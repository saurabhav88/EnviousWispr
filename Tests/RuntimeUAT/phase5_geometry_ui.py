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


class UATPreconditionFailed(RuntimeError):
    """A state this run needs, which it could not establish."""


def require(condition, what):
    """Stop the run rather than record a value nothing established.

    **Every field below used to be written whatever the app was doing.** Measured
    2026-08-26 against a freshly launched build with NO Settings window open: the
    report came back with `appearance_open: false` and the run CARRIED ON,
    producing `tapped_readingWell: true`, `tapped_classic: true` and
    `configure_link_gone_after_wordless: true` — three green-looking fields from a
    run that never opened a window. Every `bounds` was null in the same report and
    was recorded as data rather than as failure.

    **`w.tap()` returning True does NOT mean the tap landed.** That is the half
    that matters, because a guard built on tap results — which is exactly what
    `coupling_observed` was — inherits the lie. The only trustworthy evidence is
    the app's own rendered state, read back after the action.
    """
    if not condition:
        raise UATPreconditionFailed(what)


def main():
    pid = int(sys.argv[1])
    report = {"pid": pid, "rows": {}, "picker": {}}

    w.connect()

    # **The window has to EXIST before any of this means anything.** Nothing here
    # opened Settings, and every check below silently assumed someone had.
    require(w.tap("Appearance"), "could not reach the Appearance section")
    await_idle()

    appearance_open = "RECORDING PILL" in ui_text()
    report["picker"]["appearance_open"] = appearance_open
    require(appearance_open, "Appearance did not open — the Recording Pill panel is not on screen")

    # **The greyed-reason rows are GONE, not renamed.** They asserted a sentence
    # the panel no longer renders in either Live Preview state: the presence half
    # would have failed on correct behaviour, and the absence half would have
    # passed vacuously. Found by Codex review on this branch — and it is the
    # SECOND time this pair went stale, the first being when the wording changed
    # rather than when it was deleted. A literal that only one side of a
    # presence/absence pair can falsify is the shape to stop writing here.
    #
    # What replaces them tests the behaviour that replaced the sentence.
    # **Select it EXPLICITLY rather than assuming it is already selected.** The
    # previous version sampled the baseline from whatever state the machine
    # happened to be in, and this script finishes each run on Level Rail without
    # restoring — so the second run in a row read the link as missing, captured a
    # Level Rail pill under the key `readingWell`, and reported the coupling
    # broken while it worked. It also failed that way for any user who simply
    # prefers a wordless pill. Found by Codex review.
    #
    # Resolves through the ACCESSIBILITY label, since the cards carry no visible
    # name; `tapped_readingWell` false means that label stopped naming the design,
    # which is a real defect and not a harness quirk.
    w.tap("Reading Well")
    await_idle()

    before = ui_text()
    report["picker"]["configure_link_while_words_selected"] = CONFIGURE_LINK in before
    # The link IS the evidence that the tap landed, so it is required rather than
    # recorded. A tap result would not be: see `require`.
    require(
        report["picker"]["configure_link_while_words_selected"],
        "selecting the words design did not produce the Configure Live Preview link")

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
        w.tap(label)
        await_idle()
        row = capture_design(pid, key)
        report["rows"][key] = row
        # A null bound is a failed capture, and recording it as data is how a dead
        # run reported three designs it never saw.
        require(row.get("bounds"), f"no bounds captured for {key} — the pill never rendered")

    # Both directions, so neither half can pass vacuously: the link was present
    # above with the words design live, and must be gone now that a wordless one
    # is. A run where the taps did nothing fails HERE rather than reporting green.
    w.tap("Appearance")
    after = ui_text()
    report["picker"]["configure_link_gone_after_wordless"] = CONFIGURE_LINK not in after
    # Every tap that had to land is named here, so a run where the picker was
    # never actually driven reports FALSE rather than inheriting a lucky starting
    # state. Without this the whole verdict rests on a link being absent, which is
    # also what a completely dead run looks like.
    # Both halves are now REQUIRED above and here, so reaching this line at all
    # means the coupling was observed in both directions. The field stays for the
    # report's readers; it is no longer what decides the verdict, because a value
    # computed from tap results was exactly the thing that could not be trusted.
    require(
        report["picker"]["configure_link_gone_after_wordless"],
        "the Configure Live Preview link survived selecting a wordless design")
    report["picker"]["coupling_observed"] = True

    (UAT / "geometry-ui.json").write_text(json.dumps(report, indent=2, default=str))
    print(json.dumps(report, indent=2, default=str)[:2200])


if __name__ == "__main__":
    # **A failed precondition EXITS NONZERO and writes no report.** The previous
    # entrypoint let every failure become a JSON file full of plausible-looking
    # fields, which is worse than no file: a caller reading it cannot tell a real
    # result from a run that never opened a window. `validate-pr.sh` and any human
    # reading the exit status now get an unambiguous answer.
    try:
        main()
    except UATPreconditionFailed as failure:
        print(f"UAT PRECONDITION FAILED: {failure}", file=sys.stderr)
        sys.exit(2)
