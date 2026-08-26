"""Born-locked, judged from video (#2377 Phase 5, chunk 6, Codex instrument ruling).

The PASS test, verbatim from the ruling:

  - frame zero is the first video frame containing overlay pixels inside the
    lifecycle-confirmed panel bounds;
  - that same frame already shows `Hands-free`;
  - no visible overlay frame before or after shows the unlocked treatment;
  - a SINGLE-PRESS negative control shows the unlocked treatment in the same
    crop, proving the classifier can distinguish the states.

Window polling and occasional screenshots cannot prove a first composited frame,
so this records 60 fps video started before the input and extracts frames after.

The overlay is `64874`, identified by LIFECYCLE rather than by size — it is the
only window that appears with a recording and hides after stop
(`window-lifecycle.json`). Its bounds change per design, which is exactly why a
size predicate was rejected.

Log lines are SYNCHRONISERS only: they say which attempt took, never what the
user saw.
"""

import json
import pathlib
import subprocess
import sys
import time

sys.path.insert(0, str(pathlib.Path(__file__).parent))

import wispr_eyes as rk  # noqa: E402  (record-key helpers; merged in #2425)  — ported verbatim, see its header
import wispr_eyes as w  # noqa: E402

UAT = pathlib.Path(
    "/Users/m4pro_sv/Developer/EnviousLabs/EnviousWispr/.validation/runs/2377-phase5-live-uat"
)
LOG = pathlib.Path.home() / "Library/Logs/EnviousWispr/app.log"
OVERLAY_ID = 64874


def dev_pids():
    """Every dev instance, by EXECUTABLE path. Not by name: a Release instance is
    `EnviousWispr.app`, carries the production bundle id, and writes no log."""
    out = subprocess.run(["ps", "-eo", "pid=,command="], capture_output=True, text=True).stdout
    needle = "EnviousWispr Local.app/Contents/MacOS/" + "EnviousWispr"
    return sorted(
        int(ln.split(None, 1)[0])
        for ln in out.splitlines()
        if needle in ln and "/bin/zsh" not in ln and "python3" not in ln
    )


def overlay_bounds(pid):
    import Quartz

    info = Quartz.CGWindowListCopyWindowInfo(Quartz.kCGWindowListOptionAll, Quartz.kCGNullWindowID)
    for x in info or []:
        if x.get("kCGWindowOwnerPID") == pid and x.get("kCGWindowNumber") == OVERLAY_ID:
            b = x.get("kCGWindowBounds") or {}
            return {
                "x": round(b.get("X", 0)),
                "y": round(b.get("Y", 0)),
                "w": round(b.get("Width", 0)),
                "h": round(b.get("Height", 0)),
                "onscreen": bool(x.get("kCGWindowIsOnscreen")),
            }
    return None


def capture(tag, seconds, action):
    """Record 60 fps video across `action`, started BEFORE it."""
    vid = UAT / f"{tag}.mov"
    vid.unlink(missing_ok=True)
    proc = subprocess.Popen(
        ["/usr/sbin/screencapture", "-v", f"-V{seconds}", "-x", str(vid)],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    time.sleep(1.2)  # settle: recorder must be writing before input; screencapture emits no ready signal
    started = time.time()
    result = action()
    # deadline-fallback: waits on the real signal (recorder process exit); the timeout only bounds a hang
    proc.wait(timeout=seconds + 20)
    return {"video": str(vid), "started": started, "action": result, "exists": vid.exists()}


def await_idle(timeout=25.0):
    """Block until the app will ACCEPT a keypress, reading its own log.

    `double_press_record_key`'s contract says "retry at most three times from a
    clean, non-recording state", and the first run violated it: three attempts
    landed while a previous take was still in the pipeline and the app answered
    `Key press ignored — pipeline is still processing` to every one. That is the
    app refusing input correctly, not a missed chain — so it never reached the
    ~80% the gesture is measured at, and reading it as a product failure would
    have been the confident-wrong-subject shape.

    Idle is defined as: the newest terminal marker is newer than the newest
    `Recording started`. A signal from the subject, not a duration.
    """
    deadline = time.time() + timeout
    while time.time() < deadline:
        text = LOG.read_text(errors="replace")
        last_start = text.rfind("Recording started")
        last_end = max(text.rfind("dictation_terminal"), text.rfind("Clipboard cleanup"))
        if last_end > last_start:
            return True
        time.sleep(0.25)  # test-fixture-timer: log-polling cadence; the app emits no readiness event
    return False


def main():
    pid = int(sys.argv[1])
    pids_before = dev_pids()
    if pids_before != [pid]:
        print(json.dumps({"verdict": "ABORT_INSTANCE", "expected": [pid], "found": pids_before}))
        return

    w.connect()
    report = {"pid": pid, "pids_before": pids_before, "overlay_id": OVERLAY_ID}
    report["bounds_idle"] = overlay_bounds(pid)

    # ---- ARM: hands-free via the ported double press ----
    report["idle_before_double"] = await_idle()
    mark = LOG.stat().st_size
    armed = capture("born-locked-double", 14, lambda: rk.double_press_record_key(attempts=3))
    tail = LOG.read_bytes()[mark:].decode("utf-8", errors="replace").splitlines()
    report["double_press"] = {
        "capture": armed,
        "double_press_lines": [ln for ln in tail if "Double press" in ln][:5],
        "activated_lines": [ln for ln in tail if "Hands-free mode activated" in ln][:5],
        "ignored_lines": [ln for ln in tail if "Key press ignored" in ln][:5],
        "debounce_lines": [ln for ln in tail if "Debounce timer fired" in ln][:5],
        "bounds_during": overlay_bounds(pid),
    }

    # ---- NEGATIVE CONTROL: single press, same crop, must show UNLOCKED ----
    report["idle_before_single"] = await_idle()
    mark2 = LOG.stat().st_size
    control = capture("born-locked-single", 10, rk.single_press_record_key)
    tail2 = LOG.read_bytes()[mark2:].decode("utf-8", errors="replace").splitlines()
    report["single_press"] = {
        "capture": control,
        "double_press_lines": [ln for ln in tail2 if "Double press" in ln][:5],
        "bounds_during": overlay_bounds(pid),
    }

    pids_after = dev_pids()
    report["pids_after"] = pids_after
    report["instance_stable"] = pids_after == pids_before
    if not report["instance_stable"]:
        report["verdict"] = "ABORT_INSTANCE_CHANGED"

    (UAT / "born-locked.json").write_text(json.dumps(report, indent=2, default=str))
    print(json.dumps(report, indent=2, default=str)[:3000])


if __name__ == "__main__":
    main()
