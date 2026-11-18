"""Open History: app start to the first complete, correct page (#4586 WP-A).

Two modes. `missing`: before every launch, delete only the fixture's derived `HistoryCatalog`
folder (a missing-catalog launch, NOT a reboot-cold launch: the file cache stays warm). `existing`:
keep the fully covered catalog from the previous launch.

Per sample:
1. Arm display capture (`frame_recorder --display-rect`) over the list's screen rectangle learned on
   the warm-up launches, and wait for its ready line, BEFORE the subject starts.
2. Spawn the subject (`fixture.launch`); the start time is taken immediately before the spawn,
   after every check (`fixture.LAST_SPAWN_AT`).
3. Poll the subject's windows by AX every 20 ms (window time, a breakdown only).
4. Read the list (`history_reader`) until the independent answer (newest Dictations rows from the
   fixture's files, `m5-speed-ground-truth.py`) is confirmed complete and correct twice in a row,
   then keep confirming it for HOLD_MS.
5. Stop capture. The verified picture is the one held at the end of that hold
   (`search_frames.reference_from_frames`); the endpoint is the FIRST captured frame after the spawn
   that shows it. `launch_to_page_ms` = endpoint - spawn (headline). If the first frame captured
   after the spawn already shows it, the endpoint is an upper bound (`capture_late`).
6. Stop the subject (TERM, re-verified pid).

The window opens where AppKit restored it; every measured sample checks that the list rectangle
equals the warm-up one, or the sample is invalid. Every attempted sample is kept: a sample with no
complete page within PAGE_DEADLINE_S is `missed` and makes the verdict FAIL.

Isolation: the dev-app lock, the renamed subject and a fresh fixture home (fixture.py). The
throwaway preferences domain must not exist at start (refused otherwise), lives for the whole run
(so the saved window frame and last tab persist between samples) and is removed at the end; the
production preferences domain is compared before and after and never restored over.

Control: `--control drop-row` removes one expected row from the answer: no sample may confirm.

The fixture's recordings (~2.15 GB) are over the default 2 GB storage warning threshold, so every launch
passes the app's own setting `recordingStorageWarningThreshold=none` in its launch arguments (no
preference is written): otherwise the warning banner appears 2.4-3.9 s after launch and pushes the
page down about 65 pt. `--storage-warning` launches WITHOUT that argument and reports the banner
(`banner_jump`: when it appeared and how far the list moved): a labelled check of a real
user-visible jump, not a timing run. `--watch-banner` runs the same watch with the warning off.

Usage: python3 m5-speed-open.py <subject .app> <fixture home> <new out dir> --mode missing|existing
                                [--samples 20] [--warmups 2] [--busy] [--control drop-row] [--storage-warning] [--watch-banner]
The caller holds the dev-app lock; no other instance of the subject may run.
"""
import importlib.util
import json
from math import ceil
from pathlib import Path
import signal
import statistics
import subprocess
import sys
import time

HERE = Path(__file__).resolve().parent
RUNTIME_UAT = HERE.parent
PAGE_DEADLINE_S = 60.0
WINDOW_DEADLINE_S = 30.0
HOLD_MS = 300
BANNER_WATCH_S = 8.0               # the banner appeared 2.4-3.9 s after launch on the M1 (#4586)
BANNER_PREFIX = "Recordings use about"
COVERAGE_DEADLINE_S = 900   # 2026-11-15 measured 264.7 s to full coverage on the M5 (old build); M1 rebuild ~180 s
BUDGET_MS = 300
SCROLL_BAR = 20


def option(argv, name, default=None):
    return argv[argv.index(name) + 1] if name in argv else default


def percentiles(values):
    values = sorted(values)
    if not values:
        return {"n": 0}
    return {"n": len(values), "p50": statistics.median(values), "p95": values[ceil(len(values) * .95) - 1],
            "max": values[-1]}


def main():
    argv = sys.argv[1:]
    if len(argv) < 5 or argv[0] in ("-h", "--help") or option(argv, "--mode") not in ("missing", "existing"):
        print(__doc__)
        return 2
    sys.path.insert(0, str(RUNTIME_UAT))
    sys.path.insert(0, str(HERE))
    import ctypes
    import ui_helpers as ui
    import fixture
    import history_reader as hr
    import load_tools
    import search_check as check
    import search_frames

    subject, home, out = Path(argv[0]), Path(argv[1]), Path(argv[2])
    mode = option(argv, "--mode")
    samples = int(option(argv, "--samples", "20"))
    warmups = max(1, int(option(argv, "--warmups", "2")))
    control = option(argv, "--control")
    storage_warning = "--storage-warning" in argv
    watch = "--watch-banner" in argv   # watch for the banner with the warning OFF (proof it stays off)
    if control not in (None, "drop-row"):
        print(f"unknown control {control}", file=sys.stderr)
        return 2
    spec = importlib.util.spec_from_file_location("ground_truth", HERE / "m5-speed-ground-truth.py")
    truth = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(truth)
    recorder_bin = RUNTIME_UAT.parent.parent / "build" / "history_speed" / "frame_recorder"
    if not recorder_bin.is_file():
        raise SystemExit(f"build the frame recorder first: {recorder_bin}")
    if fixture.subject_identity(subject) != fixture.SUBJECT_BUNDLE_ID:
        raise SystemExit(f"{subject} is not the renamed measurement subject")
    out.mkdir(parents=True, exist_ok=False)
    libc = ctypes.CDLL("/usr/lib/libSystem.dylib")
    libc.mach_absolute_time.restype = ctypes.c_uint64

    class Timebase(ctypes.Structure):
        _fields_ = [("numer", ctypes.c_uint32), ("denom", ctypes.c_uint32)]
    tb = Timebase()
    libc.mach_timebase_info(ctypes.byref(tb))
    ms = lambda ticks: ticks * tb.numer / tb.denom / 1e6
    executable = str(Path(subject).resolve() / fixture.EXECUTABLE)
    real_home = Path(fixture.pwd_home())

    truth.pin_locale(home)
    rows = truth.load_rows(home)
    answer_rows = truth.expected(rows, "dictations", "", truth.now_reference())
    if control == "drop-row":
        answer_rows = answer_rows[:1] + answer_rows[2:]
    answer = check.expected_tokens(answer_rows)

    def coverage_complete():
        import sqlite3
        db = fixture.catalog_dir(home) / "history.sqlite"
        if not db.is_file():
            return False
        try:
            with sqlite3.connect(f"file:{db}?mode=ro", uri=True, timeout=1) as con:
                row = con.execute("select revision from coverage where revision is not null and revision != ''").fetchone()
            return row is not None
        except sqlite3.Error:
            return False

    def start_recorder(path, rect):
        recorder = subprocess.Popen([str(recorder_bin), "--display-rect", rect, "--seconds", str(int(PAGE_DEADLINE_S + 60)),
                                     "--out", str(path)], stdout=subprocess.PIPE, text=True, bufsize=1)
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
        return header, frames

    def watch_banner(window, area, spawned, start_y):
        """Labelled jump check (`--storage-warning`, or `--watch-banner` with the warning off): until
        BANNER_WATCH_S after the spawn, watch for the recordings storage-warning banner and how far the
        list moved from where it was when the page was first confirmed (`start_y`). Accessibility reads,
        outside the list only (history_reader.find_outside_list)."""
        seen_at, moved_to = None, start_y
        while ms(libc.mach_absolute_time() - spawned) < BANNER_WATCH_S * 1000:
            if seen_at is None and hr.find_outside_list(window, lambda e, r: r == "AXStaticText" and str(
                    ui.get_attr(e, "AXValue") or "").startswith(BANNER_PREFIX)):
                seen_at = round(ms(libc.mach_absolute_time() - spawned))
            moved_to = (ui.element_frame(area) or {}).get("y", moved_to)
            time.sleep(0.1)  # deadline-fallback: paced read inside the banner watch window
        return {"seen_at_ms": seen_at, "list_y_at_page": start_y, "list_y_after": moved_to,
                "jump_pt": None if start_y is None or moved_to is None else round(moved_to - start_y, 1)}

    def one_launch(index, rect, measured):
        """One launch; returns a sample record. `rect` is the capture rectangle or None (warm-up)."""
        sample = {"index": index, "measured": measured, "conditions": load_tools.machine_conditions()}
        if mode == "missing":
            sample["catalog_deleted"] = fixture.reset_catalog(home)
        frames_path = out / f"open-{index}.jsonl"
        recorder = start_recorder(frames_path, rect) if rect else None
        pid = None
        try:
            pid = fixture.launch(subject, home, out / "app.log", storage_warning=storage_warning)
            spawned = fixture.LAST_SPAWN_AT
            sample["pid"] = pid
            window, window_at = None, None
            deadline = time.monotonic() + WINDOW_DEADLINE_S
            while time.monotonic() < deadline and window is None:
                windows = ui.get_attr(ui.get_ax_app(pid), "AXWindows") or []
                if windows:
                    window, window_at = windows[0], libc.mach_absolute_time()
                else:
                    time.sleep(0.02)  # deadline-fallback: paced poll for the window signal
            if window is None:
                sample.update(result="missed", reason="no window")
                return sample
            sample["window_ms"] = round(ms(window_at - spawned), 1)
            first, confirmed, table, area, last_verdict = None, None, None, None, None
            verdicts = {}
            deadline = time.monotonic() + PAGE_DEADLINE_S
            while time.monotonic() < deadline:
                if table is None:
                    table, area = hr.find_list(window)
                observed = check.tokens_from_items(hr.visible_items(table, area)) if table is not None else None
                verdict = check.classify(observed, answer, [])
                verdicts[verdict] = verdicts.get(verdict, 0) + 1
                last_verdict = verdict
                now = libc.mach_absolute_time()
                if verdict == "correct":
                    if first is not None:
                        confirmed = now
                        break
                    first = now
                else:
                    first = None
                    if verdict == "unreadable":
                        table = None   # the table may not exist yet, or was replaced
                time.sleep(0.02)  # deadline-fallback: paced AX read inside the page deadline
            sample["ax_verdicts"] = verdicts
            if confirmed is None:
                sample.update(result="missed", reason=f"no complete correct page in {PAGE_DEADLINE_S:.0f} s "
                                                      f"(last read {last_verdict})")
                return sample
            sample["ax_confirm_ms"] = round(ms(confirmed - spawned), 1)
            y_at_page = (ui.element_frame(area) or {}).get("y")   # the jump check starts here
            hold_end = time.monotonic() + HOLD_MS / 1000
            held = True
            while time.monotonic() < hold_end:
                if check.classify(check.tokens_from_items(hr.visible_items(table, area)), answer, []) != "correct":
                    held = False
                time.sleep(0.03)  # deadline-fallback: paced AX read inside the hold
            held_until = libc.mach_absolute_time()
            if storage_warning or watch:
                sample["banner"] = watch_banner(window, area, spawned, y_at_page)
            a, w = ui.element_frame(area), ui.element_frame(window)
            sample["list_rect"] = f"{int(a['x'])},{int(a['y'])},{int(a['width'] - SCROLL_BAR)},{int(a['height'])}"
            sample["window_frame"] = w
            if recorder is None:
                if mode == "existing":
                    # Untimed: the existing-catalog samples need a COMPLETE catalog, and an earlier
                    # missing-catalog sample may have stopped right after its first page (Codex round 6).
                    deadline = time.monotonic() + COVERAGE_DEADLINE_S
                    while time.monotonic() < deadline and not coverage_complete():
                        time.sleep(1)  # deadline-fallback: poll the catalog's coverage signal
                    sample["coverage_complete"] = coverage_complete()
                    if not sample["coverage_complete"]:
                        raise RuntimeError("the catalog never reached full coverage before existing-catalog samples")
                sample.update(result="warmup")
                return sample
            header, frames = stop_recorder(recorder, frames_path)
            recorder = None
            if not held:
                sample.update(result="unknown", reason="the page did not stay correct for the hold")
                return sample
            if sample["list_rect"] != rect:
                sample.update(result="invalid", reason=f"list moved: {sample['list_rect']} vs {rect}")
                return sample
            reference, why = search_frames.reference_from_frames(frames, held_until, header["timebase_numer"],
                                                                 header["timebase_denom"], HOLD_MS)
            if reference is None:
                sample.update(result="unknown", reason=f"no held picture: {why}")
                return sample
            complete = search_frames.complete_frames(frames)
            after = [f for f in complete if f["display"] >= spawned]
            hit = next((f for f in after if f["hash"] == reference), None)
            if hit is None:
                sample.update(result="unknown", reason="no captured frame shows the verified page")
                return sample
            sample["launch_to_page_ms"] = round(ms(hit["display"] - spawned), 1)
            sample["window_to_page_ms"] = round(ms(hit["display"] - window_at), 1)
            sample["capture_late"] = hit is after[0]
            sample["frames_after_spawn"] = len(after)
            sample["result"] = "timed"
            return sample
        finally:
            if recorder is not None:
                recorder.kill()
                recorder.wait()
            if pid is not None:
                fixture.stop(pid, executable)

    # ------------------------------------------------------------------ session
    fixture._default_owner_check()
    fixture.refuse_existing_throwaway(real_home)
    production_before = fixture.export_domain(fixture.PRODUCTION_DOMAIN)
    report = {"mode": mode, "subject": str(subject), "home": str(home), "control": control,
              "storage_warning": storage_warning,
              "budget_ms": BUDGET_MS, "answer_rows_checked": "newest Dictations, unfiltered",
              "conditions_start": load_tools.machine_conditions(), "samples": []}
    busy = load_tools.BusyLoad() if "--busy" in argv else None
    report["busy"] = busy.count if busy else 0
    problems = []
    try:
        if busy:
            busy.__enter__()
        rect = None
        for index in range(warmups):
            sample = one_launch(index, None, False)
            report["samples"].append(sample)
            rect = sample.get("list_rect", rect)
            print(json.dumps({k: sample.get(k) for k in ("index", "result", "list_rect", "ax_confirm_ms")}), flush=True)
        if rect is None:
            raise RuntimeError("warm-up never showed the page; cannot place the capture")
        report["capture_rect"] = rect
        for index in range(warmups, warmups + samples):
            sample = one_launch(index, rect, True)
            report["samples"].append(sample)
            print(json.dumps({k: sample.get(k) for k in ("index", "result", "launch_to_page_ms", "window_ms",
                                                          "capture_late", "reason")}), flush=True)
            (out / "report.json").write_text(json.dumps(report, indent=1))
    finally:
        if busy:
            busy.__exit__(None, None, None)
        try:   # the comparison and the cleanup are attempted independently; both failures are reported
            production_after = fixture.export_domain(fixture.PRODUCTION_DOMAIN)
            changed = sorted(k for k in set(production_before or {}) | set(production_after or {})
                             if (production_before or {}).get(k) != (production_after or {}).get(k))
            report["production_changed_keys"] = changed
            if changed:
                problems.append(f"production preferences changed (not restored): {changed}")
        except Exception as error:
            problems.append(f"production comparison: {error}")
        try:
            report["throwaway_removed"] = fixture.cleanup_throwaway(real_home)
        except Exception as error:   # cleanup failure is a finding, reported, never hidden
            problems.append(f"cleanup: {error}")
    measured = [s for s in report["samples"] if s["measured"]]
    timed = [s["launch_to_page_ms"] for s in measured if s["result"] == "timed"]
    counts = {}
    for s in measured:
        counts[s["result"]] = counts.get(s["result"], 0) + 1
    report["results"] = counts
    report["launch_to_page_ms"] = percentiles(timed)   # timed samples only
    # Every attempt counts: a missed or untimed sample is slower than any timed one (or unknown), so
    # the all-attempt p95 is only a number when it falls on a timed sample (Codex round 1).
    attempts = sorted(timed) + [float("inf")] * (len(measured) - len(timed))
    if attempts:
        p95_all = attempts[ceil(len(attempts) * .95) - 1]
        report["launch_to_page_all_attempts_p95_ms"] = p95_all if p95_all != float("inf") else "not measured (missed or untimed samples)"
        report["attempts"] = len(measured)
    report["window_to_page_ms"] = percentiles([s["window_to_page_ms"] for s in measured if s["result"] == "timed"])
    report["window_ms"] = percentiles([s["window_ms"] for s in measured if "window_ms" in s])
    report["capture_late"] = sum(1 for s in measured if s.get("capture_late"))
    if storage_warning or watch:   # the labelled jump check: banner seen and how far it moved the page
        banners = [s["banner"] for s in measured if s.get("banner")]
        report["banner_jump"] = {"samples": len(banners),
                                 "seen": sum(1 for b in banners if b["seen_at_ms"] is not None),
                                 "seen_at_ms": sorted(b["seen_at_ms"] for b in banners if b["seen_at_ms"] is not None),
                                 "jump_pt": sorted(b["jump_pt"] for b in banners if b["jump_pt"] is not None)}
    p95 = report["launch_to_page_ms"].get("p95")
    if counts.get("missed") or (p95 is not None and p95 > BUDGET_MS):
        verdict = "FAIL"
    elif timed and set(counts) == {"timed"}:
        verdict = "PASS"
    else:
        verdict = "UNPROVEN"
    report["budget_verdict"] = verdict
    report["conditions_end"] = load_tools.machine_conditions()
    report["problems"] = problems
    (out / "report.json").write_text(json.dumps(report, indent=1))
    print(json.dumps({k: report.get(k) for k in ("mode", "results", "launch_to_page_ms", "launch_to_page_all_attempts_p95_ms", "window_to_page_ms",
                                             "capture_late", "budget_verdict", "problems")}))
    return 0 if verdict == "PASS" and not problems else 1


if __name__ == "__main__":
    sys.exit(main())
