"""Escape Recovery's rail: hover pauses it, leaving restarts it (#2377 chunk 6, C6C).

Phase 5 deleted the recovery pill's `dismissTask` and `onExpire`, so the
director's clock is the only thing that dismisses this rail. The catalog arms it
`.after(seconds: 3, pausesOnHover: true)` (`PillCatalog.swift:320`), and until the
cutover there were TWO three-second timers running side by side — a panel-level
one and the view's own — which cloud review caught only because the rail finished
while the pill was still on screen. This row is the outside proof that one
remains.

**ONE HUMAN ACTION IS REQUIRED AND IT CANNOT BE AUTOMATED. THE REASON IS NOT THAT
NOBODY HAS TRIED HARD ENOUGH.** Two separate facts have to hold at once:

 - The cancel shortcut is a plain key, so `HotkeyService` registers it through
   Carbon `RegisterEventHotKey`, and WindowServer does not deliver synthetic
   events to a Carbon hotkey on this OS. A `simulate_input` press produces NO log
   line at all — `cancel()` is never entered
   (`tools-and-apps.md` FACT: synthetic-escape-does-not-reach-a-carbon-hotkey).

 - The obvious alternative is excluded BY DESIGN, which is worth stating because
   it looks like an unexplored option. There is a second cancel trigger,
   `UserCancelTrigger.cancelButton`, wired to a real button
   (`MainWindowView.swift:113`) — and `PipelineVocabulary.swift:282` says
   "Escape Recovery is therefore offered for `.shortcut` only; `.cancelButton`
   keeps discarding immediately". So driving the button reaches a DIFFERENT
   outcome and would produce no rail to measure. A run that tapped it and
   reported no rail would be reporting the product working.

So: the operator presses the cancel shortcut ONCE, at a prompt. Everything before
and after it is automated, and the run refuses rather than waiting forever.
"""

import json
import pathlib
import subprocess
import sys
import threading
import time

sys.path.insert(0, str(pathlib.Path(__file__).parent))

import phase5_geometry_relaunch as g  # noqa: E402
import phase5_paste_target as pt  # noqa: E402
import phase5_record_key as rk  # noqa: E402
import simulate_input as si  # noqa: E402
import wispr_eyes as w  # noqa: E402

UAT = pathlib.Path(
    "/Users/m4pro_sv/Developer/EnviousLabs/EnviousWispr/.validation/runs/2377-phase5-live-uat"
)
OUT = UAT / "recovery-rail"
OUT.mkdir(parents=True, exist_ok=True)
LOG = pathlib.Path.home() / "Library/Logs/EnviousWispr/app.log"

RAIL_DWELL = 3.0            # PillCatalog.swift:320
WAIT_FOR_HUMAN = 45.0
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


def wait_for_cancel(since_bytes, timeout):
    """Poll the app's OWN cancel marker, never elapsed time or a keypress echo."""
    deadline = time.time() + timeout
    while time.time() < deadline:
        if "terminal cancelled" in tail_since(since_bytes):
            return True
        time.sleep(0.2)  # test-fixture-timer: log-polling cadence for the human press
    return False


def main():
    pids = g.dev_pids()
    if len(pids) != 1:
        print(json.dumps({"verdict": "ABORT_INSTANCE", "found": pids}))
        return
    pid = pids[0]
    report = {"pid": pid, "dwell_seconds": RAIL_DWELL}

    pt.ensure()  # best effort; a missing paste target never blocks a row

    audio = w.tts(SPEECH)
    g.await_idle()

    rails = Rails(pid)
    rails.start()
    since = LOG.stat().st_size

    clip_path = str(OUT / "recovery-rail.mov")
    with w.record(WAIT_FOR_HUMAN + 30, save_path=clip_path) as clip:
        if not rk.double_press_record_key():
            rails.stop()
            print(json.dumps({"verdict": "REFUSED", "error": "hands-free did not engage"}))
            return
        subprocess.run(["afplay", audio])

        before_cancel = set(g.visible_overlays(pid))
        print("\n" + "=" * 62)
        print("  PRESS YOUR CANCEL SHORTCUT NOW  (Escape, unless you rebound it)")
        print("  The recording is live and waiting. Everything after this is")
        print(f"  automatic. Refusing in {WAIT_FOR_HUMAN:.0f}s if nothing arrives.")
        print("=" * 62 + "\n", flush=True)

        cancelled = wait_for_cancel(since, WAIT_FOR_HUMAN)
        report["cancelled"] = cancelled
        if not cancelled:
            # NEVER LEAVE A RECORDING RUNNING on a refusal — it captures ambient
            # audio and poisons every later run in the session.
            rk.stop_after_short_hold(0.0)
            rails.stop()
            report["verdict"] = "NOT_ATTEMPTED_NO_HUMAN_PRESS"
            (UAT / "recovery-rail.json").write_text(json.dumps(report, indent=2, default=str))
            print(json.dumps(report, indent=2, default=str))
            return

        # The rail is whatever became visible AFTER the cancel.
        rail, deadline = None, time.time() + 6
        while time.time() < deadline:
            fresh = {i: m for i, m in g.visible_overlays(pid).items() if i not in before_cancel}
            if fresh:
                if len(fresh) > 1:
                    report["error"] = f"ambiguous rail: {sorted(fresh)}"
                    break
                wid, meta = next(iter(fresh.items()))
                rail = dict(meta, id=wid)
                break
            time.sleep(0.05)  # test-fixture-timer: window-server sampling cadence
        report["rail"] = rail

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
    report["clip"] = clip.path
    report["clip_exists"] = clip.exists
    report["verdict"] = ("PASS" if (report.get("cancelled") and report.get("rail")
                                    and report.get("survived_hover")
                                    and report.get("expired_after_leaving"))
                         else "REFUSED")
    (UAT / "recovery-rail.json").write_text(json.dumps(report, indent=2, default=str))
    print(json.dumps(report, indent=2, default=str))


if __name__ == "__main__":
    main()
