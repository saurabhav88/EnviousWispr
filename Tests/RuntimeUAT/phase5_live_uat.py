"""Phase 5 live UAT — subflow 1: born locked, preview growth, per-design geometry.

Codex's evidence boundary (#2377 chunk 6): the Debug log may only SYNCHRONISE —
identify which double-press attempt activated hands-free, locate the warning
event. Every verdict about what the user SEES is judged from the running process:
CGWindow bounds and screenshots.

Born-locked PASSES only if the FIRST captured overlay frame carries the locked
treatment. A later locked frame is insufficient, which is why sampling starts
before the input rather than after it.

On the waits below: none is a test inferring that a subject has finished. This
harness SAMPLES an external app it cannot instrument, so the cadence is the
instrument; each wait is annotated with which kind it is.
"""

import json
import pathlib
import subprocess
import sys
import threading
import time

sys.path.insert(0, str(pathlib.Path(__file__).parent))

import wispr_eyes as w  # noqa: E402

UAT = pathlib.Path(
    "/Users/m4pro_sv/Developer/EnviousLabs/EnviousWispr/.validation/runs/2377-phase5-live-uat"
)
SHOTS = UAT / "subflow1"
SHOTS.mkdir(parents=True, exist_ok=True)
LOG = pathlib.Path.home() / "Library/Logs/EnviousWispr/app.log"


def overlay_windows(pid: int):
    """CGWindow bounds for the app's on-screen windows. Process evidence."""
    import Quartz

    out = []
    info = Quartz.CGWindowListCopyWindowInfo(
        Quartz.kCGWindowListOptionOnScreenOnly | Quartz.kCGWindowListExcludeDesktopElements,
        Quartz.kCGNullWindowID,
    )
    for win in info or []:
        if win.get("kCGWindowOwnerPID") != pid:
            continue
        b = win.get("kCGWindowBounds") or {}
        out.append(
            {
                "id": win.get("kCGWindowNumber"),
                "x": round(b.get("X", 0)),
                "y": round(b.get("Y", 0)),
                "w": round(b.get("Width", 0)),
                "h": round(b.get("Height", 0)),
                "layer": win.get("kCGWindowLayer"),
            }
        )
    return out


class Sampler(threading.Thread):
    """Continuous frame + screenshot sampling, started BEFORE the input."""

    def __init__(self, pid, tag, interval=0.05):
        super().__init__(daemon=True)
        self.pid, self.tag, self.interval = pid, tag, interval
        self.frames, self.running, self.shots = [], True, []

    def run(self):
        n = 0
        while self.running:
            wins = overlay_windows(self.pid)
            if wins:
                stamp = time.time()
                self.frames.append({"t": round(stamp, 3), "windows": wins})
                # Frame one is the whole question and a shot costs ~80 ms, so only
                # the opening frames of an appearance are captured.
                if n < 6:
                    p = SHOTS / f"{self.tag}-frame{n:02d}.png"
                    subprocess.run(
                        ["/usr/sbin/screencapture", "-x", "-o", str(p)],
                        capture_output=True,
                    )
                    self.shots.append(str(p))
                    n += 1
            time.sleep(self.interval)  # test-fixture-timer: sampling cadence, not a wait on a condition

    def stop(self):
        self.running = False
        self.join(timeout=2)


def log_tail_since(offset: int) -> list[str]:
    data = LOG.read_bytes()[offset:]
    return data.decode("utf-8", errors="replace").splitlines()


def main():
    pid = int(sys.argv[1])
    baseline = int((UAT / "log-baseline-bytes.txt").read_text().strip())
    result = {"pid": pid, "log_baseline": baseline}

    w.connect()

    # ---- geometry rows first: they need no recording and cost nothing ----
    result["idle_windows"] = overlay_windows(pid)

    # ---- born locked ----
    before = LOG.stat().st_size
    sampler = Sampler(pid, "handsfree")
    sampler.start()
    time.sleep(0.4)  # settle: sampler must be live BEFORE input, or "frame one" is whatever it caught

    attempts = []
    activated = False
    for attempt in range(1, 4):
        mark = LOG.stat().st_size
        try:
            hf = w.test_hands_free(sentence="phase five born locked audit", hold=6.0)
        except Exception as exc:  # noqa: BLE001
            hf = f"raised: {exc}"
        lines = log_tail_since(mark)
        got = any("Double press — requesting hands-free mode" in ln for ln in lines)
        attempts.append({"attempt": attempt, "result": str(hf)[:200], "double_press_seen": got})
        if got:
            activated = True
            break
        time.sleep(1.0)  # settle: retry must land OUTSIDE the 500 ms chain window or it reads as a triple

    time.sleep(1.0)  # settle: let the dismissal animation finish so the frame log covers the whole appearance
    sampler.stop()

    result["attempts"] = attempts
    result["hands_free_activated"] = activated
    result["frames_captured"] = len(sampler.frames)
    result["first_frames"] = sampler.frames[:8]
    result["screenshots"] = sampler.shots
    result["log_lines"] = [
        ln
        for ln in log_tail_since(before)
        if any(
            k in ln
            for k in (
                "Double press",
                "Hands-free",
                "Recording started",
                "RAW ASR",
                "Pipeline timing TOTAL",
                "dictation_terminal",
                "overlay",
            )
        )
    ][:40]

    (UAT / "subflow1.json").write_text(json.dumps(result, indent=2))
    print(json.dumps({k: v for k, v in result.items() if k != "log_lines"}, indent=2)[:2500])
    print("\n--- synchronising log lines ---")
    for ln in result["log_lines"][:20]:
        print(ln[:130])


if __name__ == "__main__":
    main()
