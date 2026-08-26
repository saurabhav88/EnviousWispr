"""The #1060 in-panel warning, morphing INTO the pill already on screen.

#2377 chunk 6 (C6B). Phase 5's claim is that the notice rides in the SAME atomic
frame as the recording it belongs to, so the row's subject is not "a banner
appeared" — it is "the banner appeared WITHOUT a second window and WITHOUT the
pill being torn down and rebuilt". The retained window id is what carries that,
so it is the assertion rather than the screenshot.

**Driven by the production DEBUG override, not a new seam.** `TimingConstants`
already honours `EWDebugMaxRecordingSeconds` and `EWDebugWarningLeadSeconds`, and
its own comment says why they exist: "so Live UAT can drive the full
warning -> cap -> transcribe cycle in ~90s instead of an hour"
(`Constants.swift:366`). Codex ruled against adding a Phase 5 fault seam for this,
and it would have been a second answer to a question production already answers.

**THE OVERRIDE READS `UserDefaults.standard`, WHICH IS THE DEV DOMAIN.** Every
other preset in this harness goes to the shared `com.enviouswispr.app` store
(`SettingsDefaults.store` redirects the unified keys there), but these two are
read straight off `.standard`, so for the dev build they live in
`com.enviouswispr.app.dev`. Writing them to the shared domain changes nothing and
the run then reports the warning never firing.

**The CLEAR half of this row is not reachable and is not attempted.** The notice
is armed with `dismissAfter: nil` and the coordinator's own comment says it "stays
until the recording stops; cleared by the transition out of recording"
(`DictationLifecycleCoordinator.swift:285-294`). So there is no supported action
that clears the notice while the pill remains — the clear IS the recording ending.
Recorded as BLOCKED_PRODUCT_TRIGGER per Codex's ruling, with the suite carrying
the same-id clear instead.

No speech is needed: the cap warning is driven by elapsed recording time.
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
import phase5_record_key as rk  # noqa: E402
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

        pid = g.start_app()
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
        near = [m for m in morphs
                if m["at_s"] is not None and abs(m["at_s"] - expected) <= 4.0]

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

        report["verdict"] = ("PASS" if (locked and settled and life["verdict"] == lc.OK
                                        and report["one_window_id"] and near and clip.exists)
                             else "REFUSED")
        # The clear is not attempted; see the module docstring.
        report["clear_row"] = "BLOCKED_PRODUCT_TRIGGER"
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
