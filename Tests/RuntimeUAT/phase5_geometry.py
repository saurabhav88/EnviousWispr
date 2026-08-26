"""Per-design pill geometry, on screen (#2377 chunk 6, row 1 — owed since Phase 4).

Phase 4 never verified this: it could not get the shared dev-app slot. The rows
are Classic, Level Rail and Reading Well, each with lifecycle-confirmed CGWindow
bounds and a screenshot, plus the 288-point Level Rail width and badge placement
the founder asked about.

**Settings are snapshotted and restored.** The dev build redirects most settings
to `com.enviouswispr.app`, the SHARED suite, so a value left behind changes what
every other worktree's dev build reads on next launch.

The design is read once per FRESH recording and then held — an `NSPanel` cannot
grow mid-recording without a rebuild, and a rebuild is the #930 flicker. So each
row sets the defaults, then starts a NEW recording.

Every wait here reads a real signal: a settings value read back, the window server
reporting the panel on screen, or the app's own terminal marker. None guesses.
"""

import json
import pathlib
import subprocess
import sys
import time

sys.path.insert(0, str(pathlib.Path(__file__).parent))

import wispr_eyes as rk  # noqa: E402  (record-key helpers; merged in #2425)
import wispr_eyes as w  # noqa: E402

UAT = pathlib.Path(
    "/Users/m4pro_sv/Developer/EnviousLabs/EnviousWispr/.validation/runs/2377-phase5-live-uat"
)
SHOTS = UAT / "geometry"
SHOTS.mkdir(parents=True, exist_ok=True)
LOG = pathlib.Path.home() / "Library/Logs/EnviousWispr/app.log"
DOMAIN = "com.enviouswispr.app"
OVERLAY_ID = 64874

KEYS = ["livePreviewEnabled", "recordingPillDesignWithoutWords"]

ROWS = [
    ("readingWell", {"livePreviewEnabled": "1"}),
    ("levelRail", {"livePreviewEnabled": "0", "recordingPillDesignWithoutWords": "levelRail"}),
    ("classic", {"livePreviewEnabled": "0", "recordingPillDesignWithoutWords": "classic"}),
]


def read_default(key):
    r = subprocess.run(["defaults", "read", DOMAIN, key], capture_output=True, text=True)
    return r.stdout.strip() if r.returncode == 0 else None


def write_default(key, value):
    subprocess.run(["defaults", "write", DOMAIN, key, value], check=True)


def apply_settings(settings, timeout=5.0):
    """Write, then READ BACK until the value is what we wrote.

    A signal, not a wait: `defaults` is a separate process writing a shared
    suite, and the honest question is whether the value landed — which the value
    itself answers.
    """
    for k, v in settings.items():
        write_default(k, v)
    deadline = time.time() + timeout
    while time.time() < deadline:
        if all(read_default(k) == v for k, v in settings.items()):
            return True
        time.sleep(0.05)  # test-fixture-timer: read-back polling cadence
    return False


def bounds(pid):
    import Quartz

    info = Quartz.CGWindowListCopyWindowInfo(Quartz.kCGWindowListOptionAll, Quartz.kCGNullWindowID)
    for x in info or []:
        if x.get("kCGWindowOwnerPID") == pid and x.get("kCGWindowNumber") == OVERLAY_ID:
            b = x.get("kCGWindowBounds") or {}
            return {
                "x": round(b.get("X", 0)), "y": round(b.get("Y", 0)),
                "w": round(b.get("Width", 0)), "h": round(b.get("Height", 0)),
                "onscreen": bool(x.get("kCGWindowIsOnscreen")),
            }
    return None


def await_idle(timeout=25.0):
    deadline = time.time() + timeout
    while time.time() < deadline:
        t = LOG.read_text(errors="replace")
        if max(t.rfind("dictation_terminal"), t.rfind("Clipboard cleanup")) > t.rfind("Recording started"):
            return True
        time.sleep(0.25)  # test-fixture-timer: log-polling cadence; the app emits no readiness event
    return False


def await_visible(pid, timeout=8.0):
    """Wait for the lifecycle-confirmed overlay to be on screen — a signal from
    the window server, not a duration."""
    deadline = time.time() + timeout
    while time.time() < deadline:
        b = bounds(pid)
        if b and b["onscreen"] and b["w"] > 0:
            return b
        time.sleep(0.05)  # test-fixture-timer: window-server sampling cadence
    return None


def main():
    pid = int(sys.argv[1])
    snapshot = {k: read_default(k) for k in KEYS}
    report = {"pid": pid, "settings_snapshot": snapshot, "rows": {}}
    print("snapshot:", snapshot)

    try:
        for name, settings in ROWS:
            await_idle()
            report.setdefault("applied", {})[name] = apply_settings(settings)

            rk.single_press_record_key()
            seen = await_visible(pid)
            shot = SHOTS / f"{name}.png"
            if seen:
                subprocess.run(["/usr/sbin/screencapture", "-x", "-o", str(shot)], capture_output=True)
            rk.single_press_record_key()  # stop
            report["rows"][name] = {
                "settings": settings,
                "bounds": seen,
                "screenshot": str(shot) if seen else None,
            }
            print(f"  {name}: {seen}")
    finally:
        for k, v in snapshot.items():
            if v is None:
                subprocess.run(["defaults", "delete", DOMAIN, k], capture_output=True)
            else:
                write_default(k, v)
        report["settings_restored"] = {k: read_default(k) for k in KEYS}
        report["restore_clean"] = report["settings_restored"] == snapshot
        (UAT / "geometry.json").write_text(json.dumps(report, indent=2, default=str))
        print(json.dumps(report, indent=2, default=str)[:2000])


if __name__ == "__main__":
    main()
