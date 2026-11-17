"""History search, keyboard event to correct visible result, on every tab (#4586 G1).

Replaces the 2026-11-14 driver (one keyboard event per whole query, endpoint = one string appearing
and one disappearing; kept in git history at 6d390f59). Now:

- Cases come from `search_cases.json`: the seven historical queries (posted as one event, as before)
  plus typed (one event per character), replaced and cleared sequences on all three tabs.
- Every accepted query is timed from the keyboard event that produced it. The field's AX value must
  equal the intended query, or the sample is invalid.
- The expected result comes from `m5-speed-ground-truth.py` (the fixture's saved files, never the app).
  `search_check.classify` decides each observation: correct, retained (previous page kept while the
  next is pending), stale (an older query's page), wrong or unreadable. The endpoint is the first
  observation classified `correct`. Stale and wrong observations are counted; unreadable reads never
  become samples.
- Observation: AX reads of the visible part of the History list. An AX read is NOT a frame
  timestamp: the endpoint lies between the end of the previous read and the end of the read that saw
  the correct state. Each sample records both bounds and the read cost, so the uncertainty is
  published instead of subtracted.
- Every wait is on a signal (frontmost app, a correct starting result) with a deadline fallback.

Modes:
  calibrate <pid> <subject .app> <tab> <out.json>   dump the visible list structure (for the card reader)
  run <pid> <subject .app> <home> <cases.json> <new out dir> [samples]

The app must already run on a regenerated fixture home (fixture.py) with full catalog coverage, and
the caller must hold the dev-app lock. Keys go to the frontmost app, so the driver re-checks before
every key that the app under test is frontmost and aborts otherwise.

Usage: python3 m5-speed-ui-search.py calibrate <pid> <subject .app> <tab> <out.json>
       python3 m5-speed-ui-search.py run <pid> <subject .app> <home> <cases.json> <new out dir> [samples] [--capture-compare]
                                     [--only name,name] [--busy]
  --only runs the named series; --busy keeps one busy loop per performance core running (busy Mac).
  The report carries machine conditions, the subject's CPU seconds and peak memory for the run, and
  a budget verdict per series and overall: PASS only when every step was timed and p95 <= 50 ms.
"""
import importlib.util
import json
import os
from math import ceil
from pathlib import Path
import statistics
import sys
import time

HERE = Path(__file__).resolve().parent
RUNTIME_UAT = HERE.parent   # Tests/RuntimeUAT (ported from cwd-relative, #4586)
LIST_ATTRS = ["AXRole", "AXValue", "AXDescription", "AXTitle", "AXChildren", "AXPlaceholderValue",
              "AXPosition", "AXSize"]
SEARCH_PLACEHOLDER = "Search history"
TAB_WORD = {"Dictations": "dictations", "Transcripts": "transcripts", "Meetings": "meetings"}
TIMEOUT_S = 20.0   # control pass 7: pasted Dictations queries took up to 8.6 s to confirm
SETUP_WAIT_S = 30.0   # untimed setup waits (references, query entry)
# Fixed for every baseline and candidate run (chunk 2 review): the calibrated default window showed
# only one or two cards. Fits the M5 Max built-in display's visible area (1512 x 863 points).
WINDOW_ORIGIN = (40, 30)
WINDOW_SIZE = (1200, 820)


def load_truth():
    spec = importlib.util.spec_from_file_location("ground_truth", HERE / "m5-speed-ground-truth.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def wait_for(predicate, timeout, what):
    """Poll a signal until it holds; the deadline is only a fallback."""
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        result = predicate()
        if result:
            return result
        time.sleep(0.02)  # deadline-fallback: poll interval inside a signal wait bounded by `timeout`
    raise RuntimeError(f"timed out waiting for {what}")


def main():
    if len(sys.argv) < 6 or sys.argv[1] in ('-h', '--help') or sys.argv[1] not in ("calibrate", "run"):
        print(__doc__)
        return 2
    sys.path.insert(0, str(RUNTIME_UAT))
    sys.path.insert(0, str(HERE))
    import ui_helpers as ui
    import wispr_eyes as eyes
    import simulate_input as keys
    import search_check as check
    from ApplicationServices import (AXUIElementCopyMultipleAttributeValues, AXUIElementSetAttributeValue,
                                     AXValueCreate, AXValueGetValue, kAXValueCGPointType, kAXValueCGSizeType)
    from Quartz import CGPoint, CGSize
    from AppKit import NSRunningApplication
    from Quartz import (CGEventCreateKeyboardEvent, CGEventKeyboardSetUnicodeString, CGEventPost,
                        CGEventSetFlags, kCGHIDEventTap)

    mode, pid, subject = sys.argv[1], int(sys.argv[2]), Path(sys.argv[3])
    import fixture
    fixture._default_owner_check()   # the shared dev-app lock, before any AX or input action
    # The caller names the prepared subject; the pid must run exactly its executable.
    expected_executable = fixture.require_subject_pid(pid, subject)

    def require_identity():
        if fixture._comm(pid) != expected_executable:
            raise RuntimeError(f"pid {pid} no longer runs {expected_executable}")

    eyes.find_app_pid = ui.find_app_pid = lambda *a, **kw: pid
    eyes.connect()

    def frontmost():
        running = NSRunningApplication.runningApplicationWithProcessIdentifier_(pid)
        return running is not None and running.isActive()

    def require_front():
        require_identity()
        if not frontmost():
            raise RuntimeError(f"pid {pid} is not frontmost; refusing to post keys")

    def values(element):
        err, vals = AXUIElementCopyMultipleAttributeValues(element, LIST_ATTRS, 0, None)
        if err != 0 or vals is None:
            return None
        out = [None if type(v).__name__ == "AXValueRef" and "Error" in str(v) else v for v in vals]
        # Highlighted search matches arrive as attributed strings, not plain strings (debug pass
        # 2026-11-15: every filtered card read as empty). Read their plain text.
        for i in (1, 2, 3):
            if out[i] is not None and not isinstance(out[i], str) and hasattr(out[i], "string"):
                out[i] = str(out[i].string())
        return out

    def frame_of(position, size):
        try:
            ok_p, p = AXValueGetValue(position, 1, None)
            ok_s, s = AXValueGetValue(size, 2, None)
        except Exception:
            return None
        return (p.x, p.y, s.width, s.height) if ok_p and ok_s else None

    def window_and_field():
        for window in ui.get_attr(eyes._app, "AXWindows") or []:
            stack = [(window, 0)]
            while stack:
                element, depth = stack.pop()
                v = values(element)
                if v is None:
                    continue
                if v[5] == SEARCH_PLACEHOLDER:
                    return window, element
                if depth < 30 and v[4] is not None and not isinstance(v[4], str):
                    stack.extend((c, depth + 1) for c in v[4])
        return None, None

    import history_reader as hr
    parents = {}

    def list_area(window):
        """The History list's AXTable (history_reader calibration, 2026-11-17)."""
        table, area = hr.find_list(window)
        if table is not None:
            parents[id(table)] = area
        return table

    def area_of(table):
        if id(table) not in parents:
            parents[id(table)] = ui.get_attr(table, "AXParent")
        return parents[id(table)]

    def visible_items(table, _viewport=None):
        """Visible rows as reader items (history_reader.visible_items), with ("filled",) when the
        list fills its viewport, plus the empty-state text when the app shows one."""
        if table is None:
            return None
        return hr.visible_items(table, area_of(table))

    def flat_children(table):
        """Loaded rows (AXRows), or None when unreadable: used only for 'loaded' and 'empty'."""
        rows = ui.get_attr(table, "AXRows") if table is not None else None
        return None if rows is None else list(rows)

    ui.activate_app(pid)
    wait_for(frontmost, 5, "the app under test to become frontmost")
    assert eyes.nav("History"), "History did not open"
    window, field = wait_for(lambda: (lambda w: w if w[0] is not None else None)(window_and_field()), 10,
                             "the History search box")

    def fix_window():
        """Place and size the subject's window, then prove it took the fixed frame."""
        AXUIElementSetAttributeValue(window, "AXPosition", AXValueCreate(kAXValueCGPointType, CGPoint(*WINDOW_ORIGIN)))
        AXUIElementSetAttributeValue(window, "AXSize", AXValueCreate(kAXValueCGSizeType, CGSize(*WINDOW_SIZE)))

        def placed():
            f = ui.element_frame(window)
            return f is not None and abs(f["width"] - WINDOW_SIZE[0]) <= 2 and abs(f["height"] - WINDOW_SIZE[1]) <= 2
        wait_for(placed, 5, f"the window to take the fixed size {WINDOW_SIZE}")
        return ui.element_frame(window)

    window_frame = fix_window()

    def press_tab(name):
        for role in ("AXRadioButton", "AXButton"):
            control = eyes._find_match(window, name, role, exact=True, mx=24)
            if control is not None:
                return ui.perform_action(control, "AXPress")
        return False

    def viewport_of(table):
        area = area_of(table) if table is not None else None
        frame = ui.element_frame(area) if area is not None else None
        return None if frame is None else (frame["x"], frame["y"], frame["width"], frame["height"])

    if mode == "calibrate":
        tab, out = sys.argv[4], Path(sys.argv[5])
        query = sys.argv[6] if len(sys.argv) > 6 else None
        assert press_tab(tab), f"tab {tab} not found"
        if query is not None:
            # Calibrate a FILTERED list too: matches are highlighted, which may change what the
            # accessibility layer exposes for card text. Each tab has its own search box.
            _, field = wait_for(lambda: (lambda w: w if w[1] is not None else None)(window_and_field()), 10,
                                "the current search box")
            ui.set_attr(field, "AXFocused", True)
            require_front()
            keys.press_key("a", cmd=True)
            require_front()
            keys.press_key("delete")
            require_front()
            for is_down in (True, False):
                event = CGEventCreateKeyboardEvent(None, 0, is_down)
                CGEventKeyboardSetUnicodeString(event, len(query), query)
                CGEventSetFlags(event, 0)
                CGEventPost(kCGHIDEventTap, event)
            wait_for(lambda: (ui.get_attr(field, "AXValue") or "") == query, 5, "the query in the field")
            time.sleep(3.0)  # settle: calibration only, let the filtered list replace the unfiltered one
        area = wait_for(lambda: list_area(window), 30, f"the {tab} list")
        time.sleep(1.0)  # settle: calibration only, let the list finish drawing before the dump
        rows = flat_children(area) or []
        out.write_text(json.dumps({"window": window_frame, "viewport": viewport_of(area),
                                   "loaded_rows": len(rows),
                                   "window_texts": (ui.get_all_visible_text(window, max_depth=16) or [])[:160],
                                   "items": visible_items(area)}, indent=1))
        print("wrote", out)
        return 0

    home, cases_path, out = Path(sys.argv[4]), Path(sys.argv[5]), Path(sys.argv[6])
    samples = int(sys.argv[7]) if len(sys.argv) > 7 else 100
    # Alternate attempts with the frame recorder on and off, to compare accessibility confirmation
    # times with and without capture (capture-overhead control, chunk 2 review).
    capture_compare = "--capture-compare" in sys.argv[8:]
    import ctypes
    import signal as signals
    import subprocess
    import search_frames
    truth = load_truth()
    rows = truth.load_rows(home)
    cases = json.loads(cases_path.read_text())
    libc = ctypes.CDLL("/usr/lib/libSystem.dylib")
    libc.mach_absolute_time.restype = ctypes.c_uint64

    class MachTimebase(ctypes.Structure):
        _fields_ = [("numer", ctypes.c_uint32), ("denom", ctypes.c_uint32)]
    timebase = MachTimebase()
    libc.mach_timebase_info(ctypes.byref(timebase))
    TIMEBASE = (timebase.numer, timebase.denom)
    recorder_bin = HERE.parent.parent.parent / "build" / "history_speed" / "frame_recorder"
    if not recorder_bin.is_file():
        raise RuntimeError(f"build the frame recorder first: {recorder_bin}")
    out.mkdir(parents=True, exist_ok=False)

    def answer(tab, query):
        return check.expected_tokens(truth.expected(rows, TAB_WORD[tab], query, truth.now_reference()))

    def post_text(text):
        """Post text as one keyboard event pair. Returns the post time, taken AFTER the frontmost and
        identity checks and immediately before the first event (Codex verdict 2026-11-17)."""
        require_front()
        posted = libc.mach_absolute_time()
        for is_down in (True, False):
            event = CGEventCreateKeyboardEvent(None, 0, is_down)
            CGEventKeyboardSetUnicodeString(event, len(text), text)
            CGEventSetFlags(event, 0)
            CGEventPost(kCGHIDEventTap, event)
        return posted

    def select_all():
        require_front()
        keys.press_key("a", cmd=True)

    def burst_text(text):
        """Post text with no frontmost re-check (the caller checked just before a burst)."""
        for is_down in (True, False):
            event = CGEventCreateKeyboardEvent(None, 0, is_down)
            CGEventKeyboardSetUnicodeString(event, len(text), text)
            CGEventSetFlags(event, 0)
            CGEventPost(kCGHIDEventTap, event)

    def burst_select_all():
        """Command-A as raw events, so an overlap posts its second query within milliseconds."""
        from Quartz import kCGEventFlagMaskCommand
        for is_down in (True, False):
            event = CGEventCreateKeyboardEvent(None, 0, is_down)   # virtual key 0 is "a"
            CGEventSetFlags(event, kCGEventFlagMaskCommand)
            CGEventPost(kCGHIDEventTap, event)

    def delete():
        require_front()
        posted = libc.mach_absolute_time()
        keys.press_key("delete")
        return posted

    held_field = {"el": field}

    def field_value():
        return ui.get_attr(held_field["el"], "AXValue") or ""

    def focus_search_box():
        """Each tab draws its own search box (debug pass 2026-11-15: keys typed after a tab switch
        went to a stale box and opened other UI). Find the current one and prove it has focus."""
        _, box = wait_for(lambda: (lambda w: w if w[1] is not None else None)(window_and_field()), 10,
                          "the current search box")
        held_field["el"] = box
        ui.set_attr(box, "AXFocused", True)
        wait_for(lambda: ui.get_attr(box, "AXFocused") is True, 5, "the search box to take focus")

    current_area = {"element": None, "refound_at": 0.0}
    POLL_S = 0.04          # accessibility read pace: a tight loop starved the app (debug pass 2026-11-15)
    REFIND_EVERY_S = 0.25  # re-find a replaced list element at most this often
    # After a confirmation, keep checking the page for this long; the picture held at its end is a
    # verified picture when every read stayed correct (search_frames.STEP_HOLD_MS plus margin).
    OBSERVE_S = search_frames.STEP_HOLD_MS / 1000 + 0.05

    def observe(area):
        """One paced read. A query replaces the list's accessibility element, so an empty read
        re-finds the list (rate-limited); the empty-state text lives outside the list, so it is
        looked for only after several empty reads (rate-limited)."""
        time.sleep(POLL_S)  # deadline-fallback: paced polling inside the caller's deadline-bounded wait
        held = current_area["element"] or area
        items = visible_items(held, viewport_of(held))
        now = time.monotonic()
        if not items and now - current_area["refound_at"] >= REFIND_EVERY_S:
            current_area["refound_at"] = now
            fresh = list_area(window)
            if fresh is not None:
                current_area["element"] = held = fresh
                items = visible_items(held, viewport_of(held))
        if items == [] and list_loaded(held) and not flat_children(held):
            # No results: this build shows no message, only an empty, loaded list (calibration
            # 2026-11-15 with "zqxjvkwplm": no list children, no busy indicator, no empty-state text).
            items = [("text", check.EMPTY_STATE)]
        return check.tokens_from_items(items)

    SCROLL_BAR = 20   # points at the list's right edge: the overlay scroll bar fades in and out

    def list_crop(table):
        a, w = ui.element_frame(area_of(table)), ui.element_frame(window)
        return f"{a['x'] - w['x']},{a['y'] - w['y']},{a['width'] - SCROLL_BAR},{a['height']}"

    def park_pointer():
        """Hover highlights a card under the pointer and changes the picture: park it outside."""
        from Quartz import CGWarpMouseCursorPosition
        CGWarpMouseCursorPosition(CGPoint(WINDOW_ORIGIN[0] + WINDOW_SIZE[0] + 60, WINDOW_ORIGIN[1] + WINDOW_SIZE[1] - 10))

    def list_loaded(table):
        return flat_children(table) is not None and visible_items(table) is not None

    def observe_after(area, current, history, seconds):
        """Keep reading for `seconds` after a confirmation and count every verdict: a page that turns
        wrong, retained or stale after it was confirmed is a regression, never a pass. The first read
        of each other verdict is kept as evidence under "_samples"."""
        post, until = {}, time.monotonic() + seconds
        while time.monotonic() < until:   # deadline-bounded observation; each read is paced by observe()
            observed = observe(area)
            verdict = check.classify(observed, current, history)
            post[verdict] = post.get(verdict, 0) + 1
            if verdict != "correct" and verdict not in post.setdefault("_samples", {}):
                post["_samples"][verdict] = {"observed": repr(observed)[:900], "expected_head": repr(current[:4])[:500],
                                             "field": field_value()}
        return post

    def all_correct(*verdict_sets):
        return all({k for k in v if k != "_samples"} == {"correct"} for v in verdict_sets)

    def confirm(area, current, history):
        """Read until the accessibility checker sees `current` twice in a row, then keep checking for
        OBSERVE_S. Returns (host time at which the SECOND consecutive correct read finished, or None;
        verdicts before; verdicts after). That time includes the reads' own cost and pacing, so it is
        an upper bound on accessibility confirmation, used only for the capture on/off comparison;
        the frame endpoint never uses it. Counts every verdict for the record."""
        verdicts, first, deadline = {}, None, time.monotonic() + TIMEOUT_S
        samples = verdicts.setdefault("_samples", {})
        while time.monotonic() < deadline:
            observed = observe(area)
            read_end = libc.mach_absolute_time()
            verdict = check.classify(observed, current, history)
            verdicts[verdict] = verdicts.get(verdict, 0) + 1
            if verdict not in ("correct",) and verdict not in samples:
                # Evidence for the record: what the reader saw the first time each verdict occurred.
                held = current_area["element"] or area
                raw = visible_items(held, viewport_of(held))
                samples[verdict] = {"observed": repr(observed)[:600], "items": repr(raw)[:900],
                                    "expected_head": repr(current[:3])[:400], "field": field_value()}
            if verdict == "correct":
                if first is not None:
                    return read_end, verdicts, observe_after(area, current, history, OBSERVE_S)
                first = read_end
            else:
                first = None
        return None, verdicts, {}

    def start_recorder(frames_path, crop, seconds):
        recorder = subprocess.Popen([str(recorder_bin), "--pid", str(pid), "--seconds", str(int(seconds)),
                                     "--out", str(frames_path), "--crop", crop],
                                    stdout=subprocess.PIPE, text=True, bufsize=1)
        if not recorder.stdout.readline().startswith('{"ready"'):
            recorder.kill()
            return None
        return recorder

    def stop_recorder(recorder, frames_path):
        """Returns (header, frames, recorder CPU text, reason-if-invalid)."""
        # Capture overhead: the recorder's own CPU time (ps reports [[dd-]hh:]mm:ss.ss).
        cpu_text = subprocess.run(["/bin/ps", "-o", "time=", "-p", str(recorder.pid)], capture_output=True,
                                  text=True).stdout.strip()
        recorder.send_signal(signals.SIGTERM)
        recorder.communicate(timeout=60)  # deadline-fallback: waits for the recorder to write and exit
        lines = [json.loads(l) for l in frames_path.read_text().splitlines() if l.strip()]
        header, frames = lines[0], lines[1:]
        if header.get("stopped_by") != "signal":
            return header, frames, cpu_text, f"recorder stopped by {header.get('stopped_by')}, not by the driver"
        return header, frames, cpu_text, None

    def set_query(query):
        """Untimed: empty the current search box, prove it is empty, then post the query."""
        focus_search_box()
        select_all()
        delete()
        try:
            # Untimed setup: a long unfiltered Dictations filter kept the app busy for over 7 s in
            # control pass 7, so these waits are generous.
            wait_for(lambda: field_value() == "", SETUP_WAIT_S, "an empty search box")
            if query:
                post_text(query)
                wait_for(lambda: field_value() == query, SETUP_WAIT_S, f"the query {query!r} in the field")
        except RuntimeError as error:
            raise RuntimeError(f"{error}; field holds {field_value()!r}; box focused "
                               f"{ui.get_attr(held_field['el'], 'AXFocused')}") from error

    def plan_queries(steps):
        """Every query an attempt of this plan can show, the starting (empty) query first."""
        queries, query = [""], ""
        for step in steps:
            if step[0] == "type":
                for ch in step[1]:
                    query += ch
                    queries.append(query)
            elif step[0] == "paste":
                query = step[1]
                queries.append(query)
            elif step[0] == "overlap":
                queries += [step[1], step[2]]
                query = step[2]
            elif step[0] == "clear":
                query = ""
        return list(dict.fromkeys(queries))

    answer_now = {}
    REFERENCE_HOLD_S = search_frames.REFERENCE_HOLD_MS / 1000 + 0.15   # margin over the analyzer's hold
    STILL_MS = 1000         # readiness: the unfiltered list's picture must not change for this long
    STILL_WINDOW_S = 1.5    # each readiness recording
    STILL_DEADLINE_S = 600  # control pass 8: a moving loading picture lasted about 3 minutes after launch

    def wait_still(name, crop):
        """Untimed readiness. Control pass 8 (2026-11-15) found the list drawing a moving, nearly
        blank loading picture for minutes after launch while accessibility already listed the rows.
        Record short windows until one ends with STILL_MS of an unchanged picture. Returns the
        readiness record (time waited, windows used); raises if the deadline passes."""
        began, windows, last_failed = time.monotonic(), 0, None
        while time.monotonic() - began < STILL_DEADLINE_S:
            path = out / f"{name}-still-{windows}.jsonl"
            recorder = start_recorder(path, crop, STILL_WINDOW_S + 30)
            if recorder is None:
                raise RuntimeError("recorder did not start for the readiness check")
            observe_after(current_area["element"], answer_now["unfiltered"], [], STILL_WINDOW_S)  # paced reads, also the wait
            end = libc.mach_absolute_time()
            header, frames, _, invalid = stop_recorder(recorder, path)
            windows += 1
            if invalid:
                raise RuntimeError(f"readiness recording invalid: {invalid}")
            picture, _ = search_frames.reference_from_frames(frames, end, header["timebase_numer"],
                                                             header["timebase_denom"], STILL_MS)
            if picture is not None:
                return {"waited_ms": round((time.monotonic() - began) * 1000), "windows": windows,
                        "kept": [str(x) for x in (last_failed, path) if x is not None]}
            if last_failed is not None:
                last_failed.unlink()   # keep the latest unsuccessful window beside the successful one
            last_failed = path
        raise RuntimeError(f"the list never held still for {STILL_MS} ms within {STILL_DEADLINE_S} s")

    def take_references(name, tab, area, queries, crop, label):
        """Untimed: for each query, show it, confirm it by accessibility, keep confirming it for the
        hold, and take the picture held at the end (search_frames.reference_from_frames)."""
        frames_path = out / f"{name}-refs-{label}.jsonl"
        seconds = 60 + len(queries) * (TIMEOUT_S + OBSERVE_S + REFERENCE_HOLD_S + 5)
        recorder = start_recorder(frames_path, crop, seconds)
        if recorder is None:
            return {}, {"*": "recorder did not start"}
        marks, reasons = {}, {}
        for query in queries:
            set_query(query)
            current = answer(tab, query)
            confirmed, _, post = confirm(area, current, [])
            hold = observe_after(area, current, [], REFERENCE_HOLD_S)
            if confirmed is None:
                reasons[query] = "accessibility never confirmed the correct result"
            elif not all_correct(post, hold) or field_value() != query:
                reasons[query] = f"not held correct: after {post}, hold {hold}, field {field_value()!r}"
            else:
                marks[query] = libc.mach_absolute_time()
        header, frames, _, invalid = stop_recorder(recorder, frames_path)
        if invalid:
            return {}, {"*": invalid}
        refs = {}
        for query, held_until in marks.items():
            ref, why = search_frames.reference_from_frames(frames, held_until, header["timebase_numer"],
                                                           header["timebase_denom"])
            if ref is None:
                reasons[query] = why
            else:
                refs[query] = ref
        return refs, reasons

    def run_sequence(name, tab, area, steps, attempt, crop, capture):
        """One attempt. Collects records only; measurement happens after the closing references."""
        require_identity()
        current_area["element"] = area
        park_pointer()
        focus_search_box()
        set_query("")
        history = [answer(tab, "")]
        start_ok, _, _ = confirm(area, history[0], [])
        if start_ok is None or field_value() != "":
            return {"name": name, "attempt": attempt, "valid": False, "reason": "unfiltered start not confirmed"}
        frames_path, recorder = out / f"{name}-{attempt}.jsonl", None
        if capture:
            accepted = sum(len(st[1]) if st[0] == "type" else 1 for st in steps)
            recorder = start_recorder(frames_path, crop, 60 + accepted * (TIMEOUT_S + OBSERVE_S + 3))
            if recorder is None:
                return {"name": name, "attempt": attempt, "valid": False, "reason": "recorder did not start"}
        # The starting picture, held while every read confirms the unfiltered list (the baseline).
        start_hold = observe_after(area, history[0], [], OBSERVE_S)
        start_held_until = libc.mach_absolute_time() if all_correct(start_hold) else None
        baseline_at = libc.mach_absolute_time()
        records, query = [], ""

        def accept(query, kind, posted):
            current = answer(tab, query)
            confirmed, verdicts, post = confirm(area, current, history)
            held_until = libc.mach_absolute_time() if confirmed is not None and all_correct(post) else None
            records.append({"query": query, "kind": kind, "posted": posted, "confirmed": confirmed,
                            "field": field_value(), "verdicts": verdicts, "post_verdicts": post,
                            "held_until": held_until})
            history.append(current)

        for step in steps:
            kind = step[0]
            if kind == "type":
                for ch in step[1]:
                    query += ch
                    posted = post_text(ch)
                    accept(query, "typed", posted)
            elif kind == "paste":
                query = step[1]
                posted = post_text(query)
                accept(query, "pasted", posted)
            elif kind == "overlap":
                # Genuine supersession: the second query is posted while the first is still pending.
                first_query, second_query = step[1], step[2]
                require_front()
                posted_first = libc.mach_absolute_time()
                burst_text(first_query)
                burst_select_all()
                posted = libc.mach_absolute_time()
                burst_text(second_query)
                records.append({"query": first_query, "kind": "superseded", "posted": posted_first,
                                "second_posted": posted, "confirmed": None, "field": None, "verdicts": {}})
                # For the accessibility checker the superseded answer is OLDER than the previous page.
                history.insert(len(history) - 1, answer(tab, first_query))
                query = second_query
                accept(query, "replaced", posted)
            elif kind == "clear":
                select_all()
                query = ""
                posted = delete()
                accept("", "cleared", posted)
        ended = libc.mach_absolute_time()
        result = {"name": name, "attempt": attempt, "valid": True, "capture": capture, "records": records,
                  "ended": ended, "start_held_until": start_held_until,
                  "ax_steps": [[r["query"], r["kind"], (r["confirmed"] - r["posted"]) * TIMEBASE[0] / TIMEBASE[1] / 1e6
                                if r["confirmed"] else None] for r in records if r["kind"] != "superseded"]}
        if capture:
            header, _, cpu_text, invalid = stop_recorder(recorder, frames_path)
            if invalid:
                return {"name": name, "attempt": attempt, "valid": False, "reason": invalid}
            result.update(frames=str(frames_path), recorder_cpu=cpu_text, timebase=[header["timebase_numer"],
                          header["timebase_denom"]], sequence_ms=(ended - baseline_at) * header["timebase_numer"]
                          / header["timebase_denom"] / 1e6)
        return result

    def measure(attempt, refs):
        lines = [json.loads(l) for l in Path(attempt["frames"]).read_text().splitlines() if l.strip()]
        numer, denom = attempt["timebase"]
        return search_frames.measure_attempt(attempt.pop("records"), lines[1:], refs, "", attempt["ended"],
                                             numer, denom, start_held_until=attempt["start_held_until"])

    def percentiles(values):
        values = sorted(values)
        return {"n": len(values), "p5": values[max(ceil(len(values) * .05) - 1, 0)],
                "p50": statistics.median(values), "p95": values[ceil(len(values) * .95) - 1]} if values else {"n": 0}

    # Capture comparison runs predeclared on/off PAIRS per case (a case may set "pairs"; default
    # `samples`); counted runs use `samples` capture-on attempts.
    plans = [(c["name"], c["tab"], [["paste", c["query"]], ["clear"]], c.get("pairs")) for c in cases["historical"]]
    plans += [(f'{c["name"]}-typed', c["tab"], [["type", c["query"]], ["clear"]], c.get("pairs"))
              for c in cases["historical"]]
    plans += [(s["name"], s["tab"], s["steps"], s.get("pairs")) for s in cases["sequences"]]
    import load_tools
    truth.pin_locale(home)
    report = {"conditions_start": load_tools.machine_conditions(), "pid": pid, "executable": expected_executable, "home": str(home), "cases": str(cases_path),
              "window": window_frame, "capture_compare": capture_compare, "series": {}}

    def run_plan(name, tab, steps, pairs):
        # Untimed readiness and references: tab, loaded list, fixed crop, the correct picture of
        # every query this plan can show. Counting starts only after this phase.
        require_identity()
        assert press_tab(tab), f"tab {tab} not found"
        area = wait_for(lambda: list_area(window), 10, f"the {tab} list")
        current_area["element"] = area
        park_pointer()
        focus_search_box()
        wait_for(lambda: list_loaded(area), 30, f"the {tab} list to finish loading")
        crop = list_crop(area)
        queries = plan_queries(steps)
        set_query("")
        answer_now["unfiltered"] = answer(tab, "")
        readiness = wait_still(name, crop)
        print(name, "ready", json.dumps(readiness), flush=True)
        refs_before, reasons_before = take_references(name, tab, area, queries, crop, "before")
        if "*" in reasons_before:   # the reference recording itself failed
            report["series"][name] = {"summary": {"tab": tab, "invalid_plan": True},
                                      "references": {"before": refs_before, "reasons_before": reasons_before}}
            print(name, "invalid plan:", reasons_before["*"], flush=True)
            return
        count = 2 * (pairs or samples) if capture_compare else samples
        attempts = [run_sequence(name, tab, area, steps, i, crop, capture=not (capture_compare and i % 2))
                    for i in range(count)]
        refs_after, reasons_after = take_references(name, tab, area, queries, crop, "after")
        # Every verified picture of each query, from both reference phases (a query may draw
        # slightly different pixels on different visits; each one was confirmed by accessibility).
        verified = {q: {h for h in (refs_before.get(q), refs_after.get(q)) if h} for q in queries}
        for a in attempts:
            if a.get("valid") and a["capture"]:
                a["steps"] = measure(a, verified)
            elif a.get("valid"):
                a.pop("records")
        steps_all = [st for a in attempts if a.get("valid") and a["capture"] for st in a["steps"]
                     if st["kind"] != "superseded"]
        timed = [st for st in steps_all if st["result"] == "timed"]
        counts = {}
        for st in steps_all:
            counts[st["result"]] = counts.get(st["result"], 0) + 1
        summary = {"tab": tab, "attempts": len(attempts),
                   "invalid_attempts": sum(1 for a in attempts if not a.get("valid")),
                   "results": counts, "timed": len(timed),
                   "queries_with_two_reference_pictures": sorted(q for q, v in verified.items() if len(v) > 1),
                   "queries_without_reference": sorted(q for q, v in verified.items() if not v),
                   "supersession": [st.get("supersession") for a in attempts if a.get("valid") and a["capture"]
                                    for st in a["steps"] if st["kind"] == "superseded"],
                   "upper_ms": percentiles([st["upper_ms"] for st in timed]),
                   "ax_ms_capture_on": percentiles([v for a in attempts if a.get("valid") and a["capture"]
                                                    for _, _, v in a["ax_steps"] if v is not None])}
        if capture_compare:
            summary["ax_ms_capture_off"] = percentiles([v for a in attempts if a.get("valid") and not a["capture"]
                                                        for _, _, v in a["ax_steps"] if v is not None])
            # Paired: attempt 2k (on) with 2k+1 (off), same sequence, matched step by step on
            # (query, kind). Difference = on minus off.
            diffs = []
            for k in range(0, len(attempts) - 1, 2):
                on, off = attempts[k], attempts[k + 1]
                if not (on.get("valid") and off.get("valid")):
                    continue
                for (q1, k1, v1), (q2, k2, v2) in zip(on["ax_steps"], off["ax_steps"]):
                    if (q1, k1) == (q2, k2) and v1 is not None and v2 is not None:
                        diffs.append(v1 - v2)
            summary["ax_ms_paired_on_minus_off"] = percentiles(diffs)
            if diffs:
                summary["ax_ms_paired_on_minus_off"]["mean"] = statistics.fmean(diffs)
        if timed:
            summary["median_gap_ms"] = statistics.median(st["gap_ms"] for st in timed if st["gap_ms"] is not None)
        summary["readiness"] = readiness
        summary["budget_verdict"] = budget_verdict(summary, [st["upper_ms"] for st in timed])
        report["series"][name] = {"summary": summary, "attempts": attempts,
                                  "references": {"before": refs_before, "after": refs_after,
                                                 "reasons_before": reasons_before, "reasons_after": reasons_after}}
        print(name, json.dumps(summary), flush=True)

    BUDGET_MS = 50

    def budget_verdict(summary, upper):
        """PASS only when every counted step was timed and p95 <= budget; FAIL when p95 of the timed
        steps is over budget or any step failed (wrong or stale page); otherwise UNPROVEN. Steps
        that could not be timed (unknown, no visible change) never let a series PASS."""
        counts = summary.get("results", {})
        p95 = percentiles(upper).get("p95") if upper else None
        if summary.get("invalid_attempts") or counts.get("failed"):
            return "FAIL" if counts.get("failed") else "UNPROVEN"
        if p95 is not None and p95 > BUDGET_MS:
            return "FAIL"
        if upper and set(counts) == {"timed"}:
            return "PASS"
        return "UNPROVEN"

    def save_report():
        (out / "report.json").write_text(json.dumps(report, indent=1))

    only = sys.argv[sys.argv.index("--only") + 1].split(",") if "--only" in sys.argv else None
    busy = load_tools.BusyLoad() if "--busy" in sys.argv else None
    report["busy"] = busy.count if busy else 0
    if busy:
        busy.__enter__()
    try:
        with load_tools.ResourceSampler(pid) as usage:
            for name, tab, steps, pairs in plans:
                if only and name not in only:
                    continue
                try:
                    run_plan(name, tab, steps, pairs)
                except RuntimeError as error:   # one plan's setup failure is recorded, never fatal to the run
                    report["series"][name] = {"summary": {"tab": tab, "invalid_plan": True, "error": str(error)[:600]}}
                    print(name, "invalid plan:", str(error)[:300], flush=True)
                save_report()
        report["resources_search_run"] = usage.result()
    finally:
        if busy:
            busy.__exit__(None, None, None)
    verdicts = [v["summary"].get("budget_verdict", "UNPROVEN") for v in report["series"].values()]
    all_upper = [st["upper_ms"] for v in report["series"].values() for a in v.get("attempts", [])
                 if a.get("valid") and a.get("capture") for st in a.get("steps", []) if st.get("result") == "timed"]
    report["overall"] = {"timed_p95_ms": percentiles(all_upper).get("p95"), "timed_n": len(all_upper),
                         "budget_verdict": "PASS" if verdicts and all(v == "PASS" for v in verdicts)
                         else "FAIL" if "FAIL" in verdicts else "UNPROVEN"}
    report["conditions_end"] = load_tools.machine_conditions()
    save_report()
    print("overall", json.dumps(report["overall"]))
    print("wrote", out / "report.json")
    return 0 if report["overall"]["budget_verdict"] == "PASS" else 1


if __name__ == "__main__":
    sys.exit(main())
