"""Preview growth, captured with `wispr_eyes.record` (#2377 chunk 6, row 2).

Validates the new recorder against a real scorecard row: the reading-well pill
must grow as words arrive — empty, one line, several — without clipping.

Growth is judged from the VIDEO plus the window's own bounds over time, not from
a screenshot taken at a guessed instant. A screenshot can only answer "was it
this tall at the moment I asked"; the row is about a sequence.
"""

import json
import pathlib
import subprocess
import sys
import threading
import time

sys.path.insert(0, str(pathlib.Path(__file__).parent))

import phase5_record_key as rk  # noqa: E402
import wispr_eyes as w  # noqa: E402

UAT = pathlib.Path(
    "/Users/m4pro_sv/Developer/EnviousLabs/EnviousWispr/.validation/runs/2377-phase5-live-uat"
)
OUT = UAT / "preview-growth"
OUT.mkdir(parents=True, exist_ok=True)
LOG = pathlib.Path.home() / "Library/Logs/EnviousWispr/app.log"

SENTENCE = (
    "The quarterly numbers came in ahead of plan this month. "
    "Revenue grew across every region we track. "
    "The team shipped four features and closed eleven bugs. "
    "Customer retention held steady at ninety four percent. "
    "We expect the same trajectory through the end of the year."
)


def dev_pids():
    out = subprocess.run(["ps", "-eo", "pid=,command="], capture_output=True, text=True).stdout
    needle = "EnviousWispr Local.app/Contents/MacOS/" + "EnviousWispr"
    return sorted(int(l.split(None, 1)[0]) for l in out.splitlines()
                  if needle in l and "/bin/zsh" not in l and "python3" not in l)


def overlay(pid):
    import Quartz

    info = Quartz.CGWindowListCopyWindowInfo(Quartz.kCGWindowListOptionAll, Quartz.kCGNullWindowID)
    best = None
    for x in info or []:
        if x.get("kCGWindowOwnerPID") != pid or not x.get("kCGWindowIsOnscreen"):
            continue
        if (x.get("kCGWindowLayer") or 0) <= 0:
            continue
        b = x.get("kCGWindowBounds") or {}
        best = {"id": x.get("kCGWindowNumber"), "w": round(b.get("Width", 0)),
                "h": round(b.get("Height", 0)), "x": round(b.get("X", 0)),
                "y": round(b.get("Y", 0))}
    return best


class Heights(threading.Thread):
    """The window's own height over time — the growth series."""

    def __init__(self, pid):
        super().__init__(daemon=True)
        self.pid, self.running, self.series = pid, True, []

    def run(self):
        while self.running:
            o = overlay(self.pid)
            if o:
                self.series.append({"t": round(time.time(), 2), **o})
            time.sleep(0.05)  # test-fixture-timer: window-server sampling cadence

    def stop(self):
        self.running = False
        self.join(timeout=2)


def await_idle(timeout=30.0):
    deadline = time.time() + timeout
    while time.time() < deadline:
        t = LOG.read_text(errors="replace")
        if max(t.rfind("dictation_terminal"), t.rfind("Clipboard cleanup")) > t.rfind("Recording started"):
            return True
        time.sleep(0.25)  # test-fixture-timer: log-polling cadence
    return False


def main():
    pids = dev_pids()
    if len(pids) != 1:
        print(json.dumps({"verdict": "ABORT_INSTANCE", "found": pids}))
        return
    pid = pids[0]
    w.connect()
    await_idle()

    heights = Heights(pid)
    heights.start()

    clip_path = str(OUT / "preview-growth.mov")
    with w.record(26, save_path=clip_path) as clip:
        rk.single_press_record_key()
        w.record_tts(SENTENCE)          # speaks it through the speakers
        rk.single_press_record_key()

    heights.stop()
    await_idle()

    series = heights.series
    hs = [s["h"] for s in series]
    report = {
        "pid": pid,
        "clip": clip.path,
        "clip_exists": clip.exists,
        "samples": len(series),
        "distinct_heights": sorted(set(hs)),
        "min_height": min(hs) if hs else None,
        "max_height": max(hs) if hs else None,
        "grew": bool(hs and max(hs) > min(hs)),
        "width_constant": len({s["w"] for s in series}) == 1 if series else None,
        "one_window_id": len({s["id"] for s in series}) == 1 if series else None,
    }

    # Frames at the extremes, so the verdict can be looked at rather than trusted.
    if clip.exists and series:
        t0 = series[0]["t"]
        for label, target in (("empty", 0.5), ("mid", 6.0), ("tallest", 12.0)):
            got = clip.frame_at(target, save_path=str(OUT / f"{label}.png"))
            report.setdefault("frames", {})[label] = got

    (UAT / "preview-growth.json").write_text(json.dumps(report, indent=2, default=str))
    print(json.dumps(report, indent=2, default=str)[:1800])


if __name__ == "__main__":
    main()
