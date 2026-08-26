"""Preview growth, captured with `wispr_eyes.record` (#2377 chunk 6, row 2).

Validates the new recorder against a real scorecard row: the reading-well pill
must grow as words arrive — empty, one line, several — without clipping.

Growth is judged from the VIDEO plus the window's own bounds over time, not from
a screenshot taken at a guessed instant. A screenshot can only answer "was it
this tall at the moment I asked"; the row is about a sequence.
"""

import json
import pathlib
import subprocess
import sys
import threading
import time

sys.path.insert(0, str(pathlib.Path(__file__).parent))

import phase5_overlay_lifecycle as lc  # noqa: E402
import phase5_paste_target as pt  # noqa: E402
import phase5_record_key as rk  # noqa: E402
import wispr_eyes as w  # noqa: E402

UAT = pathlib.Path(
    "/Users/m4pro_sv/Developer/EnviousLabs/EnviousWispr/.validation/runs/2377-phase5-live-uat"
)
OUT = UAT / "preview-growth"
OUT.mkdir(parents=True, exist_ok=True)
LOG = pathlib.Path.home() / "Library/Logs/EnviousWispr/app.log"

SENTENCE = (
    "The quarterly numbers came in ahead of plan this month. "
    "Revenue grew across every region we track. "
    "The team shipped four features and closed eleven bugs. "
    "Customer retention held steady at ninety four percent. "
    "We expect the same trajectory through the end of the year."
)


def dev_pids():
    out = subprocess.run(["ps", "-eo", "pid=,command="], capture_output=True, text=True).stdout
    needle = "EnviousWispr Local.app/Contents/MacOS/" + "EnviousWispr"
    return sorted(int(l.split(None, 1)[0]) for l in out.splitlines()
                  if needle in l and "/bin/zsh" not in l and "python3" not in l)


def visible_overlays(pid):
    """EVERY visible overlay-layer window, keyed by id.

    The previous revision returned `best` — the LAST window the enumeration
    happened to yield — which is arbitrary, not an identification. Keeping them
    all lets `phase5_overlay_lifecycle` decide which one was the pill, and lets
    the report show what was rejected.
    """
    import Quartz

    info = Quartz.CGWindowListCopyWindowInfo(Quartz.kCGWindowListOptionAll, Quartz.kCGNullWindowID)
    got = {}
    for x in info or []:
        if x.get("kCGWindowOwnerPID") != pid or not x.get("kCGWindowIsOnscreen"):
            continue
        if (x.get("kCGWindowLayer") or 0) <= 0:
            continue
        b = x.get("kCGWindowBounds") or {}
        got[x.get("kCGWindowNumber")] = {
            "w": round(b.get("Width", 0)), "h": round(b.get("Height", 0)),
            "x": round(b.get("X", 0)), "y": round(b.get("Y", 0))}
    return got


class Heights(threading.Thread):
    """Every visible overlay window's bounds over time.

    Samples ALL of them rather than one, because which one is the pill is not
    knowable until the recording has ended — the identification needs the window
    to have disappeared. Filtering happens afterwards, against the confirmed id.
    """

    def __init__(self, pid):
        super().__init__(daemon=True)
        self.pid, self.running, self.series = pid, True, []

    def run(self):
        while self.running:
            for wid, m in visible_overlays(self.pid).items():
                self.series.append({"t": round(time.time(), 2), "id": wid, **m})
            time.sleep(0.05)  # test-fixture-timer: window-server sampling cadence

    def stop(self):
        self.running = False
        self.join(timeout=2)


def await_idle(timeout=30.0):
    deadline = time.time() + timeout
    while time.time() < deadline:
        t = LOG.read_text(errors="replace")
        if max(t.rfind("dictation_terminal"), t.rfind("Clipboard cleanup")) > t.rfind("Recording started"):
            return True
        time.sleep(0.25)  # test-fixture-timer: log-polling cadence
    return False


def growth_segment(series, start_t=None, end_t=None):
    """The longest contiguous same-width run INSIDE the recording window.

    ONE TAKE CONTAINS SEVERAL PRESENTATIONS, and only one of them is this row's
    subject. Measured 2026-08-25, the size series across a single dictation:

        398x34, 400x34, 402x34        the reading well arriving and settling
        400x34 -> 78 -> 99 -> 120 -> 141 -> 162   the growth this row is about
        152x44, 131x44, 129x44        the pill collapsing after the stop

    So a width-constant check over the WHOLE take reports the width varying
    129..402 and refuses a perfectly correct pill. The reading well's own
    documentation is the reason the segment is defined by width rather than by a
    time window: it is "content-sized from the first frame so it does not visibly
    snap as lines wrap" (`SettingsEnums.swift`), so constant width IS its identity
    while the height is what moves.

    Segmenting on the modal width is data-driven; a size or time threshold would
    be a constant invented here, and the collapse frames are only "small" relative
    to a number nobody measured.
    """
    # BOUND BY THE RECORDING, not by the whole capture. The longest same-width
    # run is not necessarily the growth: a longer, stable presentation AFTER the
    # stop, with three height changes of its own, would win on length alone and
    # the row would report growth that happened once the take was over.
    if start_t is not None:
        series = [x for x in series if x["t"] >= start_t]
    if end_t is not None:
        series = [x for x in series if x["t"] <= end_t]

    best, run = [], []
    for s in series:
        if run and s["w"] == run[-1]["w"]:
            run.append(s)
        else:
            run = [s]
        if len(run) > len(best):
            best = list(run)
    return best


def _transitions(series):
    """Only the samples where the pill's size actually changed."""
    out, last = [], None
    for s in series:
        key = (s["w"], s["h"])
        if key != last:
            out.append({"t": s["t"], "w": s["w"], "h": s["h"]})
            last = key
    return out


def recording_window(since_bytes):
    """(start, end) wall-clock of the take, from the app's OWN markers.

    The harness knows when it PRESSED; the app knows when it started recording
    and when the pipeline reached its terminal. Those differ by the chain window,
    any double-press retry, and the whole polish tail.
    """
    import datetime as _dt

    with LOG.open("rb") as fh:
        fh.seek(since_bytes)
        lines = fh.read().decode("utf-8", errors="replace").splitlines()

    def stamp(line):
        return _dt.datetime.fromisoformat(line[1:line.index("]")]).timestamp()

    starts = [stamp(l) for l in lines if "Recording started" in l and l.startswith("[")]
    ends = [stamp(l) for l in lines if "dictation_terminal" in l and l.startswith("[")]
    return (starts[-1] if starts else None), (ends[-1] if ends else None)


def raw_ids(series):
    return {s["id"] for s in series}


def main():
    pids = dev_pids()
    if len(pids) != 1:
        print(json.dumps({"verdict": "ABORT_INSTANCE", "found": pids}))
        return
    pid = pids[0]
    w.connect()
    await_idle()

    # Somewhere harmless for the transcript to land. REFUSES rather than
    # proceeding: a run that pastes into the operator's terminal is worse than a
    # run that did not start.
    pt.ensure()  # best effort; a missing paste target never blocks a row

    before = set(visible_overlays(pid))

    heights = Heights(pid)
    heights.start()

    clip_path = str(OUT / "preview-growth.mov")
    # SYNTHESIZE BEFORE RECORDING, then play SYNCHRONOUSLY inside the held window.
    # `record_tts` is not usable here: it drives its OWN push-to-talk hold, so
    # calling it inside a hands-free lock is two overlapping drives of one app.
    # Measured 2026-08-25 — the first attempt did exactly that and the take came
    # back `RAW ASR: Rarely have I made the same same choice` against a
    # five-sentence script, with ASR=0.075s. Almost nothing was captured, and the
    # row would have been read as the pill failing to grow.
    # Shape owned by uat-testing.md RULE: tts-drills-prove-playback-inside-the-window.
    since_log = LOG.stat().st_size
    audio = w.tts(SENTENCE)
    duration = w._audio_duration(audio)
    print(f"  speech is {duration:.1f}s")

    locked = False
    with w.record(duration + 12, save_path=clip_path) as clip:
        # HOLD THE PILL WITH HANDS-FREE, not a bare single press. A single press is
        # push-to-talk and the app answers it with `Debounce timer fired — stopping
        # PTT (no double-press detected)` in the SAME SECOND, so the take this row
        # depends on may never survive long enough to grow.
        # `double_press_record_key` refuses on the app's own
        # `Hands-free mode activated`, so a failure here is a refusal rather than a
        # short recording that still produces a plausible series.
        locked = rk.double_press_record_key()
        if locked:
            # Synchronous: when this returns the audio has provably played in full.
            subprocess.run(["afplay", audio])
            rk.stop_after_short_hold(0.0)

    heights.stop()
    settled = await_idle()

    # WAIT FOR THE PILL TO GO, do not sample once at idle. The pipeline reaches its
    # terminal marker while the overlay is still on screen, so a single snapshot
    # taken at idle finds the window still present and the lifecycle check reports
    # NONE — a refusal caused by reading too early rather than by anything wrong.
    gone_deadline = time.time() + 15
    after = set(visible_overlays(pid))
    while (set(raw_ids(heights.series)) - before) & after and time.time() < gone_deadline:
        time.sleep(0.2)  # test-fixture-timer: waiting for the overlay to be ordered out
        after = set(visible_overlays(pid))

    raw = heights.series
    life = lc.describe(before, {s["id"] for s in raw}, after)

    # ONLY the lifecycle-confirmed window. Mixing several windows' bounds into one
    # series manufactures growth out of two windows of different sizes.
    series = [s for s in raw if s["id"] == life["window_id"]] if life["window_id"] else []
    hs = [s["h"] for s in series]
    ws = [s["w"] for s in series]
    report = {
        "pid": pid,
        "clip": clip.path,
        "clip_exists": clip.exists,
        "locked": locked,
        "settled": settled,
        "lifecycle": life,
        "samples_all_windows": len(raw),
        "samples": len(series),
        "distinct_heights": sorted(set(hs)),
        "min_height": min(hs) if hs else None,
        "max_height": max(hs) if hs else None,
        "grew": bool(hs and max(hs) > min(hs)),
        # KEEP THE WIDTHS, not just whether they were constant. A bare boolean
        # can say the width varied and not what between, so a reader cannot tell a
        # one-point rounding wobble from the pill changing size.
        "distinct_widths": sorted(set(ws)),
        "width_constant": len(set(ws)) == 1 if series else None,
        "one_window_id": len({s["id"] for s in series}) == 1 if series else None,
        # THE SERIES ITSELF, so a verdict can be re-adjudicated without a rerun.
        # Collapsed to transitions: consecutive identical (w,h) samples carry no
        # information and 341 rows of them bury the handful that do.
        "transitions": _transitions(series),
    }

    rec_start, rec_end = recording_window(since_log)
    report["recording_window"] = {"start": rec_start, "end": rec_end}
    seg = growth_segment(series, start_t=rec_start, end_t=rec_end)
    seg_h = [x["h"] for x in seg]
    report["growth_segment"] = {
        "samples": len(seg),
        "width": seg[0]["w"] if seg else None,
        "heights": sorted(set(seg_h)),
        "min_height": min(seg_h) if seg_h else None,
        "max_height": max(seg_h) if seg_h else None,
        "grew": bool(seg_h and max(seg_h) > min(seg_h)),
        # Three distinct heights is the row's own wording — empty, one line,
        # several — so two would satisfy "it grew" without showing it wrap twice.
        "distinct_heights": len(set(seg_h)),
    }
    # Every precondition is part of the verdict. A growth series read from an
    # unidentified window, or taken while the pipeline was still running, is not
    # evidence for this row however convincing the numbers look.
    g = report["growth_segment"]
    report["verdict"] = ("PASS" if (locked and settled and life["verdict"] == lc.OK
                                    and rec_start and rec_end
                                    and report["one_window_id"]
                                    and g["grew"] and g["distinct_heights"] >= 3
                                    and clip.exists)
                         else "REFUSED")

    # Frames at the extremes, so the verdict can be looked at rather than trusted.
    if clip.exists and series:
        t0 = series[0]["t"]
        for label, target in (("empty", 0.5), ("mid", 6.0), ("tallest", 12.0)):
            got = clip.frame_at(target, save_path=str(OUT / f"{label}.png"))
            report.setdefault("frames", {})[label] = got

    (UAT / "preview-growth.json").write_text(json.dumps(report, indent=2, default=str))
    print(json.dumps(report, indent=2, default=str)[:1800])


if __name__ == "__main__":
    main()
