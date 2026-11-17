"""History scroll UAT (#4586 WP-A): smoothness, row stability and travel symmetry on every tab.

For each tab (Dictations, Transcripts, Meetings) and each input kind (trackpad: phased continuous
pixel events; wheel: clicking-wheel line events), from a settled mid-list start, the driver posts
one gesture down, waits for the list to stop, then the SAME gesture up, and measures:

- hitch ms per moving second (budget 5): Apple's `xctrace` Animation Hitches template attached to
  the subject records the hitch pass; NO accessibility reads happen while it records gestures (AX
  reads run on the app's main thread and would cause the hitches they measure). Moving seconds come
  from the frame recorder (ScreenCaptureKit, out of process): per gesture, first to last frame
  whose picture changed. Every hitch in the trace counts (an idle list draws no frames, so it has
  no hitches); a trace that fails to save or export makes the number UNPROVEN, never 0.
- rows that change height after first display (budget 0): a separate layout pass repeats the same
  gestures while reading the table's visible rows (index, first text, height) about every 40 ms.
- travel symmetry (budget 2%): the table's on-screen origin is read when the list is settled
  before, between and after the two gestures; asymmetry = |down - up| / down.
- also recorded: seconds the picture kept moving after the last event of each gesture.

Known limits: synthetic trackpad events carry no device momentum phase (no fling); the pointer is
parked over the list and nobody may move the mouse or scroll during a run; the subject must have
full catalog coverage (containment_pilot.py waits for it).

Options: `--start-pt N` starts N points below the newest row (default 2400; "deep" runs use about
40000, which loads more than ten pages of 30 rows); `--idle` first samples CPU and memory for 30 s
of idle History; `--busy` runs one busy loop per performance core for the whole run (busy Mac).
Control: `--control short-return` makes the up gesture half as long (travel must FAIL).
Every run records machine conditions (load, peer builds) at start and end.

Usage: python3 m5-speed-scroll.py <pid> <subject .app> <new out dir> [--tabs Dictations,Transcripts,Meetings]
                                  [--inputs trackpad,wheel] [--repeats N] [--start-pt N] [--idle] [--busy]
                                  [--deep] [--control short-return]
  --trace-repeats N records xctrace only on the first N repeats of each tab x input (later repeats
  reuse that hitch number and add travel and row-height readings)
  --deep adds one trackpad run on Dictations from 40000 pt down (many loaded pages)
The caller holds the dev-app lock and runs the subject inside fixture.ContainedSession
(containment_pilot.py --scroll does both).
"""
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import threading
import time

HERE = Path(__file__).resolve().parent
RUNTIME_UAT = HERE.parent
WINDOW_ORIGIN = (40, 30)
WINDOW_SIZE = (1200, 820)
MID_START_PT = 4000          # how far below the newest row the first pass starts (more than one gesture, so
                             # the up gesture cannot clamp at the top)
FRESH_STEP_PT = 6000         # each later pass starts this much deeper, in rows no pass has shown yet
TRACKPAD = {"step_px": 30, "steps": 50, "interval_s": 0.008}       # 1500 pt in 0.4 s
WHEEL = {"clicks": 12, "interval_s": 0.05}                          # a brisk wheel flick
QUIET_S = 1.5                # hitch pass: no AX reads for this long after each gesture
SETTLE_S = 0.6               # the table origin must hold this long to count as stopped
SETTLE_DEADLINE_S = 15.0
XCTRACE_WINDOW_S = 10        # recording length: both gestures and their quiet periods fit inside
XCTRACE_HANG_S = 300         # #4587 hang guard; one 5 s recording took 64 s to start, record and save under load
IDLE_S = 30
DEEP_START_PT = 40000        # more than ten loaded pages of 30 rows on Dictations


def option(argv, name, default=None):
    return argv[argv.index(name) + 1] if name in argv else default


def main():
    argv = sys.argv[1:]
    if len(argv) < 3 or argv[0] in ("-h", "--help"):
        print(__doc__)
        return 2
    sys.path.insert(0, str(RUNTIME_UAT))
    sys.path.insert(0, str(HERE))
    import ui_helpers as ui
    import wispr_eyes as eyes
    import fixture
    import history_reader as hr
    import load_tools
    import scroll_analysis as sa
    from ApplicationServices import AXUIElementSetAttributeValue, AXValueCreate, kAXValueCGPointType, kAXValueCGSizeType
    from Quartz import (CGEventCreateScrollWheelEvent, CGEventPost, CGEventSetIntegerValueField,
                        CGEventSetLocation, CGPoint, CGSize, CGWarpMouseCursorPosition, kCGHIDEventTap,
                        kCGScrollEventUnitLine, kCGScrollEventUnitPixel, kCGScrollWheelEventIsContinuous,
                        kCGScrollWheelEventScrollPhase)

    pid, subject, out = int(argv[0]), Path(argv[1]), Path(argv[2])
    tabs = option(argv, "--tabs", "Dictations,Transcripts,Meetings").split(",")
    inputs = option(argv, "--inputs", "trackpad,wheel").split(",")
    repeats = int(option(argv, "--repeats", "3"))
    control = option(argv, "--control")
    start_pt = float(option(argv, "--start-pt", str(MID_START_PT)))
    trace_repeats = int(option(argv, "--trace-repeats", "99"))
    busy = "--busy" in argv
    if control not in (None, "short-return"):
        print(f"unknown control {control}", file=sys.stderr)
        return 2
    fixture._default_owner_check()
    expected_executable = fixture.require_subject_pid(pid, subject)
    recorder_bin = RUNTIME_UAT.parent.parent / "build" / "history_speed" / "frame_recorder"
    if not recorder_bin.is_file():
        raise SystemExit(f"build the frame recorder first: {recorder_bin}")
    out.mkdir(parents=True, exist_ok=False)
    eyes.find_app_pid = ui.find_app_pid = lambda *a, **kw: pid
    eyes.connect()

    def require_identity():
        if fixture._comm(pid) != expected_executable:
            raise RuntimeError(f"pid {pid} no longer runs {expected_executable}")

    # ------------------------------------------------------------------ window, tab, list
    ui.activate_app(pid)
    assert eyes.nav("History"), "History did not open"
    window = next(iter(ui.get_attr(eyes._app, "AXWindows") or []), None)
    assert window is not None, "no window"
    AXUIElementSetAttributeValue(window, "AXPosition", AXValueCreate(kAXValueCGPointType, CGPoint(*WINDOW_ORIGIN)))
    AXUIElementSetAttributeValue(window, "AXSize", AXValueCreate(kAXValueCGSizeType, CGSize(*WINDOW_SIZE)))

    def press_tab(name):
        for role in ("AXRadioButton", "AXButton"):
            control_el = eyes._find_match(window, name, role, exact=True, mx=24)
            if control_el is not None:
                return ui.perform_action(control_el, "AXPress")
        return False

    def find_table():
        table, area = hr.find_list(window)
        return (table, area) if table is not None else None

    def wait(predicate, timeout, what):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            value = predicate()
            if value:
                return value
            time.sleep(0.05)  # deadline-fallback: poll inside a signal wait bounded by `timeout`
        raise RuntimeError(f"timed out waiting for {what}")

    def table_y(table):
        """The first row's screen y: it moves exactly with the scroll position (history_reader)."""
        return hr.first_row_y(table)

    def settled(table, on_read=None):
        """Wait until the table origin holds still for SETTLE_S; return that origin y. `on_read`
        runs on every poll (the layout pass keeps sampling row heights while the list settles)."""
        last, since = table_y(table), time.monotonic()
        deadline = since + SETTLE_DEADLINE_S
        while time.monotonic() < deadline:
            time.sleep(0.05)  # deadline-fallback: paced read inside a deadline-bounded settle wait
            now = table_y(table)
            if on_read is not None:
                on_read()
            if now is None or last is None or abs(now - last) > 0.5:
                last, since = now, time.monotonic()
            elif time.monotonic() - since >= SETTLE_S:
                return now
        raise RuntimeError("the list never stopped moving")

    def visible_rows(table):
        return hr.row_heights(table, current_area["area"])

    # ------------------------------------------------------------------ input
    def post_scroll(point, unit, delta, continuous, phase=None):
        event = CGEventCreateScrollWheelEvent(None, unit, 1, int(delta))
        CGEventSetLocation(event, point)
        CGEventSetIntegerValueField(event, kCGScrollWheelEventIsContinuous, 1 if continuous else 0)
        if phase is not None:
            CGEventSetIntegerValueField(event, kCGScrollWheelEventScrollPhase, phase)
        CGEventPost(kCGHIDEventTap, event)

    def gesture(kind, point, direction, scale=1.0):
        """Post one gesture; direction -1 scrolls toward older rows (down). Returns
        (first event time, last event time) in time.monotonic() seconds."""
        began = time.monotonic()
        if kind == "trackpad":
            steps = max(1, round(TRACKPAD["steps"] * scale))
            post_scroll(point, kCGScrollEventUnitPixel, 0, True, 1)   # began
            for _ in range(steps):
                post_scroll(point, kCGScrollEventUnitPixel, direction * TRACKPAD["step_px"], True, 2)
                time.sleep(TRACKPAD["interval_s"])  # settle: input pacing is the gesture's own cadence
            post_scroll(point, kCGScrollEventUnitPixel, 0, True, 4)   # ended
        else:
            clicks = max(1, round(WHEEL["clicks"] * scale))
            for _ in range(clicks):
                post_scroll(point, kCGScrollEventUnitLine, direction, False)
                time.sleep(WHEEL["interval_s"])  # settle: input pacing is the gesture's own cadence
        return began, time.monotonic()

    # ------------------------------------------------------------------ instruments
    import ctypes
    libc = ctypes.CDLL("/usr/lib/libSystem.dylib")
    libc.mach_absolute_time.restype = ctypes.c_uint64

    class Timebase(ctypes.Structure):
        _fields_ = [("numer", ctypes.c_uint32), ("denom", ctypes.c_uint32)]
    tb = Timebase()
    libc.mach_timebase_info(ctypes.byref(tb))
    pair_mach, pair_mono = libc.mach_absolute_time(), time.monotonic()
    epoch_offset = time.time() - time.monotonic()   # monotonic seconds + offset = epoch seconds
    mach_offset = pair_mach * tb.numer / tb.denom / 1e9 - pair_mono

    def mono_from_mach(ticks):
        """Recorder display times (mach ticks) on the time.monotonic() clock, via one paired read."""
        return ticks * tb.numer / tb.denom / 1e9 - mach_offset

    def start_recorder(path, crop):
        recorder = subprocess.Popen([str(recorder_bin), "--pid", str(pid), "--seconds", "120",
                                     "--out", str(path), "--crop", crop],
                                    stdout=subprocess.PIPE, text=True, bufsize=1)
        if not recorder.stdout.readline().startswith('{"ready"'):
            recorder.kill()
            raise RuntimeError("frame recorder did not start")
        return recorder

    def stop_recorder(recorder, path):
        recorder.send_signal(signal.SIGTERM)
        recorder.communicate(timeout=60)  # deadline-fallback: waits for the recorder to write and exit
        lines = [json.loads(l) for l in path.read_text().splitlines() if l.strip()]
        header, frames = lines[0], lines[1:]
        if header.get("stopped_by") != "signal" or header.get("stop_error"):
            raise RuntimeError(f"capture invalid: stopped by {header.get('stopped_by')}, error {header.get('stop_error')}")
        return sorted((mono_from_mach(f["display"]), f["hash"]) for f in frames
                      if f.get("status") == 0 and f.get("hash"))

    def start_xctrace(trace, seconds):
        """Start an Animation Hitches recording that ends by its own time limit (a SIGINT stop hung
        and never saved on this Mac, #4587). Returns once xctrace says the recording is live."""
        log_path = Path(str(trace) + ".log")
        proc = subprocess.Popen(["xcrun", "xctrace", "record", "--template", "Animation Hitches",
                                 "--attach", str(pid), "--time-limit", f"{seconds}s",
                                 "--output", str(trace)], stdout=open(log_path, "w"), stderr=subprocess.STDOUT)
        # Signal: xctrace prints "Ctrl-C to stop the recording" once the instruments are live.
        try:
            wait(lambda: "Ctrl-C to stop" in log_path.read_text() or proc.poll() is not None,
                 120, "xctrace to start recording")
        except RuntimeError:
            proc.kill()
            proc.wait()
            raise
        if proc.poll() is not None:
            raise RuntimeError(f"xctrace exited early: {log_path.read_text()[-400:]}")
        return proc

    def finish_xctrace(proc, trace):
        """Wait for the time limit and the save. Returns (hitches, trace start epoch, trace end epoch,
        None) or (None, None, None, reason): a missing trace is UNPROVEN, never zero hitches."""
        try:
            proc.wait(timeout=XCTRACE_HANG_S)  # deadline-fallback: #4587 hang guard around xctrace's own exit
        except subprocess.TimeoutExpired:
            proc.kill()
            return None, None, None, "xctrace did not finish saving (killed)"
        if proc.returncode != 0 or not Path(trace).exists():
            return None, None, None, f"xctrace exit {proc.returncode}, trace saved {Path(trace).exists()}"
        toc = subprocess.run(["xcrun", "xctrace", "export", "--input", str(trace), "--toc"],
                             capture_output=True, text=True, timeout=300)
        export = subprocess.run(["xcrun", "xctrace", "export", "--input", str(trace), "--xpath",
                                 '/trace-toc/run[@number="1"]/data/table[@schema="hitches"]'],
                                capture_output=True, text=True, timeout=300)
        if toc.returncode != 0 or export.returncode != 0:
            return None, None, None, f"export failed: {(toc.stderr + export.stderr).strip()[-300:]}"
        Path(str(trace) + ".hitches.xml").write_text(export.stdout)
        start = sa.trace_start_epoch(toc.stdout)
        import re
        duration = re.search(r"<duration>([\d.]+)</duration>", toc.stdout)
        end = start + float(duration.group(1)) if start is not None and duration else None
        return sa.parse_hitches(export.stdout), start, end, None

    def layout_gesture(table, kind, point, direction, scale, samples):
        """Post a gesture on a thread while this thread reads visible rows; return the settled y."""
        done = threading.Event()

        def poster():
            try:
                gesture(kind, point, direction, scale)
            finally:
                done.set()
        thread = threading.Thread(target=poster)
        thread.start()
        while not done.is_set():
            samples.append(visible_rows(table))
            done.wait(0.04)  # deadline-fallback: paced AX read that ends on the gesture's done signal
        thread.join()
        return settled(table, lambda: samples.append(visible_rows(table)))

    report = {"pid": pid, "executable": expected_executable, "window": WINDOW_SIZE, "control": control,
              "budget": sa.BUDGET, "trackpad": TRACKPAD, "wheel": WHEEL, "runs": []}

    def save():
        (out / "report.json").write_text(json.dumps(report, indent=1))

    current_area = {"area": None}

    def scrolled(table, frame):
        """How far below its newest row the list sits (points): viewport top minus first-row y."""
        return frame["y"] - settled(table)

    def go_to(table, frame, point, target):
        """Trackpad gestures until the list sits at least `target` points down (bounded). Returns the
        distance reached; less than `target` when the list ends first."""
        reached = scrolled(table, frame)
        for _ in range(120):   # bounded: 120 gestures of about 2000 pt
            if reached >= target:
                break
            gesture("trackpad", point, -1)
            now = scrolled(table, frame)
            if now <= reached + 1:
                break   # the list stopped moving: its end
            reached = now
        return reached

    def at_bottom(table, area):
        """True when the last loaded row ends at the viewport bottom (a down gesture clamped)."""
        rows = ui.get_attr(table, "AXRows") or []
        viewport = ui.element_frame(area)
        last = ui.element_frame(rows[-1]) if rows else None
        return bool(last and viewport and last["y"] + last["height"] <= viewport["y"] + viewport["height"] + 1)

    def run_tabs(tabs, inputs, repeats, start_pt, label):
        for tab in tabs:
            require_identity()
            assert press_tab(tab), f"tab {tab} not found"
            table, area = wait(find_table, 15, f"the {tab} list")
            current_area["area"] = area
            frame = ui.element_frame(area)
            point = CGPoint(frame["x"] + frame["width"] / 2, frame["y"] + frame["height"] / 2)
            CGWarpMouseCursorPosition(point)
            wframe = ui.element_frame(window)
            crop = f"{frame['x'] - wframe['x']},{frame['y'] - wframe['y']},{frame['width'] - 20},{frame['height']}"
            deepest = scrolled(table, frame)
            position = start_pt
            for kind in inputs:
                for rep in range(repeats):
                    require_identity()
                    run = {"case": label, "tab": tab, "input": kind, "repeat": rep}
                    up_scale = 0.5 if control == "short-return" else 1.0
                    if rep < trace_repeats:
                        # Hitch pass, in rows no pass has shown yet (first display costs the most):
                        # no AX reads while gestures run.
                        reached = go_to(table, frame, point, position)
                        run["hitch_pass_at_pt"], run["hitch_pass_fresh"] = reached, reached >= deepest
                        trace = out / f"{label}-{tab}-{kind}-{rep}.trace"
                        frames_path = out / f"{label}-{tab}-{kind}-{rep}.frames.jsonl"
                        xt = recorder = None
                        try:
                            xt = start_xctrace(trace, XCTRACE_WINDOW_S)
                            recorder = start_recorder(frames_path, crop)
                            with load_tools.ResourceSampler(pid) as usage:
                                d0, d1 = gesture(kind, point, -1)
                                time.sleep(QUIET_S)  # settle: hitch pass may not read AX; the list coasts to a stop
                                u0, u1 = gesture(kind, point, +1, up_scale)
                                time.sleep(QUIET_S)  # settle: hitch pass may not read AX; the list coasts to a stop
                            run["resources_hitch_pass"] = usage.result()
                            frames = stop_recorder(recorder, frames_path)   # before xctrace's slow save
                            recorder = None
                            hitches, t_start, t_end, why = finish_xctrace(xt, trace)
                            xt = None
                        finally:
                            for child in (recorder, xt):
                                if child is not None:
                                    child.kill()
                                    child.wait()
                        deepest = max(deepest, reached + 2 * TRACKPAD["steps"] * TRACKPAD["step_px"])
                        before = [h for t, h in frames if t < d0]
                        down_span = sa.moving_span(frames, before[-1] if before else None, d0, u0, d1)
                        mid = [h for t, h in frames if t < u0]
                        up_span = sa.moving_span(frames, mid[-1] if mid else None, u0, u1 + QUIET_S, u1)
                        spans_epoch = [None if sp is None else (sp[0] + epoch_offset, sp[1] + epoch_offset)
                                       for sp in (down_span, up_span)]
                        watched = [u0 + epoch_offset, u1 + QUIET_S + epoch_offset]   # each gesture's watched end
                        # The trace must cover everything the attribution reads: from the first event to
                        # the end of the last watched period (Codex round 4).
                        if hitches is not None and (t_end is None or t_start is None or spans_epoch[0] is None
                                                    or spans_epoch[-1] is None or d0 + epoch_offset < t_start
                                                    or watched[-1] > t_end):
                            why = "the recording does not cover both gestures and their watched periods"
                            hitches = None
                        if hitches is not None:
                            run["hitch"] = sa.hitch_rate([(t_start + st, du, p, sy) for st, du, p, sy in hitches],
                                                         spans_epoch, pid, windows=watched)
                        else:
                            run["hitch"] = {"ms_per_s": None, "unproven": why}
                        run["recording"] = {"start_epoch": t_start, "end_epoch": t_end, "spans_epoch": spans_epoch}
                        run["frames"] = len(frames)
                        run["kept_moving_s"] = {"down": round(sa.kept_moving_after(down_span, d1), 2),
                                                "up": round(sa.kept_moving_after(up_span, u1), 2)}
                        position = reached + FRESH_STEP_PT
                    else:
                        # xctrace saves slowly: later repeats measure travel and row heights only; their
                        # hitch is not measured (the traced repeat reports it; parent session 2026-11-17).
                        run["hitch"] = {"ms_per_s": None, "not_traced": True}
                    # Layout pass, again in fresh rows when the list is long enough: AX reads of the
                    # visible rows during the gestures AND while the list settles.
                    ya_pt = go_to(table, frame, point, position)
                    run["layout_pass_at_pt"], run["layout_pass_fresh"] = ya_pt, ya_pt >= deepest
                    samples = [visible_rows(table)]
                    ya = settled(table)
                    yb = layout_gesture(table, kind, point, -1, 1.0, samples)
                    clamped_bottom = at_bottom(table, area)
                    yc = layout_gesture(table, kind, point, +1, up_scale, samples)
                    deepest = max(deepest, ya_pt + 2 * TRACKPAD["steps"] * TRACKPAD["step_px"])
                    position = ya_pt + FRESH_STEP_PT
                    changed, seen, failed = sa.height_changes(samples)
                    run.update(rows_seen=seen, failed_reads=failed, samples=len(samples), height_changed=changed)
                    run["travel"] = sa.travel(ya, yb, yc, top_y=frame["y"])
                    if clamped_bottom and run["travel"]["asymmetry"] is not None:
                        run["travel"].update(asymmetry=None, problem="the down gesture ended clamped at the bottom")
                    run["verdict"] = sa.verdict(run["hitch"], changed, run["travel"], rows_seen=seen,
                                                failed_reads=failed, hitch_required=rep < trace_repeats)
                    report["runs"].append(run)
                    save()
                    print(json.dumps({"case": label, "tab": tab, "input": kind, "repeat": rep, "verdict": run["verdict"],
                                      "ms_per_s": run["hitch"].get("ms_per_s"), "changed": len(changed),
                                      "asym": run["travel"]["asymmetry"], "problem": run["travel"]["problem"],
                                      "fresh": [run.get("hitch_pass_fresh"), run["layout_pass_fresh"]]}), flush=True)

    report["conditions_start"] = load_tools.machine_conditions()
    report["busy"] = busy
    if "--idle" in argv:
        # Idle on History: no input for IDLE_S; CPU seconds and peak memory of the subject.
        with load_tools.ResourceSampler(pid) as idle:
            time.sleep(IDLE_S)  # settle: the idle phase IS this quiet interval
        report["resources_idle"] = idle.result() | {"seconds": IDLE_S}
    load = load_tools.BusyLoad() if busy else None
    if load:
        load.__enter__()
        report["busy_processes"] = load.count
    try:
        run_tabs(tabs, inputs, repeats, start_pt, "mid")
        if "--deep" in argv:
            # Many loaded pages: Dictations from DEEP_START_PT below the newest row, trackpad only.
            run_tabs(["Dictations"], ["trackpad"], 1, DEEP_START_PT, "deep")
    finally:
        if load:
            load.__exit__(None, None, None)
    report["conditions_end"] = load_tools.machine_conditions()
    verdicts = [r["verdict"] for r in report["runs"]]
    report["budget_verdict"] = ("PASS" if verdicts and all(v == "PASS" for v in verdicts)
                                else "FAIL" if "FAIL" in verdicts else "UNPROVEN")
    save()
    print("budget_verdict", report["budget_verdict"], "wrote", out / "report.json")
    return 0 if report["budget_verdict"] == "PASS" else 1


if __name__ == "__main__":
    sys.exit(main())
