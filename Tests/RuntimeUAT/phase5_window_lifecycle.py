"""Identify the overlay window by LIFECYCLE, not by size (#2377 chunk 6).

Codex rejected a size/layer predicate: it admits unrelated utility windows and
would collide `64760 layer=101` with the pill. The overlay is the window that
appears or becomes visible WITH a recording, hides after stop, and reuses the
same window id on the next presentation.

This drives a menu-started recording deliberately. The menu cannot engage
hands-free lock — which is why it is useless for born-locked — but it presents
the same overlay panel, and window identity is what this script is for.

More than one candidate satisfying the lifecycle is reported AMBIGUOUS_OVERLAY
rather than resolved by picking.
"""

import json
import pathlib
import sys
import threading
import time

sys.path.insert(0, str(pathlib.Path(__file__).parent))

import wispr_eyes as w  # noqa: E402

UAT = pathlib.Path(
    "/Users/m4pro_sv/Developer/EnviousLabs/EnviousWispr/.validation/runs/2377-phase5-live-uat"
)
PID = 8718


def census():
    import Quartz

    out = {}
    info = Quartz.CGWindowListCopyWindowInfo(Quartz.kCGWindowListOptionAll, Quartz.kCGNullWindowID)
    for x in info or []:
        if x.get("kCGWindowOwnerPID") != PID:
            continue
        b = x.get("kCGWindowBounds") or {}
        out[x.get("kCGWindowNumber")] = {
            "layer": x.get("kCGWindowLayer"),
            "onscreen": bool(x.get("kCGWindowIsOnscreen")),
            "alpha": x.get("kCGWindowAlpha"),
            "w": round(b.get("Width", 0)),
            "h": round(b.get("Height", 0)),
            "x": round(b.get("X", 0)),
            "y": round(b.get("Y", 0)),
            "name": x.get("kCGWindowName"),
        }
    return out


class Watcher(threading.Thread):
    def __init__(self, interval=0.05):
        super().__init__(daemon=True)
        self.interval, self.running, self.samples = interval, True, []

    def run(self):
        while self.running:
            self.samples.append({"t": round(time.time(), 3), "windows": census()})
            time.sleep(self.interval)  # test-fixture-timer: window-server sampling cadence, not a wait

    def stop(self):
        self.running = False
        self.join(timeout=2)


def visible_ids(sample):
    return {i for i, v in sample["windows"].items() if v["onscreen"]}


def main():
    w.connect()
    watcher = Watcher()
    watcher.start()
    time.sleep(0.6)  # settle: watcher must have a pre-recording baseline before any input

    before = visible_ids(watcher.samples[-1])

    w.tap("Start Recording", role="AXMenuItem")
    time.sleep(2.5)  # settle: hold a real recording open long enough to sample its steady state
    during_sample = watcher.samples[-1]
    during = visible_ids(during_sample)

    w.tap("Stop Recording", role="AXMenuItem")
    time.sleep(4.0)  # settle: let the pipeline finish and the panel dismiss before reading "after"
    after = visible_ids(watcher.samples[-1])

    watcher.stop()

    appeared = sorted(during - before)
    went = sorted(during - after)
    candidates = sorted(set(appeared) & set(went))

    result = {
        "pid": PID,
        "visible_before": sorted(before),
        "visible_during": sorted(during),
        "visible_after": sorted(after),
        "appeared_with_recording": appeared,
        "hidden_after_stop": went,
        "lifecycle_candidates": candidates,
        "verdict": (
            "AMBIGUOUS_OVERLAY"
            if len(candidates) > 1
            else ("OVERLAY_IDENTIFIED" if candidates else "NO_CANDIDATE")
        ),
        "candidate_metadata": {str(i): during_sample["windows"].get(i) for i in candidates},
        "all_windows_during": during_sample["windows"],
        "samples": len(watcher.samples),
    }
    (UAT / "window-lifecycle.json").write_text(json.dumps(result, indent=2, default=str))
    print(json.dumps({k: v for k, v in result.items() if k != "all_windows_during"},
                     indent=2, default=str))


if __name__ == "__main__":
    main()
