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


# The link the panel shows ONLY while the words-showing design is the live
# choice. It is the coupling's one visible consequence, which makes it the
# oracle for it: this file's own docstring records Codex's ruling that a
# defaults read-back is not evidence and the picker must be SEEN to change.
CONFIGURE_LINK = "Configure Live Preview"


def main():
    pid = int(sys.argv[1])
    report = {"pid": pid, "rows": {}, "picker": {}}

    w.connect()
    w.tap("Appearance")
    report["picker"]["appearance_open"] = "RECORDING PILL" in ui_text()

    # **The greyed-reason rows are GONE, not renamed.** They asserted a sentence
    # the panel no longer renders in either Live Preview state: the presence half
    # would have failed on correct behaviour, and the absence half would have
    # passed vacuously. Found by Codex review on this branch — and it is the
    # SECOND time this pair went stale, the first being when the wording changed
    # rather than when it was deleted. A literal that only one side of a
    # presence/absence pair can falsify is the shape to stop writing here.
    #
    # What replaces them tests the behaviour that replaced the sentence.
    before = ui_text()
    report["picker"]["configure_link_while_words_selected"] = CONFIGURE_LINK in before

    # ---- Reading Well first: it is what is selected now, no toggle needed ----
    report["rows"]["readingWell"] = capture_design(pid, "readingWell")

    # ---- Live Preview is now turned off BY THE PICKER, not on its own tab ----
    #
    # The trip to the Live Preview tab is deleted along with the toggle hunt it
    # needed. That was the friction the founder named: a user who can SEE the
    # design they want should not have to find a switch elsewhere to earn the
    # click they already made. Tapping a wordless design is now the whole gesture,
    # and driving it here is what proves it.
    #
    # The cards carry no visible name any more, so these labels resolve through
    # the ACCESSIBILITY label, which still announces "<name>. <summary>". That is
    # not incidental: if a rename ever broke it, this row goes red and a
    # VoiceOver user loses the only name they had.
    for label, key in (("Capsule", "classic"), ("Level Rail", "levelRail")):
        tapped = w.tap(label)
        report["picker"][f"tapped_{key}"] = bool(tapped)
        report["rows"][key] = capture_design(pid, key)

    # Both directions, so neither half can pass vacuously: the link was present
    # above with the words design live, and must be gone now that a wordless one
    # is. A run where the taps did nothing fails HERE rather than reporting green.
    w.tap("Appearance")
    after = ui_text()
    report["picker"]["configure_link_gone_after_wordless"] = CONFIGURE_LINK not in after
    report["picker"]["coupling_observed"] = bool(
        report["picker"].get("configure_link_while_words_selected")
        and report["picker"]["configure_link_gone_after_wordless"]
    )

    (UAT / "geometry-ui.json").write_text(json.dumps(report, indent=2, default=str))
    print(json.dumps(report, indent=2, default=str)[:2200])


if __name__ == "__main__":
    main()
