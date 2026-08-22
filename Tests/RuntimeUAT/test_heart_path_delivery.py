#!/usr/bin/env python3
"""Real-boundary receipt for capture -> shipped ASR -> TextEdit delivery (#2142).

Run through ``scripts/test-heart-path-delivery.sh``. That runner rebuilds and
launches this worktree's dev app before this file drives it. The receipt uses a
real microphone capture (the committed speech clip is played through the Mac's
speakers), each shipped ASR backend, the production PTT path, and a real
foreground TextEdit document.

This is intentionally fail-closed. An unreadable TextEdit field, a missing
pipeline signal, an unverified backend selection, or a skipped backend is a
failed receipt rather than a pass with weaker evidence.
"""

from __future__ import annotations

import contextlib
import io
import os
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
sys.path.insert(0, str(HERE))

import simulate_input as si  # noqa: E402
import ui_helpers  # noqa: E402
import wispr_eyes as w  # noqa: E402
from capture_bakeoff import (  # noqa: E402
    EXPECTED_BACKEND as EXPECTED_CAPTURE_BACKEND,
    _bt_route_line_count,
    read_new_evidence,
)
from ptt_binding import PTTBindingError, resolve  # noqa: E402
from ui_helpers import (  # noqa: E402
    activate_app,
    find_app_pid,
    find_element,
    get_attr,
    get_ax_app,
    perform_action,
    set_attr,
)

APP = ROOT / "build" / "EnviousWispr Local.app"
APP_EXECUTABLE = APP / "Contents" / "MacOS" / "EnviousWispr"
FIXTURE = ROOT / "scripts" / "freeze-suite" / "clips" / "normal-speech.wav"
LOG = Path.home() / "Library" / "Logs" / "EnviousWispr" / "app.log"
SHARED_DOMAIN = "com.enviouswispr.app"
EXPECTED_PHRASE = "quick brown fox"
BACKENDS = ("parakeet", "whisperkit")
BUILT_IN_MICROPHONE_UID = "BuiltInMicrophoneDevice"


class ReceiptFailure(RuntimeError):
    """The run did not prove the real product outcome."""


def wait_for(description, predicate, deadline=60.0, poll=0.2):
    end = time.monotonic() + deadline
    while time.monotonic() < end:
        value = predicate()
        if value:
            return value
        time.sleep(poll)
    raise ReceiptFailure(f"no signal for {description} within {deadline:.0f}s")


def screen_is_locked():
    import Quartz

    session = Quartz.CGSessionCopyCurrentDictionary()
    return bool(session.get("CGSSessionScreenIsLocked", 0)) if session else False


def audio_output_state():
    settings = subprocess.run(
        ["osascript", "-e", "get volume settings"],
        capture_output=True,
        text=True,
        check=False,
    )
    if settings.returncode != 0:
        raise ReceiptFailure("cannot read the Mac's output volume and mute state")
    volume_match = re.search(r"output volume:(\d+)", settings.stdout)
    mute_match = re.search(r"output muted:(true|false)", settings.stdout)
    if not volume_match or not mute_match:
        raise ReceiptFailure(f"cannot parse output settings: {settings.stdout.strip()!r}")
    route = subprocess.run(
        ["SwitchAudioSource", "-c", "-t", "output"],
        capture_output=True,
        text=True,
        check=False,
    )
    if route.returncode != 0 or not route.stdout.strip():
        raise ReceiptFailure("cannot verify the current audio output route")
    return int(volume_match.group(1)), mute_match.group(1) == "true", route.stdout.strip()


def log_lines():
    if not LOG.exists():
        raise ReceiptFailure(f"debug app log is missing: {LOG}")
    return LOG.read_text(errors="replace").splitlines()


def log_since(snapshot):
    """Read this take's log window without assuming app.log kept its inode."""
    lines, _ = w._read_new_log_lines(snapshot)
    return "".join(lines)


def in_flight(text):
    last = None
    for line in text.splitlines():
        if "Recording started" in line:
            last = "start"
        elif "dictation_terminal" in line:
            last = "terminal"
    return last == "start"


def running_enviouswispr_executables():
    """Return every process that can receive EnviousWispr's global PTT event."""
    result = subprocess.run(
        ["pgrep", "-x", "EnviousWispr"],
        capture_output=True,
        text=True,
        check=False,
    )
    matches = []
    for raw_pid in result.stdout.split():
        command = subprocess.run(
            ["ps", "-p", raw_pid, "-o", "comm="],
            capture_output=True,
            text=True,
            check=False,
        ).stdout.strip()
        if command:
            matches.append((int(raw_pid), Path(command).resolve()))
    return matches


def refuse_competing_apps(allow_subject):
    """Reject production or another dev app before posting a global PTT event."""
    subject = APP_EXECUTABLE.resolve()
    competing = [
        (pid, executable)
        for pid, executable in running_enviouswispr_executables()
        if not allow_subject or executable != subject
    ]
    if competing:
        detail = ", ".join(f"PID {pid}: {path}" for pid, path in competing)
        raise ReceiptFailure(
            f"another EnviousWispr app is running and could receive PTT: {detail}"
        )


def running_dev_executable():
    result = subprocess.run(
        ["pgrep", "-f", "EnviousWispr Local.app/Contents/MacOS/EnviousWispr"],
        capture_output=True,
        text=True,
        check=False,
    )
    matches = []
    for raw_pid in result.stdout.split():
        command = subprocess.run(
            ["ps", "-p", raw_pid, "-o", "comm="],
            capture_output=True,
            text=True,
            check=False,
        ).stdout.strip()
        if command:
            matches.append(command)
    return unique_running_executable(matches, allow_absent=False)


def unique_running_executable(matches, allow_absent):
    if not matches and allow_absent:
        return None
    if len(matches) != 1:
        raise ReceiptFailure(
            f"expected exactly one running dev app, found {len(matches)}: {matches}"
        )
    return Path(matches[0]).resolve()


def running_dev_executable_or_none():
    result = subprocess.run(
        ["pgrep", "-f", "EnviousWispr Local.app/Contents/MacOS/EnviousWispr"],
        capture_output=True,
        text=True,
        check=False,
    )
    matches = []
    for raw_pid in result.stdout.split():
        command = subprocess.run(
            ["ps", "-p", raw_pid, "-o", "comm="],
            capture_output=True,
            text=True,
            check=False,
        ).stdout.strip()
        if command:
            matches.append(command)
    return unique_running_executable(matches, allow_absent=True)


def subject_pid_for_executable():
    result = subprocess.run(
        ["pgrep", "-f", str(APP_EXECUTABLE)],
        capture_output=True,
        text=True,
        check=False,
    )
    matching = []
    for raw_pid in result.stdout.split():
        command = subprocess.run(
            ["ps", "-p", raw_pid, "-o", "comm="],
            capture_output=True,
            text=True,
            check=False,
        ).stdout.strip()
        if command and Path(command).resolve() == APP_EXECUTABLE.resolve():
            matching.append(int(raw_pid))
    if len(matching) != 1:
        raise ReceiptFailure(f"expected one verified worktree app PID, found {matching}")
    return matching[0]


def process_still_matches_subject(pid):
    command = subprocess.run(
        ["ps", "-p", str(pid), "-o", "comm="],
        capture_output=True,
        text=True,
        check=False,
    ).stdout.strip()
    return bool(command) and Path(command).resolve() == APP_EXECUTABLE.resolve()


def pin_wispr_eyes_to_subject():
    """Keep every high-level UAT call on this worktree's verified process."""
    pid = subject_pid_for_executable()
    fallback = w.find_app_pid

    def pinned_finder(name="EnviousWispr"):
        if name != "EnviousWispr":
            return fallback(name)
        return pid if process_still_matches_subject(pid) else None

    w.find_app_pid = pinned_finder
    ui_helpers.find_app_pid = pinned_finder
    return pid


def verify_subject():
    refuse_competing_apps(allow_subject=True)
    if screen_is_locked():
        raise ReceiptFailure("screen is locked; TextEdit cannot be a real foreground target")
    if not APP_EXECUTABLE.exists():
        raise ReceiptFailure(f"rebuilt app is missing: {APP_EXECUTABLE}")
    running = running_dev_executable()
    expected = APP_EXECUTABLE.resolve()
    if running != expected:
        raise ReceiptFailure(f"wrong dev app is running: {running}; expected {expected}")
    current = log_lines()
    if in_flight("\n".join(current[-400:])):
        raise ReceiptFailure("a recording is already live; refusing to stop someone else's take")
    volume, muted, route = audio_output_state()
    if volume <= 50 or muted:
        raise ReceiptFailure(
            f"speaker preflight failed: volume={volume}, muted={str(muted).lower()}"
        )
    if route != "MacBook Pro Speakers":
        raise ReceiptFailure(f"speaker preflight failed: output route is {route!r}")


def refuse_active_recording_before_build():
    """Fail before build-dev-app can terminate a live dev-app recording."""
    refuse_competing_apps(allow_subject=True)
    running = subprocess.run(
        ["pgrep", "-f", "EnviousWispr Local.app/Contents/MacOS/EnviousWispr"],
        capture_output=True,
        text=True,
        check=False,
    )
    if running.returncode != 0:
        return
    for raw_pid in running.stdout.split():
        state = ax_recording_state(int(raw_pid))
        if state == "recording":
            raise ReceiptFailure("a recording is active; refusing the rebuild")
        if state != "idle":
            raise ReceiptFailure(
                f"cannot verify recording state for dev-app PID {raw_pid}; refusing the rebuild"
            )


def ax_recording_state(pid):
    """Return live menu state without relying on Debug Mode or app.log."""
    app = ui_helpers.get_ax_app(pid)
    items = ui_helpers.find_all_elements(app, role="AXMenuItem")
    start_items = [
        item
        for item in items
        if str(ui_helpers.get_attr(item, "AXTitle") or "") == "Start Recording"
    ]
    has_stop = any(
        str(ui_helpers.get_attr(item, "AXTitle") or "") == "Stop Recording"
        for item in items
    )
    has_start = bool(start_items)
    if has_stop and not has_start:
        return "recording"
    if has_start and not has_stop:
        enabled_values = [ui_helpers.get_attr(item, "AXEnabled") for item in start_items]
        if any(value is None for value in enabled_values):
            return "unknown"
        return "idle" if all(bool(value) for value in enabled_values) else "processing"
    return "unknown"


def selected_backend_snapshot():
    result = subprocess.run(
        ["defaults", "export", SHARED_DOMAIN, "-"],
        capture_output=True,
        check=False,
    )
    if result.returncode != 0:
        raise ReceiptFailure("cannot snapshot selectedBackend before the receipt")
    try:
        domain = plistlib.loads(result.stdout)
    except Exception as error:
        raise ReceiptFailure(f"cannot parse the shared settings domain: {error}") from error
    present = "selectedBackend" in domain
    value = domain.get("selectedBackend", "parakeet")
    return present, preserved_backend_value(value)


def preserved_backend_value(value):
    if not isinstance(value, str):
        raise ReceiptFailure(f"selectedBackend is not a string: {value!r}")
    if value in ("whisperKit", "parakeet"):
        return value
    raise ReceiptFailure(f"cannot preserve unknown selectedBackend value: {value!r}")


def textedit_value(path):
    pid = find_app_pid("TextEdit")
    if pid is None:
        return None
    wanted = path.name
    app = get_ax_app(pid)
    for window in get_attr(app, "AXWindows") or []:
        if str(get_attr(window, "AXTitle") or "") != wanted:
            continue
        area = find_element(window, role="AXTextArea")
        if area is None:
            return None
        return str(get_attr(area, "AXValue") or "")
    return None


def focus_document(path):
    subprocess.run(["open", "-a", "TextEdit", str(path)], check=True)
    wait_for(
        f"TextEdit document {path.name} to become accessibility-readable",
        lambda: textedit_area(path) is not None,
        deadline=10.0,
    )
    area = textedit_area(path)
    if area is None:
        raise ReceiptFailure(f"TextEdit area disappeared for {path.name}")

    def activate_target():
        pid = find_app_pid("TextEdit")
        if pid is None:
            return False
        app = get_ax_app(pid)
        wanted = path.name
        window = next(
            (
                candidate
                for candidate in (get_attr(app, "AXWindows") or [])
                if str(get_attr(candidate, "AXTitle") or "") == wanted
            ),
            None,
        )
        if window is None:
            return False
        # ``open -a`` can open a document without activating TextEdit when the
        # menu-bar dev app is still settling. Target the exact PID and window;
        # never post the later PTT event until both report focused.
        activate_app(pid)
        set_attr(app, "AXFrontmost", True)
        perform_action(window, "AXRaise")
        set_attr(window, "AXMain", True)
        set_attr(area, "AXFocused", True)
        return (
            frontmost_bundle_id() == "com.apple.TextEdit"
            and bool(get_attr(area, "AXFocused"))
        )

    wait_for(
        f"TextEdit document {path.name} to become the foreground target",
        activate_target,
        deadline=10.0,
    )


def frontmost_bundle_id():
    """Read live focus through System Events (NSWorkspace is stale without a run loop)."""
    result = subprocess.run(
        [
            "osascript",
            "-e",
            'tell application "System Events" to get bundle identifier of first process whose frontmost is true',
        ],
        capture_output=True,
        text=True,
        check=False,
    )
    return result.stdout.strip() if result.returncode == 0 else ""


def textedit_area(path):
    pid = find_app_pid("TextEdit")
    if pid is None:
        return None
    wanted = path.name
    app = get_ax_app(pid)
    for window in get_attr(app, "AXWindows") or []:
        if str(get_attr(window, "AXTitle") or "") == wanted:
            return find_element(window, role="AXTextArea")
    return None


def verify_textedit_oracle(path):
    marker = "ew-delivery-oracle-check"
    focus_document(path)
    si.type_text(marker)
    wait_for(
        "TextEdit oracle control text",
        lambda: marker in (textedit_value(path) or ""),
        deadline=10.0,
    )
    w.connect()
    w.press_key("a", cmd=True)
    w.press_key("delete")
    wait_for("TextEdit oracle clear", lambda: textedit_value(path) == "", deadline=5.0)


def fixture_duration():
    result = subprocess.run(
        ["afinfo", str(FIXTURE)], capture_output=True, text=True, check=True
    )
    for line in result.stdout.splitlines():
        if "estimated duration" in line.lower():
            return float(line.split()[-2])
    raise ReceiptFailure(f"could not read fixture duration: {FIXTURE}")


def count_phrase(text):
    return text.lower().count(EXPECTED_PHRASE)


def raw_asr_word_count(evidence):
    raw = ""
    found = False
    for line in evidence.splitlines():
        if "CORRECTION_DEBUG [RAW ASR]" in line:
            found = True
            raw = line.split("CORRECTION_DEBUG [RAW ASR]", 1)[1].strip()
    return len(re.findall(r"[A-Za-z0-9']+", raw)) if found else None


def silent_probe_word_count(evidence):
    words = raw_asr_word_count(evidence)
    if words is not None:
        return words
    if "dictation_terminal result=no_speech" in evidence:
        return 0
    raise ReceiptFailure("silent probe has neither raw ASR nor an explicit no-speech result")


def assert_builtin_microphone_evidence(evidence):
    """Prove this take bound the Mac's physical built-in microphone."""
    source = [record for record in evidence if record.get("_kind") == "source"]
    if len(source) != 1:
        raise ReceiptFailure(
            f"expected one source-side capture record for this take, found {len(source)}"
        )
    record = source[0]
    expected = {
        "backend": EXPECTED_CAPTURE_BACKEND,
        "boundUID": BUILT_IN_MICROPHONE_UID,
        "boundTransport": "built_in",
        "bindOK": "true",
    }
    mismatches = [
        f"{key}={record.get(key)!r}"
        for key, value in expected.items()
        if record.get(key) != value
    ]
    if mismatches:
        raise ReceiptFailure(
            "capture did not prove the built-in microphone: " + ", ".join(mismatches)
        )
    requested = record.get("requestedUID")
    if requested not in (BUILT_IN_MICROPHONE_UID, "system_default"):
        raise ReceiptFailure(
            f"capture requested an unexpected input device: requestedUID={requested!r}"
        )


def whisperkit_warm_completed(evidence):
    return "WhisperKit warm-up: completed(" in evidence


def run_silent_probe(path):
    """Refuse acoustic UAT when a six-second silent capture hears the room."""
    print("\n[control] checking that the room is quiet")
    refuse_competing_apps(allow_subject=True)
    w.switch_backend("parakeet", wait=0.0)
    w.close_window()
    focus_document(path)
    baseline = w._snapshot_log_state()
    if baseline is None:
        raise ReceiptFailure("silent probe cannot snapshot app.log")
    capture_baseline = _bt_route_line_count()
    # The canonical probe intentionally returns False because its sentinel can
    # never match. Hide its transcript-bearing report and score raw word count.
    report = io.StringIO()
    with contextlib.redirect_stdout(report), contextlib.redirect_stderr(report):
        w.test_recording(
            audio=None,
            sentence=" ",
            hold=6.0,
            expect="\x00nomatch",
        )
    evidence = log_since(baseline)
    if not evidence.strip() or "dictation_terminal" not in evidence:
        raise ReceiptFailure("silent probe produced no complete log evidence")
    assert_take_lifecycle("parakeet", evidence)
    assert_builtin_microphone_evidence(read_new_evidence(capture_baseline))
    words = silent_probe_word_count(evidence)
    if words:
        raise ReceiptFailure(
            f"silent probe heard {words} words; room is occupied, so acoustic UAT stopped"
        )
    print("PASS control: silent probe heard no words")


def assert_backend_evidence(backend, evidence):
    expected = "whisperKit" if backend == "whisperkit" else "parakeet"
    assert_take_lifecycle(expected, evidence)
    if "Paste cascade:" not in evidence or "app=com.apple.TextEdit" not in evidence:
        raise ReceiptFailure(f"{backend}: production paste did not report a TextEdit target")


def assert_take_lifecycle(expected_backend, evidence):
    starts = [line for line in evidence.splitlines() if "dictation_started" in line]
    if len(starts) != 1 or f"backend={expected_backend}" not in starts[0]:
        raise ReceiptFailure(
            f"{expected_backend}: expected one matching dictation start, got {starts}"
        )
    take_match = re.search(r"\btake=([^\s]+)", starts[0])
    if take_match is None:
        raise ReceiptFailure(
            f"{expected_backend}: dictation start has no take identifier"
        )
    take_marker = take_match.group(1)
    terminals = [line for line in evidence.splitlines() if "dictation_terminal" in line]
    if len(terminals) != 1 or f"take={take_marker}" not in terminals[0]:
        raise ReceiptFailure(
            f"{expected_backend}: expected one terminal for take {take_marker}, got {terminals}"
        )
    return take_marker


def run_backend(backend, path):
    print(f"\n[{backend}] switching shipped backend")
    switch_snapshot = w._snapshot_log_state()
    if switch_snapshot is None:
        raise ReceiptFailure(f"{backend}: app.log disappeared before engine switch")
    w.switch_backend(backend, wait=0.0)
    if backend == "whisperkit":
        warm_evidence = wait_for(
            "WhisperKit's production warm-up completion",
            lambda: (
                evidence
                if "WhisperKit warm-up:" in (evidence := log_since(switch_snapshot))
                else None
            ),
            deadline=35.0,
        )
        if not whisperkit_warm_completed(warm_evidence):
            raise ReceiptFailure("whisperkit: production warm-up did not complete cleanly")
    w.close_window()
    focus_document(path)
    if textedit_value(path) != "":
        raise ReceiptFailure(f"{backend}: unique TextEdit document did not start empty")

    baseline = w._snapshot_log_state()
    if baseline is None:
        raise ReceiptFailure(f"{backend}: app.log disappeared before recording")
    refuse_competing_apps(allow_subject=True)
    capture_baseline = _bt_route_line_count()
    # Use Whisper Eyes' canonical PTT driver. It resolves the configured key,
    # keeps playback inside the key-down window, and owns bounded key release.
    if not w.test_ptt(audio=str(FIXTURE), expect=EXPECTED_PHRASE, timeout=90.0):
        raise ReceiptFailure(f"{backend}: canonical Whisper Eyes PTT run failed")

    wait_for(
        f"{backend} pipeline terminal",
        lambda: "dictation_terminal" in log_since(baseline),
        deadline=90.0,
    )
    wait_for(
        f"{backend} production TextEdit paste receipt",
        lambda: (
            "Paste cascade:" in log_since(baseline)
            and "app=com.apple.TextEdit" in log_since(baseline)
        ),
        deadline=10.0,
    )
    first_value = wait_for(
        f"{backend} text arrival in TextEdit",
        lambda: (
            value
            if (value := textedit_value(path)) is not None
            and count_phrase(value) > 0
            else None
        ),
        deadline=15.0,
    )
    final_value = stable_exact_once_value(path, first_value)
    evidence = log_since(baseline)
    if not evidence.strip():
        raise ReceiptFailure(f"{backend}: app.log produced no evidence for this take")
    assert_backend_evidence(backend, evidence)
    assert_builtin_microphone_evidence(read_new_evidence(capture_baseline))
    occurrences = count_phrase(final_value)
    if occurrences != 1:
        raise ReceiptFailure(
            f"{backend}: expected {EXPECTED_PHRASE!r} exactly once in TextEdit, "
            f"found {occurrences}; value={final_value!r}"
        )
    print(f"PASS {backend}: real capture reached TextEdit exactly once")
    return final_value


def stable_exact_once_value(path, initial_value, stability_seconds=2.0):
    """Require the TextEdit value to stay exactly-once after the first arrival."""
    value = initial_value
    stable_since = time.monotonic()
    deadline = stable_since + stability_seconds + 5.0
    while time.monotonic() < deadline:
        current = textedit_value(path)
        if current is None:
            raise ReceiptFailure("TextEdit document disappeared during stability check")
        occurrences = count_phrase(current)
        if occurrences != 1:
            raise ReceiptFailure(
                f"delivery changed during stability check; expected once, found {occurrences}"
            )
        if current != value:
            value = current
            stable_since = time.monotonic()
        elif time.monotonic() - stable_since >= stability_seconds:
            return value
        time.sleep(0.1)
    raise ReceiptFailure("TextEdit delivery did not stabilize within the bounded window")


def close_document(path):
    # TextEdit may group documents as tabs. Reopening the owned path activates
    # its tab so its title and value become AX-visible before cleanup decides.
    focus_document(path)
    value = textedit_value(path)
    if value is None:
        raise ReceiptFailure(f"cannot activate owned TextEdit document {path.name}")
    if value:
        w.press_key("s", cmd=True)
        wait_for(
            "TextEdit save",
            lambda: path.read_text(errors="replace") == value,
            deadline=5.0,
        )
    w.press_key("w", cmd=True)
    wait_for("TextEdit window close", lambda: textedit_value(path) is None, deadline=5.0)


def stop_leaked_recording():
    recent = "\n".join(log_lines()[-400:])
    if not in_flight(recent):
        return
    print("CLEANUP: cancelling a recording started by this receipt", file=sys.stderr)
    si.press_key("escape")
    try:
        wait_for(
            "receipt recording to stop",
            lambda: not in_flight("\n".join(log_lines()[-400:])),
            deadline=15.0,
        )
    except ReceiptFailure:
        subprocess.run(["pkill", "-f", str(APP_EXECUTABLE)], check=False)


def stop_subject_app():
    subprocess.run(["pkill", "-f", str(APP_EXECUTABLE)], check=False)
    wait_for(
        "receipt app to exit",
        lambda: subprocess.run(
            ["pgrep", "-f", str(APP_EXECUTABLE)], capture_output=True, check=False
        ).returncode
        != 0,
        deadline=15.0,
    )


def restore_backend(snapshot):
    present, backend = snapshot
    stop_subject_app()
    if present:
        subprocess.run(
            ["defaults", "write", SHARED_DOMAIN, "selectedBackend", "-string", backend],
            check=True,
        )
    else:
        subprocess.run(
            ["defaults", "delete", SHARED_DOMAIN, "selectedBackend"],
            capture_output=True,
            check=False,
        )
    if selected_backend_snapshot() != snapshot:
        raise ReceiptFailure("selectedBackend did not restore to its exact prior state")
    subprocess.run(["open", str(APP)], check=True)
    wait_for(
        "restored receipt app to relaunch",
        lambda: running_dev_executable_or_none() == APP_EXECUTABLE.resolve(),
        deadline=30.0,
    )


def run_receipt():
    verify_subject()
    subject_pid = pin_wispr_eyes_to_subject()
    if not FIXTURE.exists() or FIXTURE.stat().st_size < 8192:
        raise ReceiptFailure(f"committed speech fixture is missing or too small: {FIXTURE}")
    try:
        binding = resolve()
    except PTTBindingError as error:
        raise ReceiptFailure(f"cannot resolve the real PTT binding: {error}") from error
    if binding.recording_mode != "pushToTalk":
        raise ReceiptFailure(
            f"configured recording mode is {binding.recording_mode!r}, not pushToTalk"
        )

    original_backend = selected_backend_snapshot()
    frontmost = frontmost_bundle_id()
    duration = fixture_duration()
    workspace = Path(tempfile.mkdtemp(prefix="ew-heart-path-delivery-"))
    documents = {
        name: workspace / f"{workspace.name}-{name}-delivery.txt"
        for name in ("control", *BACKENDS)
    }
    for path in documents.values():
        path.write_text("")

    print("=== Heart Path TextEdit Delivery Receipt (#2142) ===")
    print(f"subject: {APP_EXECUTABLE}")
    print(f"subject PID: {subject_pid} (pinned for every Whisper Eyes call)")
    print(f"instrument: wispr_eyes={Path(w.__file__).resolve()}")
    print(f"instrument: simulate_input={Path(si.__file__).resolve()}")
    print(f"PTT: {binding.key_name}; fixture: {FIXTURE.name} ({duration:.2f}s)")
    results = {}
    backend_restored = False
    try:
        verify_textedit_oracle(documents["control"])
        print("PASS control: TextEdit field is readable and writable through Accessibility")
        run_silent_probe(documents["control"])
        for backend in BACKENDS:
            results[backend] = run_backend(backend, documents[backend])
    finally:
        try:
            stop_leaked_recording()
        except Exception as error:
            print(f"CLEANUP WARNING: could not stop recording: {error}", file=sys.stderr)
        try:
            restore_backend(original_backend)
            backend_restored = True
        except Exception as error:
            print(f"RESTORE FAILURE: selected backend was not restored: {error}", file=sys.stderr)
        for path in documents.values():
            try:
                close_document(path)
            except Exception as error:
                print(f"CLEANUP WARNING: could not close {path.name}: {error}", file=sys.stderr)
        shutil.rmtree(workspace, ignore_errors=True)
        if frontmost and frontmost not in ("com.apple.TextEdit", "com.enviouswispr.app.dev"):
            subprocess.run(["open", "-b", frontmost], check=False)

    if set(results) != set(BACKENDS):
        raise ReceiptFailure(f"not every shipped backend ran: {sorted(results)}")
    if not backend_restored:
        raise ReceiptFailure("the receipt passed but selectedBackend was not restored")
    print("\nPASS: both shipped backends delivered real captured speech exactly once")


def main():
    if sys.argv[1:] == ["--refuse-active-recording"]:
        try:
            refuse_active_recording_before_build()
        except ReceiptFailure as error:
            print(f"FAIL: {error}", file=sys.stderr)
            return 1
        print("PASS: no active dev-app recording")
        return 0
    if sys.argv[1:]:
        print(
            "Usage: test_heart_path_delivery.py [--refuse-active-recording]",
            file=sys.stderr,
        )
        return 2
    try:
        run_receipt()
    except (ReceiptFailure, subprocess.SubprocessError, OSError) as error:
        print(f"\nFAIL: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
