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
OVERRIDES = {"EWDebugMaxRecordingSeconds": CAP_SECONDS,
             "EWDebugWarningLeadSeconds": LEAD_SECONDS}


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

    clear_frames = {"before-notice": str(OUT / "clear-before.png")}
    subprocess.run(["/usr/sbin/screencapture", "-x", "-o", clear_frames["before-notice"]],
                   capture_output=True)
    out["reply"] = fi.send("force_auto_stop_unavailable_notice")
    fired_at = time.time()
    time.sleep(1.0)  # settle: let the banner compose before capturing it
    clear_frames["notice-visible"] = str(OUT / "clear-visible.png")
    subprocess.run(["/usr/sbin/screencapture", "-x", "-o", clear_frames["notice-visible"]],
                   capture_output=True)
    time.sleep(9.0)  # deadline-fallback: the notice is armed `dismissAfter: 4.0`
    # and there is no signal for "the clear fired"; outliving it IS the
    # observation, so this waits comfortably past it and reads the series.

    clear_frames["after-clear"] = str(OUT / "clear-after.png")
    subprocess.run(["/usr/sbin/screencapture", "-x", "-o", clear_frames["after-clear"]],
                   capture_output=True)
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
    snapshot = {k: read_dev_default(k) for k in OVERRIDES}
    report = {"snapshot": snapshot, "cap_seconds": CAP_SECONDS,
              "lead_seconds": LEAD_SECONDS,
              "expected_warning_at_s": CAP_SECONDS - LEAD_SECONDS}
    try:
        if not g.stop_app():
            print(json.dumps({"verdict": "ABORT_INSTANCE_SURVIVED_TERM"}))
            return
        for k, v in OVERRIDES.items():
            subprocess.run(["defaults", "write", DEV_DOMAIN, k, "-float", str(v)], check=True)
        report["overrides_written"] = {k: read_dev_default(k) for k in OVERRIDES}

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
            print(json.dumps({"verdict": "ABORT_NO_INSTANCE"}))
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
                time.sleep(HOLD_SECONDS)  # deadline-fallback: the cap warning is
                # driven by elapsed RECORDING time inside the app; there is no
                # earlier signal to wait on, and the log line it would emit goes
                # to PostHog rather than to the file sink.
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

        # Frames on both sides of the predicted warning, so it can be READ rather
        # than inferred from a rectangle changing size.
        if clip.exists and started:
            # Seconds into the CLIP at which the app's recording began, so a frame
            # can be asked for by its offset into the RECORDING.
            offset = started - clip.started_at if getattr(clip, "started_at", None) else 0
            for label, at in (("before-warning", expected - 4), ("at-warning", expected + 2),
                              ("after-warning", expected + 8)):
                report.setdefault("frames", {})[label] = clip.frame_at(
                    max(0.0, at + offset), save_path=str(OUT / f"{label}.png"))

        # Every extracted frame must EXIST. A verdict citing frames that were
        # never written is a claim nobody can go and look at.
        frames = report.get("frames") or {}
        report["frames_all_written"] = bool(frames) and all(
            f and pathlib.Path(f).exists() for f in frames.values())
        morph_ok = (locked and settled and life["verdict"] == lc.OK
                    and report["one_window_id"] and near
                    and clip.exists and report["frames_all_written"])
        report["morph_row"] = "PASS" if morph_ok else "REFUSED"

        # TAKE 2 — the clear, through the production notice staged on demand.
        g.await_idle()
        clear = staged_clear_take(pid)
        report["clear_take"] = clear
        clear_frames = clear.get("frames") or {}
        clear_frames_exist = bool(clear_frames) and all(
            f and pathlib.Path(f).exists() for f in clear_frames.values())
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
        for k, v in snapshot.items():
            if v is None:
                subprocess.run(["defaults", "delete", DEV_DOMAIN, k], capture_output=True)
            else:
                subprocess.run(["defaults", "write", DEV_DOMAIN, k, "-float", v], check=True)
        report["restored"] = {k: read_dev_default(k) for k in OVERRIDES}
        report["restore_clean"] = report["restored"] == snapshot
        (UAT / "warning-morph.json").write_text(json.dumps(report, indent=2, default=str))
        print(json.dumps({k: report.get(k) for k in
                          ("verdict", "one_window_id", "morphs", "morph_near_expected",
                           "expected_warning_at_s", "restore_clean")}, indent=2, default=str))


if __name__ == "__main__":
    main()
