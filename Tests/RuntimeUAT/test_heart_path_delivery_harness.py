#!/usr/bin/env python3
"""Deterministic guard tests for the #2142 real-delivery receipt."""

import importlib.util
import pathlib
import sys

SUBJECT_PATH = pathlib.Path(__file__).with_name("test_heart_path_delivery.py")
SPEC = importlib.util.spec_from_file_location("heart_path_delivery", SUBJECT_PATH)
subject = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(subject)

failures = []


def check(name, condition):
    print(f"{'PASS' if condition else 'FAIL'} {name}")
    if not condition:
        failures.append(name)


check("one expected phrase is accepted", subject.count_phrase("The quick brown fox arrived.") == 1)
check(
    "duplicate delivery is visible",
    subject.count_phrase("quick brown fox / QUICK BROWN FOX") == 2,
)
check("missing delivery is visible", subject.count_phrase("something else") == 0)
check(
    "silent transcript counts words without exposing content",
    subject.raw_asr_word_count(
        "CORRECTION_DEBUG [RAW ASR] three private words\n"
    )
    == 3,
)
check(
    "absent raw transcript is unavailable",
    subject.raw_asr_word_count("dictation_terminal result=no_speech") is None,
)
check(
    "explicit no-speech terminal proves silence",
    subject.silent_probe_word_count("dictation_terminal result=no_speech") == 0,
)
try:
    subject.silent_probe_word_count("dictation_terminal result=completed")
    check("missing silence evidence is refused", False)
except subject.ReceiptFailure:
    check("missing silence evidence is refused", True)

check(
    "blank silent probe does not generate TTS",
    not subject.w._recording_should_generate_tts(" "),
)
check(
    "default recording still generates TTS",
    subject.w._recording_should_generate_tts(None),
)
check(
    "spoken fixture still generates TTS",
    subject.w._recording_should_generate_tts("hello"),
)
check(
    "WhisperKit preference keeps its case-sensitive raw value",
    subject.preserved_backend_value("whisperKit") == "whisperKit",
)
try:
    subject.preserved_backend_value("whisperkit")
    check("invalid lowercase WhisperKit preference is refused", False)
except subject.ReceiptFailure:
    check("invalid lowercase WhisperKit preference is refused", True)
check(
    "active recording state is detected",
    subject.in_flight("Recording started\nother log line"),
)
check(
    "terminal recording state is idle",
    not subject.in_flight("Recording started\ndictation_terminal result=completed"),
)
check(
    "relaunch polling tolerates no process yet",
    subject.unique_running_executable([], allow_absent=True) is None,
)
try:
    subject.unique_running_executable([], allow_absent=False)
    check("subject verification refuses no process", False)
except subject.ReceiptFailure:
    check("subject verification refuses no process", True)

original_running_apps = subject.running_enviouswispr_executables
subject.running_enviouswispr_executables = lambda: [
    (10, subject.APP_EXECUTABLE.resolve())
]
try:
    subject.refuse_competing_apps(allow_subject=True)
    check("the verified worktree app is allowed", True)
except subject.ReceiptFailure:
    check("the verified worktree app is allowed", False)
subject.running_enviouswispr_executables = lambda: [
    (10, subject.APP_EXECUTABLE.resolve()),
    (11, pathlib.Path("/Applications/EnviousWispr.app/Contents/MacOS/EnviousWispr")),
]
try:
    subject.refuse_competing_apps(allow_subject=True)
    check("a production app competing for PTT is refused", False)
except subject.ReceiptFailure:
    check("a production app competing for PTT is refused", True)
finally:
    subject.running_enviouswispr_executables = original_running_apps

valid_capture = [{
    "_kind": "source",
    "backend": "hal_device_input",
    "boundUID": "BuiltInMicrophoneDevice",
    "boundTransport": "built_in",
    "bindOK": "true",
    "requestedUID": "BuiltInMicrophoneDevice",
}]
try:
    subject.assert_builtin_microphone_evidence(valid_capture)
    check("actual built-in microphone binding is accepted", True)
except subject.ReceiptFailure:
    check("actual built-in microphone binding is accepted", False)
try:
    subject.assert_builtin_microphone_evidence(
        [{**valid_capture[0], "requestedUID": "system_default"}]
    )
    check("Auto input with actual built-in binding is accepted", True)
except subject.ReceiptFailure:
    check("Auto input with actual built-in binding is accepted", False)

for name, evidence in (
    ("missing actual microphone evidence is refused", []),
    ("duplicate source evidence is refused", valid_capture * 2),
    (
        "virtual microphone binding is refused",
        [{**valid_capture[0], "boundUID": "BlackHole2ch_UID", "boundTransport": "virtual"}],
    ),
    ("failed microphone binding is refused", [{**valid_capture[0], "bindOK": "false"}]),
    (
        "another explicitly requested input is refused",
        [{**valid_capture[0], "requestedUID": "BlackHole2ch_UID"}],
    ),
):
    try:
        subject.assert_builtin_microphone_evidence(evidence)
        check(name, False)
    except subject.ReceiptFailure:
        check(name, True)

original_get_ax_app = subject.ui_helpers.get_ax_app
original_find_all = subject.ui_helpers.find_all_elements
original_ui_get_attr = subject.ui_helpers.get_attr
subject.ui_helpers.get_ax_app = lambda _pid: "app"
subject.ui_helpers.find_all_elements = lambda _app, role: [
    {"AXTitle": "Start Recording", "AXEnabled": True}
]
subject.ui_helpers.get_attr = lambda item, attribute: item.get(attribute)
try:
    check("live AX Start Recording menu means idle", subject.ax_recording_state(42) == "idle")
    subject.ui_helpers.find_all_elements = lambda _app, role: [
        {"AXTitle": "Start Recording", "AXEnabled": True},
        {"AXTitle": "Start Recording", "AXEnabled": True},
    ]
    check(
        "duplicate AX traversal of enabled Start remains idle",
        subject.ax_recording_state(42) == "idle",
    )
    subject.ui_helpers.find_all_elements = lambda _app, role: [
        {"AXTitle": "Start Recording", "AXEnabled": False}
    ]
    check(
        "disabled Start Recording menu means processing",
        subject.ax_recording_state(42) == "processing",
    )
    subject.ui_helpers.find_all_elements = lambda _app, role: [
        {"AXTitle": "Stop Recording", "AXEnabled": True}
    ]
    check(
        "live AX Stop Recording menu means active",
        subject.ax_recording_state(42) == "recording",
    )
    subject.ui_helpers.find_all_elements = lambda _app, role: []
    check("missing live menu state is unknown", subject.ax_recording_state(42) == "unknown")
finally:
    subject.ui_helpers.get_ax_app = original_get_ax_app
    subject.ui_helpers.find_all_elements = original_find_all
    subject.ui_helpers.get_attr = original_ui_get_attr

original_subject_pid = subject.subject_pid_for_executable
original_process_match = subject.process_still_matches_subject
original_w_finder = subject.w.find_app_pid
original_ui_finder = subject.ui_helpers.find_app_pid
subject.subject_pid_for_executable = lambda: 4242
subject.process_still_matches_subject = lambda pid: pid == 4242
try:
    pinned_pid = subject.pin_wispr_eyes_to_subject()
    check(
        "both Whisper Eyes lookup layers pin the verified PID",
        pinned_pid == 4242
        and subject.w.find_app_pid("EnviousWispr") == 4242
        and subject.ui_helpers.find_app_pid("EnviousWispr") == 4242,
    )
finally:
    subject.subject_pid_for_executable = original_subject_pid
    subject.process_still_matches_subject = original_process_match
    subject.w.find_app_pid = original_w_finder
    subject.ui_helpers.find_app_pid = original_ui_finder
check(
    "clean WhisperKit warm-up is accepted",
    subject.whisperkit_warm_completed("WhisperKit warm-up: completed(2069ms)"),
)
check(
    "failed WhisperKit warm-up is refused",
    not subject.whisperkit_warm_completed("WhisperKit warm-up: timed_out"),
)

original_post_ptt = subject.w._post_ptt_key_event
ptt_edges = []
subject.w._post_ptt_key_event = lambda key, is_down: ptt_edges.append((key, is_down))
try:
    with subject.w._held_ptt_key("rcmd"):
        raise RuntimeError("synthetic playback failure")
except RuntimeError:
    pass
finally:
    subject.w._post_ptt_key_event = original_post_ptt
check(
    "exceptional PTT path releases the key",
    ptt_edges == [("rcmd", True), ("rcmd", False)],
)

original_modifier_down = subject.si.modifier_down
original_modifier_up = subject.si.modifier_up
original_input_sleep = subject.si.time.sleep
modifier_edges = []
subject.si.modifier_down = lambda keycode: modifier_edges.append((keycode, True))
subject.si.modifier_up = lambda keycode: modifier_edges.append((keycode, False))
subject.si.time.sleep = lambda _seconds: (_ for _ in ()).throw(
    RuntimeError("interrupted hold")
)
try:
    subject.si.hold_modifier(54, 1.0)
except RuntimeError:
    pass
finally:
    subject.si.modifier_down = original_modifier_down
    subject.si.modifier_up = original_modifier_up
    subject.si.time.sleep = original_input_sleep
check(
    "interrupted generic modifier hold releases the key",
    modifier_edges == [(54, True), (54, False)],
)

original_textedit_value = subject.textedit_value
original_monotonic = subject.time.monotonic
original_sleep = subject.time.sleep
ticks = iter((0.0, 0.1))
values = iter(("quick brown fox quick brown fox",))
subject.time.monotonic = lambda: next(ticks)
subject.time.sleep = lambda _seconds: None
subject.textedit_value = lambda _path: next(values)
try:
    subject.stable_exact_once_value(pathlib.Path("unused"), "quick brown fox")
    check("delayed duplicate delivery is refused", False)
except subject.ReceiptFailure:
    check("delayed duplicate delivery is refused", True)
finally:
    subject.textedit_value = original_textedit_value
    subject.time.monotonic = original_monotonic
    subject.time.sleep = original_sleep

original_focus_document = subject.focus_document
original_textedit_value = subject.textedit_value
original_press_key = subject.w.press_key
original_wait_for = subject.wait_for
cleanup_calls = []
cleanup_values = iter(("", None))
subject.focus_document = lambda path: cleanup_calls.append(("focus", path.name))
subject.textedit_value = lambda _path: next(cleanup_values)
subject.w.press_key = lambda key, **kwargs: cleanup_calls.append(("press", key, kwargs))
subject.wait_for = lambda _description, predicate, **_kwargs: predicate()
try:
    subject.close_document(pathlib.Path("hidden-tab.txt"))
finally:
    subject.focus_document = original_focus_document
    subject.textedit_value = original_textedit_value
    subject.w.press_key = original_press_key
    subject.wait_for = original_wait_for
check(
    "cleanup activates a hidden TextEdit tab before closing",
    cleanup_calls[0] == ("focus", "hidden-tab.txt")
    and cleanup_calls[1][0:2] == ("press", "w"),
)

valid = """
dictation_started take=1 backend=parakeet
Paste cascade: tier=ax_direct, app=com.apple.TextEdit
dictation_terminal result=completed take=1 backend=parakeet
"""
try:
    subject.assert_backend_evidence("parakeet", valid)
    check("complete production evidence is accepted", True)
except subject.ReceiptFailure:
    check("complete production evidence is accepted", False)

for name, evidence in (
    ("wrong backend is refused", valid.replace("parakeet", "whisperKit")),
    ("missing terminal is refused", valid.replace("dictation_terminal", "other")),
    ("wrong target is refused", valid.replace("com.apple.TextEdit", "com.apple.Terminal")),
    ("missing take id is refused", valid.replace("take=1", "session=1", 1)),
    ("duplicate start is refused", valid + "dictation_started take=2 backend=parakeet\n"),
):
    try:
        subject.assert_backend_evidence("parakeet", evidence)
        check(name, False)
    except subject.ReceiptFailure:
        check(name, True)

sys.exit(1 if failures else 0)
