"""The #1060 in-panel warning, morphing INTO the pill already on screen.

#2377 chunk 6. Phase 5's claim is that the notice rides in the SAME atomic frame
as the recording it belongs to, so the subject is not "a banner appeared" — it is
"the banner appeared WITHOUT a second window and WITHOUT the pill being torn down
and rebuilt". The retained window id carries that, so it is the assertion rather
than the screenshot.

**Driven by the production DEBUG override, not a new seam.** `TimingConstants`
honours `EWDebugMaxRecordingSeconds` and `EWDebugWarningLeadSeconds`, and its own
comment states the purpose: "so Live UAT can drive the full
warning -> cap -> transcribe cycle in ~90s instead of an hour"
(`Constants.swift:366`).

**THE OVERRIDE READS `UserDefaults.standard`, WHICH IS THE DEV DOMAIN.** Every
other preset here goes to the shared `com.enviouswispr.app` store, but these two
are read straight off `.standard`, so for the dev build they live in
`com.enviouswispr.app.dev`. Written to the shared domain they change nothing and
the run reports the warning never firing.

**TIMING ALONE IS NOT THE PREDICATE.** A window that merely changed size near the
expected second passes a timing-only check, and an unrelated animation is exactly
that. The morph is specific: a banner adds a row to a pill whose width does not
move, so the row requires width UNCHANGED and height GROWN on the same window,
and requires every extracted frame to exist.

**TWO NOTICES, TWO TAKES, because one recording cannot show both.** The #1060
cap warning is armed `dismissAfter: nil` — the coordinator states it "stays until
the recording stops; cleared by the transition out of recording"
(`DictationLifecycleCoordinator.swift:285-294`) — so it can prove the MORPH and
never the clear. The clear is proven by `autoStopUnavailable`, the only in-panel
notice armed `dismissAfter: 4.0` (`WisprBootstrapper.swift:573`), staged through
`force_auto_stop_unavailable_notice`. Firing both into one take would leave the
persistent notice underneath the self-clearing one and neither transition legible.

    take 1  cap warning     morph 400x34 -> 400x60, stays
    take 2  autoStop notice morph 400x34 -> 400x60 -> 400x34, recording still live

**The staged notice is the PRODUCTION closure.** `WisprBootstrapper` installs the
same value it hands the VAD source, so this proves that notice clearing through
the one clock rather than proving a notice can clear.

No speech is needed: the cap warning is driven by elapsed recording time, and the
staged notice by a command.
"""

import json
import pathlib
import subprocess
import sys
import threading
import time

sys.path.insert(0, str(pathlib.Path(__file__).parent))

import phase5_geometry_relaunch as g  # noqa: E402
import phase5_overlay_lifecycle as lc  # noqa: E402
import phase5_paste_target as pt  # noqa: E402
import wispr_eyes as rk  # noqa: E402  (record-key helpers; merged in #2425)
import faultInjection as fi  # noqa: E402
import wispr_eyes as w  # noqa: E402

UAT = pathlib.Path(
    "/Users/m4pro_sv/Developer/EnviousLabs/EnviousWispr/.validation/runs/2377-phase5-live-uat"
)
OUT = UAT / "warning-morph"
OUT.mkdir(parents=True, exist_ok=True)
LOG = pathlib.Path.home() / "Library/Logs/EnviousWispr/app.log"

DEV_DOMAIN = "com.enviouswispr.app.dev"
CAP_SECONDS = 45.0
LEAD_SECONDS = 30.0          # so the warning fires 15s into the take
HOLD_SECONDS = 26.0          # comfortably past the warning, well short of the cap
MORPH_FROM, MORPH_TO = [400, 34], [400, 60]

# **THE PAIR ABOVE BELONGS TO ONE OF THREE APPEARANCES, SO THIS ROW PINS IT.**
# `PillDefinition.swift` is the authority and makes the widths a closed set:
# classic 185, readingWell 400, levelRail 288. Both rows here read an EXACT frame
# pair on purpose — see the comments at the two morph predicates, which record why
# "same width, taller near the deadline" was refused — so the geometry cannot be
# loosened, and the world it was measured in has to be declared instead.
#
# Undeclared, whichever appearance this machine happens to have selected decides
# whether the row can work at all, and it fails toward REFUSED, which reads
# exactly like a product failure. Measured 2026-08-30 on clean `main`: with the
# Level Rail selected the pill was 288x92 throughout, `morph` and `clear` both
# came back `None`, and BOTH rows refused with every mechanical check green —
# staged command accepted, one window id, lifecycle OK, recording still live.
#
# Classic could never work here whatever the timing: it is documented as "a fixed
# 185x92 interaction frame that holds ... the #1060 notice expansion without
# resizing", so on that design the morph this row watches for does not exist.
#
# Both keys are pinned because the pill picks between them on whether words are
# shown (`PillAppearanceModel`), and this row must not depend on that.
#
# **AND LIVE PREVIEW WITH IT, because the design alone does not decide.**
# `PillAppearanceModel.resolve(capabilityHasWords:)` SUBSTITUTES a wordless design
# when the words capability is absent, and `chooseCoupled` writes
# `livePreviewEnabled = design.canHoldWords` — so in the app, picking this pill and
# turning Live Preview on are one action. Setting the design without it reproduces
# the original failure exactly: measured 2026-08-30, the pin read back correctly
# and the pill was still 288x92.
DESIGN = "readingWell"
DESIGN_OVERRIDES = {"recordingPillDesignWithoutWords": DESIGN,
                    "recordingPillDesignWithWords": DESIGN}
BOOL_OVERRIDES = {"livePreviewEnabled": "true"}
OVERRIDES = {"EWDebugMaxRecordingSeconds": CAP_SECONDS,
             "EWDebugWarningLeadSeconds": LEAD_SECONDS}
# Every key this row writes, with the `defaults` type flag each one needs. A
# string written with `-float` lands as 0 and silently selects nothing.
PINNED = {**{k: "-float" for k in OVERRIDES},
          **{k: "-string" for k in DESIGN_OVERRIDES},
          **{k: "-bool" for k in BOOL_OVERRIDES}}
WANTED = {**{k: str(v) for k, v in OVERRIDES.items()},
          **DESIGN_OVERRIDES, **BOOL_OVERRIDES}


def bool_word(v):
    """A boolean in the spelling `defaults write -bool` accepts.

    **`defaults write <domain> <key> -bool 1` EXITS 255 and prints its usage.**
    It takes `true`/`false`/`YES`/`NO`, while `defaults read` hands the same key
    back as `1`/`0` — so a value round-tripped through this script without this
    conversion kills the run, and on the RESTORE path it would kill it after the
    measurement, leaving the machine on the pinned appearance.
    """
    return "true" if str(v).strip().lower() in {"1", "true", "yes"} else "false"


def same_default(flag, a, b):
    """Whether two `defaults` values mean the same thing under one type flag."""
    if flag == "-float":
        return float(a) == float(b)
    if flag == "-bool":
        return bool_word(a) == bool_word(b)
    return a == b


def read_dev_default(k):
    r = subprocess.run(["defaults", "read", DEV_DOMAIN, k], capture_output=True, text=True)
    return r.stdout.strip() if r.returncode == 0 else None


class Bounds(threading.Thread):
    """Every visible overlay window's bounds over time, with timestamps."""

    def __init__(self, pid):
        super().__init__(daemon=True)
        self.pid, self.running, self.series = pid, True, []

    def run(self):
        while self.running:
            for wid, m in g.visible_overlays(self.pid).items():
                self.series.append({"t": time.time(), "id": wid, **m})
            time.sleep(0.05)  # test-fixture-timer: window-server sampling cadence

    def stop(self):
        self.running = False
        self.join(timeout=2)


def recording_started_at(since_bytes):
    """Wall-clock of the app's own `Recording started`, from the log.

    The row's timing claim is relative to when the RECORDING began, not to when
    the harness pressed — the two differ by the chain window plus any retry, and
    a warning judged against the press time drifts by seconds.
    """
    with LOG.open("rb") as fh:
        fh.seek(since_bytes)
        tail = fh.read().decode("utf-8", errors="replace")
    for line in tail.splitlines():
        if "Recording started" in line and line.startswith("["):
            stamp = line[1:line.index("]")]
            import datetime as dt
            return dt.datetime.fromisoformat(stamp).timestamp()
    return None


def staged_clear_take(pid):
    """Take 2: stage the self-clearing notice and watch it come and go.

    Returns a dict. The claim is a round trip on ONE window — morph out to the
    banner frame, back to the pre-banner frame about four seconds later — with
    the recording still live at the end, because a "clear" that is really the
    recording ending is the thing this row must not accept.
    """
    # IDLE INVOCATION MUST BE INERT, and that is ASSERTED rather than noted. The
    # notice targets the recording panel and no-ops when none is showing; a seam
    # that rendered something with no recording would be staging a state the
    # product cannot reach, which is the opposite of what it is for.
    idle_settled = g.await_idle()
    idle_before = set(g.visible_overlays(pid))
    idle_reply = fi.send("force_auto_stop_unavailable_notice")
    idle_seen = {}
    for _ in range(60):
        idle_seen.update(g.visible_overlays(pid))
        time.sleep(0.05)  # test-fixture-timer: window-server sampling cadence
    out = {"idle_reply": idle_reply,
           "idle_settled": idle_settled,
           "idle_slot_was_empty": not idle_before,
           "idle_overlays_before": sorted(idle_before),
           "idle_overlays_after": sorted(idle_seen),
           "idle_invocation_inert": not (set(idle_seen) - idle_before)}

    before = set(g.visible_overlays(pid))
    bounds = Bounds(pid)
    bounds.start()
    if not rk.double_press_record_key():
        bounds.stop()
        return dict(out, error="hands-free did not engage")

    time.sleep(2.0)  # settle: let the recording pill settle to its steady frame
    steady = [m for m in g.visible_overlays(pid).values()]
    out["frame_before_notice"] = [steady[0]["w"], steady[0]["h"]] if steady else None

    live = [i for i in g.visible_overlays(pid) if i not in before]
    wid = live[0] if len(live) == 1 else None
    clear_frames = {}
    if wid:
        clear_frames["before-notice"] = str(OUT / "clear-before.png")
        g.capture_window(wid, clear_frames["before-notice"])
    out["reply"] = fi.send("force_auto_stop_unavailable_notice")
    fired_at = time.time()
    time.sleep(1.0)  # settle: let the banner compose before capturing it
    if wid:
        clear_frames["notice-visible"] = str(OUT / "clear-visible.png")
        g.capture_window(wid, clear_frames["notice-visible"])
    time.sleep(9.0)  # deadline-fallback: the notice is armed `dismissAfter: 4.0`
    # and there is no signal for "the clear fired"; outliving it IS the
    # observation, so this waits comfortably past it and reads the series.

    if wid:
        clear_frames["after-clear"] = str(OUT / "clear-after.png")
        g.capture_window(wid, clear_frames["after-clear"])
    still_recording = "Recording started" in tail_of_log(2000) and not _terminal_after_start()
    rk.stop_after_short_hold(0.0)
    bounds.stop()
    g.await_idle()

    after = set(g.visible_overlays(pid))
    life = lc.describe(before, {x["id"] for x in bounds.series}, after)
    series = [x for x in bounds.series if x["id"] == life["window_id"]] if life["window_id"] else []

    steps, last = [], None
    for x in series:
        key = (x["w"], x["h"])
        if last is not None and key != last:
            steps.append({"at_s": round(x["t"] - fired_at, 2),
                          "from": list(last), "to": [x["w"], x["h"]]})
        last = key
    out["steps"] = steps
    out["lifecycle"] = life["verdict"]
    out["recording_still_live_at_clear"] = still_recording

    # THE EXACT ROUND TRIP. "Any same-width growth and its inverse" still admits a
    # live preview wrapping a line and unwrapping it; the banner is a specific
    # pair of frames.
    outs = [m for m in steps if m["at_s"] >= 0
            and m["from"] == MORPH_FROM and m["to"] == MORPH_TO]
    backs = [m for m in steps if outs and m["at_s"] > outs[0]["at_s"]
             and m["from"] == MORPH_TO and m["to"] == MORPH_FROM]
    out["morph"] = outs[0] if outs else None
    out["clear"] = backs[0] if backs else None
    out["cleared_after_s"] = (round(backs[0]["at_s"] - outs[0]["at_s"], 2)
                              if outs and backs else None)
    out["frames"] = clear_frames
    return out


def tail_of_log(n_bytes):
    with LOG.open("rb") as fh:
        fh.seek(max(0, LOG.stat().st_size - n_bytes))
        return fh.read().decode("utf-8", errors="replace")


def _terminal_after_start():
    t = tail_of_log(200_000)
    return max(t.rfind("dictation_terminal"), t.rfind("Clipboard cleanup")) > t.rfind("Recording started")


def main():
    # BEFORE ANY MUTATION OR STOP (see phase5_geometry_relaunch.require_bundle).
    g.require_bundle()
    snapshot = {k: read_dev_default(k) for k in PINNED}
    report = {"snapshot": snapshot, "screen_locked": g.screen_is_locked(),
              "cap_seconds": CAP_SECONDS,
              "lead_seconds": LEAD_SECONDS,
              "design": DESIGN,
              "morph_from": MORPH_FROM, "morph_to": MORPH_TO,
              "expected_warning_at_s": CAP_SECONDS - LEAD_SECONDS}
    try:
        if not g.stop_app():
            print(json.dumps({"verdict": "ABORT_INSTANCE_SURVIVED_TERM"}))
            return
        for k, flag in PINNED.items():
            subprocess.run(["defaults", "write", DEV_DOMAIN, k, flag, WANTED[k]], check=True)
        written = {k: read_dev_default(k) for k in PINNED}
        report["overrides_written"] = written
        # **ASSERTED, not noted.** A pin that did not land leaves the row reading
        # whatever appearance this machine had selected, and the geometry above is
        # correct for exactly one of three — so the failure would present as
        # REFUSED with every mechanical check green, which is how this row spent
        # its life dead. `defaults` reads floats back with formatting of its own,
        # so the numbers are compared as numbers and the design as a string.
        landed = all(
            same_default(flag, written[k], WANTED[k])
            for k, flag in PINNED.items()
            if written.get(k) is not None)
        report["overrides_landed"] = landed and None not in written.values()
        if not report["overrides_landed"]:
            print(json.dumps({"verdict": "ABORT_OVERRIDES_DID_NOT_LAND",
                              "wanted": WANTED, "read_back": written}, indent=2))
            return

        # This row opens the bundle itself rather than through `start_app`, so it
        # asks for the same refusal explicitly.
        g.require_bundle()
        # `open` does not pass env vars, so the endpoint is armed with --env.
        subprocess.run(["open", "-n", "--env", "EW_FAULT_INJECTION=1", g.BUNDLE],
                       capture_output=True)
        deadline, pid = time.time() + 30, None
        while time.time() < deadline:
            pids = g.dev_pids()
            if len(pids) == 1:
                pid = pids[0]
                break
            time.sleep(0.2)  # test-fixture-timer: process-table polling
        if not pid:
            # NAMES THE CAUSE. This row opens the bundle itself rather than
            # through `start_app`, so it carries the same distinction by hand:
            # the build was present at `require_bundle` and still produced no
            # instance, which is an incomplete or unsignable deploy — not the
            # product failing to start. Nothing was measured either way.
            print(json.dumps({"verdict": "ABORT_LAUNCH_FAILED", "bundle": g.BUNDLE}))
            return
        report["pid"] = pid
        g.await_idle()

        # Somewhere harmless for the transcript to land.
        pt.ensure()  # best effort; a missing paste target never blocks a row

        before = set(g.visible_overlays(pid))
        bounds = Bounds(pid)
        bounds.start()

        since = LOG.stat().st_size
        clip_path = str(OUT / "warning-morph.mov")
        locked = False
        with w.record(HOLD_SECONDS + 8, save_path=clip_path) as clip:
            locked = rk.double_press_record_key()
            if locked:
                # FRAMES CAPTURED LIVE, BY WINDOW ID — not extracted from the
                # video afterwards. The video records the SCREEN, so with the
                # display locked every extracted frame is the login window; a
                # window-targeted capture reads the pill's own backing store and
                # is immune to that. It must be taken while the presentation is
                # up, because the store is torn down when it ends.
                live = [i for i in g.visible_overlays(pid) if i not in before]
                w1 = live[0] if len(live) == 1 else None
                expected_at = CAP_SECONDS - LEAD_SECONDS
                began = time.time()
                shots = {}
                for label, at in (("before-warning", expected_at - 5),
                                  ("at-warning", expected_at + 2),
                                  ("after-warning", expected_at + 8)):
                    # deadline-fallback: the cap warning is driven by elapsed
                    # RECORDING time inside the app; there is no earlier signal
                    # to wait on, and the event it emits goes to PostHog rather
                    # than to the file sink. Offsets are absolute from the start
                    # of the hold, so a slow capture cannot drift the next one.
                    time.sleep(max(0.0, at - (time.time() - began)))
                    if w1:
                        path = str(OUT / f"{label}.png")
                        if g.capture_window(w1, path):
                            shots[label] = path
                report["live_frames"] = shots
                time.sleep(max(0.0, HOLD_SECONDS - (time.time() - began)))
                rk.stop_after_short_hold(0.0)

        bounds.stop()
        settled = g.await_idle()

        gone_deadline = time.time() + 15
        after = set(g.visible_overlays(pid))
        while ({s["id"] for s in bounds.series} - before) & after and time.time() < gone_deadline:
            time.sleep(0.2)  # test-fixture-timer: waiting for the overlay to be ordered out
            after = set(g.visible_overlays(pid))

        started = recording_started_at(since)
        life = lc.describe(before, {s["id"] for s in bounds.series}, after)
        series = [s for s in bounds.series if s["id"] == life["window_id"]] if life["window_id"] else []

        # **THE PIN LANDING IN `defaults` IS NOT THE PILL BEING DRAWN.**
        # `PillAppearanceModel.resolvedSelection()` goes through
        # `resolve(capabilityHasWords:)`, and `LivePreviewCoordinator.wordsCapability`
        # refuses on THREE conditions — a model being removed, an unsupported engine
        # route, and the preview toggle. Only the last is a setting this row writes,
        # so a substituted design is a state the pins cannot rule out.
        #
        # Measured 2026-08-30: with the design AND the toggle both pinned and read
        # back correctly, the pill was still 288x92, which is the Level Rail. The
        # geometry below then matches nothing and both rows report REFUSED with every
        # mechanical check green — indistinguishable from the product being broken.
        #
        # So the WIDTH is the oracle, because it is the thing the geometry depends on
        # and it is observable from here. Any width but the pinned design's means a
        # different pill was drawn, and that is an ABORT: nothing was measured, and
        # saying so is the whole difference between this row and the one that spent
        # its life dead.
        drawn = sorted({s["w"] for s in series})
        report["drawn_widths"] = drawn
        if drawn and MORPH_FROM[0] not in drawn:
            print(json.dumps({
                "verdict": "ABORT_DESIGN_NOT_DRAWN",
                "pinned_design": DESIGN,
                "expected_width": MORPH_FROM[0],
                "drawn_widths": drawn,
                "why": ("the pins landed but a different pill was drawn, so the words "
                        "capability is absent for a reason this row cannot set — see "
                        "LivePreviewCoordinator.wordsCapability, which logs none of its "
                        "three refusals"),
            }, indent=2))
            return

        # The morph: the first size change at least 5s in, which is past the
        # hands-free expansion and before the cap. Reported with its offset so the
        # claim is checkable rather than asserted.
        morphs = []
        last = None
        for s in series:
            key = (s["w"], s["h"])
            if last is not None and key != last:
                morphs.append({"at_s": round(s["t"] - started, 2) if started else None,
                               "from": list(last), "to": [s["w"], s["h"]]})
            last = key

        expected = CAP_SECONDS - LEAD_SECONDS
        # TIMING ALONE IS NOT THE PREDICATE. A window that merely CHANGED SIZE
        # near the expected second passes a timing-only check, and an unrelated
        # animation is exactly that. The row's claim is a specific morph: the
        # banner adds a row to a pill whose width does not move, so require the
        # width to be UNCHANGED and the height to GROW, on the same window.
        # THE EXACT TRANSITION, not a shape near a time. "Same width, taller"
        # still admits any same-width growth near the deadline — a live preview
        # wrapping a line does exactly that. The banner's morph is a specific
        # pair of frames and the clear is its inverse.
        near = [m for m in morphs
                if m["at_s"] is not None and abs(m["at_s"] - expected) <= 4.0
                and m["from"] == MORPH_FROM and m["to"] == MORPH_TO]
        # The CLEAR: the same panel returns to the pre-banner frame, roughly four
        # seconds later, while the recording is still running.
        cleared = []
        if near:
            at = near[0]["at_s"]
            cleared = [m for m in morphs
                       if m["at_s"] is not None and m["at_s"] > at
                       and m["from"] == MORPH_TO and m["to"] == MORPH_FROM]
        report["morph_cleared"] = cleared

        report.update({
            "locked": locked,
            "settled": settled,
            "clip": clip.path,
            "clip_exists": clip.exists,
            "lifecycle": life,
            "one_window_id": len({s["id"] for s in series}) == 1 if series else None,
            "recording_started": bool(started),
            "morphs": morphs,
            "morph_near_expected": near,
        })

        # NO VIDEO-EXTRACTED FRAMES. They were written to the same paths as the
        # live window captures and, running later, silently overwrote them — and
        # a video records the SCREEN, so with the display locked every one of them
        # is the login window. The live captures in `live_frames` are the evidence.
        # Every extracted frame must EXIST. A verdict citing frames that were
        # never written is a claim nobody can go and look at.
        frames = report.get("live_frames") or {}
        report["frames_all_written"] = (
            set(frames) == {"before-warning", "at-warning", "after-warning"}
            and all(f and pathlib.Path(f).exists()
                    and pathlib.Path(f).stat().st_size > 8000 for f in frames.values()))
        morph_ok = (locked and settled and life["verdict"] == lc.OK
                    and report["one_window_id"] and near
                    and clip.exists and report["frames_all_written"])
        report["morph_row"] = "PASS" if morph_ok else "REFUSED"

        # TAKE 2 — the clear, through the production notice staged on demand.
        g.await_idle()
        clear = staged_clear_take(pid)
        report["clear_take"] = clear
        clear_frames = clear.get("frames") or {}
        # All THREE, and each non-trivial. A window whose presentation has ended
        # still captures — as a blank frame at a constant small size — so
        # "the file exists" is not evidence that anything was drawn.
        wanted = {"before-notice", "notice-visible", "after-clear"}
        clear_frames_exist = (set(clear_frames) == wanted and all(
            f and pathlib.Path(f).exists() and pathlib.Path(f).stat().st_size > 8000
            for f in clear_frames.values()))
        clear_ok = (clear.get("idle_reply") == "OK"
                    and clear.get("reply") == "OK"
                    and clear.get("idle_settled")
                    and clear.get("idle_slot_was_empty")
                    and clear.get("idle_invocation_inert")
                    and clear.get("morph") and clear.get("clear")
                    and clear.get("lifecycle") == lc.OK
                    and clear.get("recording_still_live_at_clear")
                    and clear_frames_exist
                    and 2.0 <= clear.get("cleared_after_s", 0) <= 8.0)
        report["clear_row"] = "PASS" if clear_ok else "REFUSED"
        report["verdict"] = "PASS" if (morph_ok and clear_ok) else "REFUSED"
    finally:
        # **STOP THE APP FIRST, OR THE RESTORE ONLY REACHES THE DISK.**
        # The instance this row launched is still running and its `SettingsManager`
        # holds the PINNED design and toggle, loaded at launch. Every one of those
        # properties persists on `didSet`, so the next settings change of any kind
        # writes the pinned values straight back over the restore — and the person
        # whose Mac this is would find their pill appearance silently changed, with
        # `restore_clean` reporting true because the disk was correct at the moment
        # it was read.
        #
        # The window is real and was open for the runs on #2431: the keys read back
        # absent afterwards, and a live instance could have re-persisted them at any
        # point. Killed by hand on discovery; closed here so it cannot recur.
        report["stopped_before_restore"] = g.stop_app()

        # THE SAME TYPE FLAG THE KEY WAS WRITTEN WITH. Restoring the user's own
        # appearance through `-float` would leave them on a number, which is not a
        # design at all — this row must give the machine back exactly what it took.
        for k, v in snapshot.items():
            if v is None:
                subprocess.run(["defaults", "delete", DEV_DOMAIN, k], capture_output=True)
            else:
                value = bool_word(v) if PINNED[k] == "-bool" else v
                subprocess.run(["defaults", "write", DEV_DOMAIN, k, PINNED[k], value], check=True)
        report["restored"] = {k: read_dev_default(k) for k in PINNED}
        # Compared by MEANING per key, not by dict equality: `defaults` hands a
        # bool back as `1` where it was written as `true`, so a literal comparison
        # reports a clean restore as dirty.
        report["restore_clean"] = all(
            (report["restored"][k] is None and snapshot[k] is None)
            or (report["restored"][k] is not None and snapshot[k] is not None
                and same_default(flag, report["restored"][k], snapshot[k]))
            for k, flag in PINNED.items())
        (UAT / "warning-morph.json").write_text(json.dumps(report, indent=2, default=str))
        # **`morph_row` AND `clear_row` ARE IN THE PRINTED SUMMARY.** Without them
        # a REFUSED run says which RUN failed and not which ROW, and the two fail
        # for unrelated reasons.
        print(json.dumps({k: report.get(k) for k in
                          ("verdict", "morph_row", "clear_row", "design",
                           "overrides_landed", "one_window_id", "morphs",
                           "morph_near_expected", "expected_warning_at_s",
                           "restore_clean")}, indent=2, default=str))


if __name__ == "__main__":
    main()
