"""Resource sampling and a busy-Mac load for the History drivers (#4586 WP-A, north star 1 and 4).

ResourceSampler: CPU seconds used and peak resident memory of one process over a phase, from `ps`
every 250 ms (`time=` is cumulative CPU, `rss=` is resident KiB). One honest number per phase, not a
profile: the CPU figure is the difference of two cumulative readings, so sampling gaps lose no CPU
time; the memory peak is the highest sampled RSS, so a spike shorter than 250 ms can be missed.

BusyLoad: one `/usr/bin/yes` busy loop per performance core (`hw.perflevel0.physicalcpu`) for the
life of the context, then killed and reaped.
"""
from __future__ import annotations

import subprocess
import threading


def _ps(pid: int):
    """(cpu seconds, rss MiB) of pid, or None when it is gone."""
    result = subprocess.run(["/bin/ps", "-o", "time=,rss=", "-p", str(pid)], capture_output=True, text=True)
    fields = result.stdout.split()
    if result.returncode != 0 or len(fields) != 2:
        return None
    return parse_cpu_time(fields[0]), int(fields[1]) / 1024


def parse_cpu_time(text: str) -> float:
    """`ps -o time=` text ([[dd-]hh:]mm:ss.ss) in seconds."""
    days = 0
    if "-" in text:
        d, text = text.split("-", 1)
        days = int(d)
    parts = [float(p) for p in text.split(":")]
    seconds = 0.0
    for part in parts:
        seconds = seconds * 60 + part
    return days * 86400 + seconds


class ResourceSampler:
    def __init__(self, pid: int, interval: float = 0.25):
        self.pid, self.interval = pid, interval
        self._stop = threading.Event()
        self.first = self.last = None
        self.peak_mb = 0.0
        self.samples = 0

    def _run(self):
        while not self._stop.is_set():
            reading = _ps(self.pid)
            if reading is not None:
                self.first = self.first or reading
                self.last = reading
                self.peak_mb = max(self.peak_mb, reading[1])
                self.samples += 1
            self._stop.wait(self.interval)  # deadline-fallback: sampling cadence, ends on the stop signal

    def __enter__(self):
        # A synchronous first reading, so work at the very start of the phase is counted.
        reading = _ps(self.pid)
        if reading is not None:
            self.first = self.last = reading
            self.peak_mb = reading[1]
            self.samples = 1
        self._thread = threading.Thread(target=self._run, daemon=True)
        self._thread.start()
        return self

    def __exit__(self, *exc):
        self._stop.set()
        self._thread.join()
        final = _ps(self.pid)
        self.final_read = final is not None
        if final is not None:
            self.last = final
            self.peak_mb = max(self.peak_mb, final[1])
        return False

    def result(self) -> dict:
        if self.first is None or self.last is None or not getattr(self, "final_read", False):
            # No baseline or no final reading: the phase was not covered; never a shorter number.
            return {"cpu_s": None, "peak_rss_mb": None, "samples": self.samples, "covered": False}
        return {"cpu_s": round(self.last[0] - self.first[0], 2), "peak_rss_mb": round(self.peak_mb, 1),
                "end_rss_mb": round(self.last[1], 1), "samples": self.samples}


def performance_cores() -> int:
    result = subprocess.run(["/usr/sbin/sysctl", "-n", "hw.perflevel0.physicalcpu"], capture_output=True, text=True)
    try:
        return max(1, int(result.stdout.strip()))
    except ValueError:
        return 4


class BusyLoad:
    def __init__(self, count: int | None = None):
        self.count = count or performance_cores()
        self.procs = []

    def __enter__(self):
        self.procs = [subprocess.Popen(["/usr/bin/yes"], stdout=subprocess.DEVNULL) for _ in range(self.count)]
        return self

    def __exit__(self, *exc):
        for proc in self.procs:
            proc.kill()
        for proc in self.procs:
            proc.wait()
        self.procs = []
        return False


def machine_conditions() -> dict:
    """Load average and the count of heavy peer processes, recorded beside every timed run so a
    number taken on a busy Mac is never published as a quiet-machine number (#4586 parent rule)."""
    uptime = subprocess.run(["/usr/bin/uptime"], capture_output=True, text=True).stdout.strip()
    listing = subprocess.run(["/bin/ps", "-axo", "comm="], capture_output=True, text=True).stdout.splitlines()
    names = [line.strip().rsplit("/", 1)[-1] for line in listing]
    counts = {name: sum(1 for n in names if n == name) for name in ("xcodebuild", "swift-frontend", "codex")}
    load1 = float(uptime.split("load averages:")[-1].split()[0]) if "load averages:" in uptime else None
    return {"uptime": uptime, "load1": load1, "processes": counts,
            # codex processes are reported, not gating: an idle Codex desktop app keeps several alive.
            "quiet": load1 is not None and load1 < 3 and counts["xcodebuild"] == 0 and counts["swift-frontend"] == 0}
