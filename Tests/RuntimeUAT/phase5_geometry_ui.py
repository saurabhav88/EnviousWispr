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

import contextlib
import io
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
    """The accessibility tree as TEXT, captured from what `see()` PRINTS.

    **`see()` has no return statement — it prints and returns None** — so the
    previous `str(w.see())` was the four-character string "None" on every call.
    A presence check against it is always False and an absence check always True:
    the absence direction merely loses information, the presence direction
    MANUFACTURES evidence.

    `uat-testing.md` FACT: uat-gotchas documents this verbatim, names the capture
    below as the fix, and records that the row "already existed and was not read
    first". It was not read first here either — the checks built on this reader
    during #2446 were vacuous by construction, and the exit-2 "control" that
    appeared to prove the script failed closed was this bug firing rather than the
    precondition logic working.
    """
    buffer = io.StringIO()
    with contextlib.redirect_stdout(buffer):
        w.see()
    return buffer.getvalue()


def capture_design(pid, name):
    """One fresh recording, its bounds and a screenshot."""
    require(await_idle(), f"the app never went idle before capturing {name}")
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


# The report path, named once because two places now touch it: the success write
# and the invalidation below.
REPORT = UAT / "geometry-ui.json"


def main():
    pid = int(sys.argv[1])
    report = {"pid": pid, "rows": {}, "picker": {}}

    # **A previous run's success must not survive this run.** The path is fixed,
    # so a failing run used to exit leaving the last GOOD report on disk — and a
    # reviewer or a script reading it cannot tell stale success from a current
    # result. Deleted up front rather than only on failure, so a crash between
    # here and the write also leaves nothing rather than something wrong.
    # Found by Codex review.
    REPORT.unlink(missing_ok=True)

    w.connect()

    # **The window has to EXIST before any of this means anything.** Nothing here
    # opened Settings, and every check below silently assumed someone had.
    require(w.tap("Appearance"), "could not reach the Appearance section")
    require(await_idle(), "the app never went idle after opening Appearance")

    tree = ui_text()
    appearance_open = "RECORDING PILL" in tree
    report["picker"]["appearance_open"] = appearance_open

    # **POSITIVE CONTROL on the same capture**, required by uat-testing.md
    # FACT: uat-gotchas. Without it, "the panel is not on screen" and "the reader
    # is broken" are the same observation — which is exactly the confusion that
    # produced a confident wrong diagnosis on this branch.
    report["picker"]["reader_alive"] = "PILL POSITION" in tree
    require(
        report["picker"]["reader_alive"],
        "the AX reader returned nothing recognisable — instrument failure, not a product result")
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
    require(await_idle(), "the app never went idle before selecting the words design")

    before = ui_text()
    report["picker"]["configure_link_while_words_selected"] = CONFIGURE_LINK in before
    # The link IS the evidence that the tap landed, so it is required rather than
    # recorded. A tap result would not be: see `require`.
    require(
        report["picker"]["configure_link_while_words_selected"],
        "selecting the words design did not produce the Configure Live Preview link")

    report["rows"]["readingWell"] = capture_design(pid, "readingWell")
    require(
        report["rows"]["readingWell"].get("bounds"),
        "no bounds captured for readingWell — the pill never rendered")

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
        # **The tap must CHANGE something before its capture is trusted.** If the
        # Capsule tap silently no-ops, the next capture records Reading Well's
        # geometry under the key `classic`; the later distinctness check still
        # passes, because Level Rail did move. Found by Codex review.
        #
        # Compared as whole trees rather than by hunting a "Selected" marker: the
        # picker was not on screen when this was written, so the marker's rendered
        # format could not be sampled, and a matcher grounded in nothing is how a
        # check comes to pass for the wrong reason. A no-op leaves the tree
        # byte-identical, which needs no format knowledge at all.
        # **Wait for the PREVIOUS recording to tear down before sampling.**
        # `capture_design` sends the stop key and returns without waiting, so the
        # recording overlay can still be on screen here and then vanish during the
        # `await_idle` below — making the two trees differ for a reason that has
        # nothing to do with the tap. The check would pass while the tap did
        # nothing, which is the exact false pass it was added to close. Found by
        # the cloud review.
        #
        # `await_idle` returns False on timeout and every other call site here
        # discards that — the same silent-empty shape as the reader this file just
        # had — so it is required rather than called.
        require(await_idle(), f"the recording before {label} never tore down")
        w.tap(label)
        require(await_idle(), f"the app never went idle after tapping {label}")

        # **Read WHICH CARD IS SELECTED, rather than diffing printed trees.**
        #
        # Two earlier versions of this check were wrong and the second is the
        # instructive one. A whole-tree diff could differ for reasons unrelated to
        # the tap — an overlay tearing down — and, worse, could be IDENTICAL for a
        # real move: Capsule to Level Rail keeps both designs wordless, so the
        # Configure link does not change and the only relevant difference is which
        # button carries `AXValue == "Selected"`. It therefore fails on a working
        # app and passes on a broken one, in different states. Found by the cloud
        # review.
        #
        # `read_cards` is the harness's own reader for this exact question and asks
        # the AX API instead of parsing text. The pill group was added to it for
        # this, and the "Selected" string it compares against is pinned by
        # `theSelectedValueIsExactly` — so this does not rest on a guessed format.
        selected = w.read_cards("pill")
        require(selected, f"read_cards found no pill cards after tapping {label}")
        require(
            selected.get(label) is True,
            f"tapping {label} did not select it (read {selected}) — the capture that "
            f"follows would be the PREVIOUS design's geometry filed under {key}")
        row = capture_design(pid, key)
        report["rows"][key] = row
        # A null bound is a failed capture, and recording it as data is how a dead
        # run reported three designs it never saw.
        require(row.get("bounds"), f"no bounds captured for {key} — the pill never rendered")

    # **The two wordless designs must MEASURE DIFFERENTLY.** Non-null bounds only
    # prove a pill rendered; if the Level Rail tap silently no-ops, the Capsule
    # renders twice, both rows look valid, and the second is filed under the wrong
    # name. uat-testing.md requires compared designs to prove they differ.
    classic_bounds = report["rows"]["classic"].get("bounds")
    rail_bounds = report["rows"]["levelRail"].get("bounds")
    require(
        classic_bounds != rail_bounds,
        f"classic and levelRail measured identically ({classic_bounds}) — one tap did not land")

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

    REPORT.write_text(json.dumps(report, indent=2, default=str))
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
