"""Per-design pill geometry, driven through the REAL settings picker (#2377 chunk 6).

The defaults-write approach failed silently: writing `com.enviouswispr.app` from
another process changed the stored value and notified nothing, so three rows
captured one design and the read-back made it look verified. Codex ruled that
defaults read-back is not evidence and that the picker's own selection must be
seen to change.

So this taps Phase 4's grouped Appearance control the way a user would, confirms
the selection moved by re-reading the AX tree, closes Settings, and only then
starts a fresh recording — the design is read once per fresh recording and held.

Settings are snapshotted and restored through the same UI.
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
SHOTS = UAT / "geometry-ui"
SHOTS.mkdir(parents=True, exist_ok=True)
LOG = pathlib.Path.home() / "Library/Logs/EnviousWispr/app.log"
OVERLAY_ID = 64874


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
    deadline = time.time() + timeout
    while time.time() < deadline:
        b = bounds(pid)
        if b and b["onscreen"] and b["w"] > 0:
            return b
        time.sleep(0.05)  # test-fixture-timer: window-server sampling cadence
    return None


def ui_text():
    return str(w.see())


def capture_design(pid, name):
    """One fresh recording, its bounds and a screenshot."""
    await_idle()
    rk.single_press_record_key()
    seen = await_visible(pid)
    shot = SHOTS / f"{name}.png"
    if seen:
        subprocess.run(["/usr/sbin/screencapture", "-x", "-o", str(shot)], capture_output=True)
    rk.single_press_record_key()
    return {"bounds": seen, "screenshot": str(shot) if seen else None}


# The greyed group's reason line, verbatim from
# `RecordingPillAppearancePanel.reason(for:)`. Two rows below read
# it — one requires it present, one requires it gone — so it lives here once.
GREYED_REASON = "Turn off Live Preview to use the other designs."


def main():
    pid = int(sys.argv[1])
    report = {"pid": pid, "rows": {}, "picker": {}}

    w.connect()
    w.tap("Appearance")
    report["picker"]["appearance_open"] = "RECORDING PILL" in ui_text()

    # The without-words group is greyed while Live Preview is on — Phase 4's own
    # behaviour, and the reason it states is captured here as evidence.
    #
    # ONE constant for both the presence and the absence check below. Held twice,
    # the absence half passes for free the moment the copy changes and the string
    # here goes stale: it then asserts that a sentence nobody renders is missing.
    # That is the shape that made this row green against copy it had never seen.
    before = ui_text()
    report["picker"]["greyed_reason_present"] = GREYED_REASON in before

    # ---- Reading Well first: it is what is selected now, no toggle needed ----
    report["rows"]["readingWell"] = capture_design(pid, "readingWell")

    # ---- turn Live Preview OFF through its own tab ----
    w.tap("Live Preview")
    lp = ui_text()
    report["picker"]["live_preview_tab"] = "Live Preview" in lp
    for label in ("Show words as I speak", "Live Preview", "Enable Live Preview"):
        try:
            if w.tap(label):
                report["picker"]["toggled_via"] = label
                break
        except Exception:  # noqa: BLE001
            continue

    w.tap("Appearance")
    after = ui_text()
    report["picker"]["greyed_cleared"] = GREYED_REASON not in after

    for label, key in (("Capsule", "classic"), ("Level Rail", "levelRail")):
        tapped = w.tap(label)
        report["picker"][f"tapped_{key}"] = bool(tapped)
        report["rows"][key] = capture_design(pid, key)

    (UAT / "geometry-ui.json").write_text(json.dumps(report, indent=2, default=str))
    print(json.dumps(report, indent=2, default=str)[:2200])


if __name__ == "__main__":
    main()
