"""Escape Recovery's rail: hover pauses it, leaving restarts it (#2377 chunk 6, C6C).

Phase 5 deleted the recovery pill's `dismissTask` and `onExpire`, so the
director's clock is the only thing that dismisses this rail. The catalog arms it
`.after(seconds: 3, pausesOnHover: true)` (`PillCatalog.swift:320`), and until the
cutover there were TWO three-second timers running side by side — a panel-level
one and the view's own — which cloud review caught only because the rail finished
while the pill was still on screen. This row is the outside proof that one
remains.

**NO HUMAN IS REQUIRED, and the reasoning that said one was is worth keeping
because it was confidently wrong.** Three cancel paths were enumerated and all
three genuinely fail:

 - a synthetic press cannot reach the DEFAULT cancel shortcut, because a plain
   key is registered through Carbon `RegisterEventHotKey` and WindowServer does
   not deliver synthetic events to it (`tools-and-apps.md`
   FACT: synthetic-escape-does-not-reach-a-carbon-hotkey);
 - `UserCancelTrigger.cancelButton` is excluded BY DESIGN —
   `PipelineVocabulary.swift:282` says "Escape Recovery is therefore offered for
   `.shortcut` only; `.cancelButton` keeps discarding immediately";
 - the debug endpoint's `force_cancel` calls `kernel.cancel()`
   (`KernelDictationDriver.swift:1363`) with no user trigger, so it is a system
   cancel and reaches no rail.

**That enumeration swept the cancel TRIGGERS and never asked whether the
shortcut's own BINDING could change.** Rebind cancel to a BARE MODIFIER and it
stops being Carbon-registrable at all: `HotkeyService.swift:401` guards
registration on `isCarbonRegistrable`, and the Carbon handler's own comment says
"Modifier-only hotkeys are handled separately via NSEvent flagsChanged monitors,
which work globally regardless of app focus". Those monitors DO see synthetic
events, and the path still reaches `.shortcut` — the one origin eligible for
recovery. So the fourth path was a property of the binding rather than of the
trigger set, which is why sweeping triggers could never find it.

The recipe is not invented here: `escape_recovery_uat.py` already presets left
Control (keycode 59, `LCTRL = 59  # left Control, a bare modifier: the event-tap
path`) and its typed `snapshot`/`restore` are reused rather than re-derived —
that restore already caught a silent failure where a value captured as `1` was
handed back as `-bool 1`, exited 255, and left the founder's own preference
changed.
"""

import json
import pathlib
import subprocess
import sys
import threading
import time

sys.path.insert(0, str(pathlib.Path(__file__).parent))

import escape_recovery_uat as eru  # noqa: E402
import phase5_geometry_relaunch as g  # noqa: E402
import phase5_paste_target as pt  # noqa: E402
import wispr_eyes as rk  # noqa: E402  (record-key helpers; merged in #2425)
import simulate_input as si  # noqa: E402
import wispr_eyes as w  # noqa: E402

UAT = pathlib.Path(
    "/Users/m4pro_sv/Developer/EnviousLabs/EnviousWispr/.validation/runs/2377-phase5-live-uat"
)
OUT = UAT / "recovery-rail"
OUT.mkdir(parents=True, exist_ok=True)
LOG = pathlib.Path.home() / "Library/Logs/EnviousWispr/app.log"

RAIL_DWELL = 3.0            # PillCatalog.swift:320
DOMAIN = "com.enviouswispr.app"
REBIND_KEYS = ("cancelKeyCode", "cancelModifiersRaw", "escapeRecoveryEnabled")
LCTRL = eru.LCTRL           # 59, a bare modifier: not Carbon-registrable
SPEECH = ("This take exists only to be cancelled, so the escape recovery rail "
          "has something to offer back.")


class Rails(threading.Thread):
    """Every visible overlay window over time, so the rail can be found later."""

    def __init__(self, pid):
        super().__init__(daemon=True)
        self.pid, self.running, self.series = pid, True, []

    def run(self):
        while self.running:
            self.series.append({"t": time.time(), "windows": g.visible_overlays(self.pid)})
            time.sleep(0.05)  # test-fixture-timer: window-server sampling cadence
    def stop(self):
        self.running = False
        self.join(timeout=2)


def tail_since(since_bytes):
    with LOG.open("rb") as fh:
        fh.seek(since_bytes)
        return fh.read().decode("utf-8", errors="replace")


# The marker is the RECOVERY DECISION, not a generic cancel.
# `RecordingSessionKernel.swift:1721` logs this on the branch that sets
# `finalizationDisposition = .escapeRecovery`, which is precisely the state this
# row's rail depends on. A cancel that arrives and finds recovery UNAVAILABLE
# takes the sibling branch (`escapeRecoveryUnavailable = true`, then
# `finishTerminal(.cancelled)`) and produces no rail — so a broader marker would
# report a rail that was never going to appear.
RECOVERY_MARKER = "escape recovery: keeping this take"


def wait_for_cancel(since_bytes, timeout):
    """Poll the app's OWN recovery-decision marker, never elapsed time."""
    deadline = time.time() + timeout
    while time.time() < deadline:
        if RECOVERY_MARKER in tail_since(since_bytes):
            return True
        time.sleep(0.2)  # test-fixture-timer: log-polling cadence
    return False


def main():
    # SCREEN LOCK FIRST. A locked screen makes every visual verdict in this row
    # meaningless while the run still looks real.
    if g.screen_is_locked():
        print(json.dumps({"verdict": "ABORT_SCREEN_LOCKED"}))
        return

    if len(g.dev_pids()) != 1:
        print(json.dumps({"verdict": "ABORT_INSTANCE", "found": g.dev_pids()}))
        return
    report = {"dwell_seconds": RAIL_DWELL}

    # PRESET WITH THE APP STOPPED, then relaunch — a running instance owns these
    # keys and flushes its own copy on quit.
    before = eru.snapshot(REBIND_KEYS)
    report["settings_before"] = {k: v[0] for k, v in before.items()}
    g.stop_app()
    subprocess.run(["defaults", "write", DOMAIN, "cancelKeyCode", "-int", str(LCTRL)], check=True)
    subprocess.run(["defaults", "write", DOMAIN, "cancelModifiersRaw", "-int", "0"], check=True)
    subprocess.run(["defaults", "write", DOMAIN, "escapeRecoveryEnabled", "-bool", "YES"], check=True)
    try:
        # `start_app` raises with the exact cause; `ABORT_NO_INSTANCE` here
        # could not tell a missing build from an app that crashes on launch.
        pid = g.start_app()
        report["pid"] = pid

        pt.ensure()  # best effort; a missing paste target never blocks a row

        audio = w.tts(SPEECH)
        g.await_idle()

        rails = Rails(pid)
        rails.start()
        since = LOG.stat().st_size

        clip_path = str(OUT / "recovery-rail.mov")
        with w.record(50, save_path=clip_path) as clip:
            if not rk.double_press_record_key():
                rails.stop()
                report["verdict"] = "REFUSED"
                report["error"] = "hands-free did not engage"
                return report
            subprocess.run(["afplay", audio])

            before_cancel = set(g.visible_overlays(pid))
            # The cancel is now a BARE MODIFIER, so it arrives through the NSEvent
            # flagsChanged monitors rather than Carbon — which is the whole reason a
            # synthetic press works here and does not on the default binding.
            si.modifier_down(LCTRL)
            time.sleep(0.04)  # test-fixture-timer: modifier down/up separation
            si.modifier_up(LCTRL)

            cancelled = wait_for_cancel(since, 15.0)
            report["cancelled"] = cancelled
            if not cancelled:
                # NEVER LEAVE A RECORDING RUNNING on a refusal — it captures ambient
                # audio and poisons every later run in the session.
                rk.stop_after_short_hold(0.0)
                rails.stop()
                report["verdict"] = "REFUSED_CANCEL_NEVER_ARRIVED"
                return report

            # THE RAIL IS NOT A NEW WINDOW. The overlay is ONE RETAINED PANEL,
            # so the rail MORPHS the panel the recording pill was using rather
            # than creating a second one — the id does not change, so looking
            # for an id absent before the cancel can never find it.
            #
            # It is also not immediate: the cancel KEEPS the take and runs the
            # ordinary pipeline, so the rail is offered once that finishes.
            g.await_idle()
            rail, deadline = None, time.time() + 15
            while time.time() < deadline:
                now = g.visible_overlays(pid)
                if now:
                    if len(now) > 1:
                        report["error"] = f"ambiguous rail: {sorted(now)}"
                        break
                    wid, meta = next(iter(now.items()))
                    rail = dict(meta, id=wid)
                    break
                time.sleep(0.05)  # test-fixture-timer: window-server sampling cadence
            report["rail"] = rail
            report["same_panel_as_recording"] = (
                rail["id"] in before_cancel if rail else None)

            if rail:
                first_seen = time.time()
                # HOVER, and hold well past the dwell. If the clock is not paused the
                # rail is gone before this returns.
                si.move_mouse(rail["x"] + rail["w"] // 2, rail["y"] + rail["h"] // 2)
                hovered_at = time.time()
                time.sleep(RAIL_DWELL * 2.5)  # deadline-fallback: there is no signal
                # for "the timer would have fired"; outliving it IS the observation.
                still_there = rail["id"] in g.visible_overlays(pid)
                report["survived_hover"] = still_there
                report["hovered_for_s"] = round(time.time() - hovered_at, 2)

                si.move_mouse(20, 20)   # leave, so the dwell re-arms
                left_at = time.time()
                gone_deadline = left_at + RAIL_DWELL * 3
                while rail["id"] in g.visible_overlays(pid) and time.time() < gone_deadline:
                    time.sleep(0.05)  # test-fixture-timer: waiting for the re-armed dwell
                gone = rail["id"] not in g.visible_overlays(pid)
                report["expired_after_leaving"] = gone
                report["expired_after_s"] = round(time.time() - left_at, 2)
                report["visible_total_s"] = round(time.time() - first_seen, 2)

        rails.stop()
        g.await_idle()
        # The timeline is kept so a miss is diagnosable without another blind
        # run: what the panel WAS showing is the question a null rail raises.
        report["overlay_timeline"] = [
            {"t": round(x["t"], 2), "w": m["w"], "h": m["h"], "id": i}
            for x in rails.series for i, m in x["windows"].items()][-400:]
        report["clip"] = clip.path
        report["clip_exists"] = clip.exists
        # `restore_clean` is deliberately NOT read here — it is set in the
        # `finally` below, which downgrades a PASS if the restore did not land.
        # Reading it at this point would always find `None` and refuse every run.
        # `same_panel_as_recording` is a VERDICT INPUT, not a note. The rail
        # morphing the retained panel is the architecture this phase rests on; a
        # rail on a second window would be a different product passing this row.
        # `clip_exists` likewise — a verdict citing video nobody wrote is a claim
        # nobody can check.
        report["verdict"] = ("PASS" if (report.get("cancelled") and report.get("rail")
                                        and report.get("same_panel_as_recording")
                                        and report.get("survived_hover")
                                        and report.get("expired_after_leaving")
                                        and report.get("clip_exists"))
                             else "REFUSED")
        return report


    finally:
        # HAND THE SHORTCUT BACK ON EVERY PATH. This rebinds the founder's own
        # cancel key, so an early return that skipped the restore would leave it
        # on left Control — a destructive tidy-up wearing the word "abort".
        # Judged by a RE-READ through the typed reader, never by the write
        # having been attempted: that reader already caught a restore handing a
        # captured `1` back as `-bool 1`, exiting 255, and silently leaving the
        # founder's preference changed.
        g.stop_app()
        report["restore_ok"] = bool(eru.restore(before))
        report["settings_after"] = {k: v[0] for k, v in eru.snapshot(REBIND_KEYS).items()}
        report["restore_clean"] = report["settings_after"] == report["settings_before"]
        # Guarded for the same reason as language-hover: an unguarded raise here
        # would lose the report that records whether the restore succeeded.
        try:
            g.start_app()
        except SystemExit as exc:
            report["relaunch_error"] = str(exc)
        report.setdefault("verdict", "REFUSED")
        if report["verdict"] == "PASS" and not report["restore_clean"]:
            report["verdict"] = "REFUSED_RESTORE_FAILED"
        (UAT / "recovery-rail.json").write_text(json.dumps(report, indent=2, default=str))
        print(json.dumps(report, indent=2, default=str))


if __name__ == "__main__":
    main()
