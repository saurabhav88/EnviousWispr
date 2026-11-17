"""Card actions on a recorded dictation: Show edits and Play (#4586 WP-A, parent scope 2026-11-17).

On the Dictations tab of a running subject, the driver picks the first visible card that has both a
"Play" and a "Show edits" button, then for each of N repeats:

- Show edits: press it (AXPress, timestamp taken right before the press), confirm by AX that the
  card now offers "Hide edits", hold, and time to the FIRST captured frame of the list that shows
  the held picture (`search_frames.reference_from_frames`). Then press "Hide edits" and wait until
  the card shows "Show edits" again (untimed).
- Play: press Play, confirm by AX that the card shows "Pause", hold, time to the first frame showing
  the held picture; then press Pause (untimed). The Mac's sound output is switched to "BlackHole 2ch"
  for the run and restored afterwards, so the room stays silent.

Both are upper bounds on the first correct picture (capture misses some frames). The AX labels
("Hide edits", "Pause") are read from the card's row only.

Usage: python3 m5-speed-card.py <pid> <subject .app> <new out dir> [--repeats 10]
The caller holds the dev-app lock and runs the subject inside fixture.ContainedSession.
"""
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
HOLD_MS = 300
DEADLINE_S = 10.0
SCROLL_BAR = 20
SILENT_OUTPUT = "BlackHole 2ch"


def percentiles(values):
    values = sorted(values)
    if not values:
        return {"n": 0}
    return {"n": len(values), "p50": statistics.median(values), "p95": values[ceil(len(values) * .95) - 1],
            "max": values[-1]}


def main():
    argv = sys.argv[1:]
    if len(argv) < 3 or argv[0] in ("-h", "--help"):
        print(__doc__)
        return 2
    sys.path.insert(0, str(RUNTIME_UAT))
    sys.path.insert(0, str(HERE))
    import ctypes
    import ui_helpers as ui
    import wispr_eyes as eyes
    import fixture
    import history_reader as hr
    import load_tools
    import search_frames

    pid, subject, out = int(argv[0]), Path(argv[1]), Path(argv[2])
    repeats = int(argv[argv.index("--repeats") + 1]) if "--repeats" in argv else 10
    fixture._default_owner_check()
    expected_executable = fixture.require_subject_pid(pid, subject)
    recorder_bin = RUNTIME_UAT.parent.parent / "build" / "history_speed" / "frame_recorder"
    out.mkdir(parents=True, exist_ok=False)
    libc = ctypes.CDLL("/usr/lib/libSystem.dylib")
    libc.mach_absolute_time.restype = ctypes.c_uint64

    class Timebase(ctypes.Structure):
        _fields_ = [("numer", ctypes.c_uint32), ("denom", ctypes.c_uint32)]
    tb = Timebase()
    libc.mach_timebase_info(ctypes.byref(tb))
    ms = lambda ticks: ticks * tb.numer / tb.denom / 1e6

    eyes.find_app_pid = ui.find_app_pid = lambda *a, **kw: pid
    eyes.connect()
    ui.activate_app(pid)
    assert eyes.nav("History"), "History did not open"
    window = (ui.get_attr(eyes._app, "AXWindows") or [None])[0]
    control = eyes._find_match(window, "Dictations", "AXButton", exact=True, mx=24)
    assert control is not None and ui.perform_action(control, "AXPress") is not False

    def wait(predicate, timeout, what):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            value = predicate()
            if value:
                return value
            time.sleep(0.01)  # deadline-fallback: paced AX read inside a deadline-bounded signal wait
        raise RuntimeError(f"timed out waiting for {what}")

    table, area = wait(lambda: (lambda t: t if t[0] is not None else None)(hr.find_list(window)), 15, "the list")

    def button(row, title):
        for element in ui.find_all_elements(row, "AXButton", max_depth=12):
            if ui.get_attr(element, "AXTitle") == title or ui.get_attr(element, "AXDescription") == title:
                return element
        return None

    def pick_row():
        for row in ui.get_attr(table, "AXVisibleRows") or []:
            if button(row, "Play") is not None and button(row, "Show edits") is not None:
                return row
        return None

    row = wait(pick_row, 15, "a visible card with Play and Show edits")
    row_index = ui.get_attr(row, "AXIndex")

    def current_row():
        for candidate in ui.get_attr(table, "AXVisibleRows") or []:
            if ui.get_attr(candidate, "AXIndex") == row_index:
                return candidate
        return None

    a, w = ui.element_frame(area), ui.element_frame(window)
    crop = f"{a['x'] - w['x']},{a['y'] - w['y']},{a['width'] - SCROLL_BAR},{a['height']}"

    def start_recorder(path):
        recorder = subprocess.Popen([str(recorder_bin), "--pid", str(pid), "--seconds", "60", "--out", str(path),
                                     "--crop", crop], stdout=subprocess.PIPE, text=True, bufsize=1)
        if not recorder.stdout.readline().startswith('{"ready"'):
            recorder.kill()
            raise RuntimeError("frame recorder did not start")
        return recorder

    def stop_recorder(recorder, path):
        recorder.send_signal(signal.SIGTERM)
        recorder.communicate(timeout=60)  # deadline-fallback: waits for the recorder to write and exit
        lines = [json.loads(l) for l in path.read_text().splitlines() if l.strip()]
        return lines[0], lines[1:]

    def timed_press(name, press_title, done_title, undo_title, rep):
        """Press `press_title` on the card, confirm `done_title` appears and holds, time the picture,
        then press `undo_title` and wait for `press_title` to return (untimed)."""
        path = out / f"{name}-{rep}.jsonl"
        recorder = start_recorder(path)
        try:
            target = button(current_row(), press_title)
            if target is None:
                return {"result": "invalid", "reason": f"no {press_title} button"}
            pressed = libc.mach_absolute_time()
            ui.perform_action(target, "AXPress")
            wait(lambda: current_row() is not None and button(current_row(), done_title) is not None, DEADLINE_S,
                 f"{done_title} on the card")
            confirmed = libc.mach_absolute_time()
            hold_end = time.monotonic() + HOLD_MS / 1000
            held = True
            while time.monotonic() < hold_end:
                if button(current_row(), done_title) is None:
                    held = False
                time.sleep(0.03)  # deadline-fallback: paced AX read inside the hold
            held_until = libc.mach_absolute_time()
        finally:
            header, frames = stop_recorder(recorder, path)
        record = {"ax_confirm_ms": round(ms(confirmed - pressed), 1)}
        reference, why = search_frames.reference_from_frames(frames, held_until, header["timebase_numer"],
                                                             header["timebase_denom"], HOLD_MS)
        complete = [f for f in search_frames.complete_frames(frames) if f["display"] >= pressed]
        hit = next((f for f in complete if f["hash"] == reference), None) if reference else None
        if not held or hit is None:
            record.update(result="unknown", reason="not held" if not held else (why or "no frame shows it"))
        else:
            record.update(result="timed", upper_ms=round(ms(hit["display"] - pressed), 1),
                          capture_late=hit is complete[0])
        undo = button(current_row(), undo_title)
        if undo is not None:
            ui.perform_action(undo, "AXPress")
        wait(lambda: current_row() is not None and button(current_row(), press_title) is not None, DEADLINE_S,
             f"{press_title} back on the card")
        time.sleep(0.5)  # settle: let the card finish collapsing before the next recording starts
        return record

    previous_output = subprocess.run(["SwitchAudioSource", "-c", "-t", "output"], capture_output=True,
                                     text=True).stdout.strip()
    subprocess.run(["SwitchAudioSource", "-t", "output", "-s", SILENT_OUTPUT], check=True, capture_output=True)
    report = {"pid": pid, "executable": expected_executable, "row_index": row_index,
              "conditions_start": load_tools.machine_conditions(), "edits": [], "play": [],
              "output_during_run": SILENT_OUTPUT, "output_restored_to": previous_output}
    try:
        for rep in range(repeats):
            report["edits"].append(timed_press("edits", "Show edits", "Hide edits", "Hide edits", rep))
            report["play"].append(timed_press("play", "Play", "Pause", "Pause", rep))
            print(json.dumps({"rep": rep, "edits": report["edits"][-1], "play": report["play"][-1]}), flush=True)
    finally:
        subprocess.run(["SwitchAudioSource", "-t", "output", "-s", previous_output], capture_output=True)
        report["output_after"] = subprocess.run(["SwitchAudioSource", "-c", "-t", "output"], capture_output=True,
                                                text=True).stdout.strip()
    for key in ("edits", "play"):
        report[f"{key}_ms"] = percentiles([r["upper_ms"] for r in report[key] if r.get("result") == "timed"])
        report[f"{key}_untimed"] = sum(1 for r in report[key] if r.get("result") != "timed")
    report["conditions_end"] = load_tools.machine_conditions()
    (out / "report.json").write_text(json.dumps(report, indent=1))
    print(json.dumps({k: report[k] for k in ("edits_ms", "play_ms", "edits_untimed", "play_untimed", "output_after")}))
    return 0


if __name__ == "__main__":
    sys.exit(main())
