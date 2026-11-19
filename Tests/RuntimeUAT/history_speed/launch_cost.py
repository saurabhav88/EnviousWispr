"""Launch cost with an existing catalog: process CPU and full History passes per launch (#4656).

Per sample: start a signpost stream for the app's HistorySpeed track and wait for its header, launch
the subject on the fixture home (`fixture.ContainedSession`: lock, renamed subject, production
preference compare, throwaway cleanup), read the subject's user plus system CPU at CPU_AT_S seconds
after the spawn, stop it, then count `HistoryDiscoveryDone` events from that pid (one per full
re-check of every source). An unchanged relaunch should show one full pass.

The CPU number is the whole launch, not only History: compare it with the same driver on the old
app on the same Mac. A sample whose CPU cannot be read, or whose stream never printed its header,
is kept as `unmeasured`, never as zero.

Usage: python3 launch_cost.py <prepared subject .app> <fixture home> <new out dir> [--samples N]
The caller holds the dev-app lock. Writes <out>/report.json.
"""
import json
import re
import subprocess
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import fixture  # noqa: E402

CPU_AT_S = 10.0
LOG = "/usr/bin/log"   # zsh has a `log` builtin; always the system tool
PREDICATE = 'subsystem == "com.enviouswispr.app" AND category == "HistorySpeed"'
HEADER = "Filtering the log data"


def parse_cpu_time(text: str) -> float | None:
    """`ps -o time=` as seconds: `M:SS.ss` or `H:MM:SS.ss`; None for anything else."""
    parts = text.strip().split(":")
    try:
        values = [float(p) for p in parts]
    except ValueError:
        return None
    if len(values) == 2:
        return values[0] * 60 + values[1]
    if len(values) == 3:
        return values[0] * 3600 + values[1] * 60 + values[2]
    return None


def count_full_passes(lines: list[str], pid: int) -> int:
    """`HistoryDiscoveryDone` events from `pid` in compact `log stream --signpost` output."""
    marker = re.compile(rf"\[{pid}:[0-9a-fx]+\].*\bHistoryDiscoveryDone\b")
    return sum(1 for line in lines if marker.search(line))


def sample(subject: Path, home: Path, out: Path, index: int) -> dict:
    stream_path = out / f"signposts-{index}.txt"
    with open(stream_path, "w") as sink:
        stream = subprocess.Popen([LOG, "stream", "--signpost", "--style", "compact", "--predicate", PREDICATE],
                                  stdout=sink, stderr=subprocess.STDOUT)
    pid = None
    cpu = None
    try:
        deadline = time.time() + 10
        while time.time() < deadline and HEADER not in stream_path.read_text():
            time.sleep(0.05)   # deadline-fallback: polls for the stream's own header line (the signal), 10 s cap
        header = HEADER in stream_path.read_text()
        with fixture.ContainedSession(subject, home, out / f"app-{index}.log") as session:
            pid = session.pid
            spawned = fixture.LAST_SPAWN_AT or time.time()
            # settle: the measurement IS "CPU at 10 s after the spawn"; a fixed instant by definition
            time.sleep(max(0.0, spawned + CPU_AT_S - time.time()))
            reading = subprocess.run(["ps", "-o", "time=", "-p", str(pid)], capture_output=True, text=True).stdout
            cpu = parse_cpu_time(reading) if reading.strip() else None
        time.sleep(1.0)   # settle: `log stream` delivers in batches; give the last events from the stopped pid time to land
    finally:
        stream.terminate()
        stream.wait(timeout=10)   # deadline-fallback: process exit is the signal; 10 s cap
    passes = count_full_passes(stream_path.read_text().splitlines(), pid) if header and pid else None
    result = "timed" if cpu is not None and passes is not None else "unmeasured"
    return {"index": index, "result": result, "cpu_at_10s_s": cpu, "full_passes": passes, "pid": pid,
            "stream_header": header}


def main() -> int:
    if len(sys.argv) < 4 or sys.argv[1] in ("-h", "--help"):
        print(__doc__)
        return 2
    subject, home, out = Path(sys.argv[1]), Path(sys.argv[2]), Path(sys.argv[3])
    samples = int(sys.argv[sys.argv.index("--samples") + 1]) if "--samples" in sys.argv else 2
    if out.exists():
        print(f"output exists: {out}", file=sys.stderr)
        return 2
    out.mkdir(parents=True)
    runs = []
    for index in range(samples):
        runs.append(sample(subject, home, out, index))
        print(json.dumps(runs[-1]), flush=True)
    timed = [r for r in runs if r["result"] == "timed"]
    cpus = sorted(r["cpu_at_10s_s"] for r in timed)
    report = {
        "samples": runs,
        "cpu_at_10s_s": {"n": len(cpus), "min": cpus[0] if cpus else None, "max": cpus[-1] if cpus else None},
        "full_passes": sorted({r["full_passes"] for r in timed}),
        "unmeasured": len(runs) - len(timed),
    }
    (out / "report.json").write_text(json.dumps(report, indent=1))
    print(json.dumps(report))
    return 0 if timed and len(timed) == len(runs) else 1


if __name__ == "__main__":
    sys.exit(main())
