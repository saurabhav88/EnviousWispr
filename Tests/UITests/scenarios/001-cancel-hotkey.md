# UAT Scenarios: Cancel Hotkey During Recording

## Feature Summary

ESC key (configurable) cancels an active recording immediately, discarding audio and returning to idle without pasting.

## Test Scenarios

### P0: Critical

#### test_esc_cancels_toggle_mode_recording
**Suite**: cancel_recording
**Layers**: CGEvent, AX value, AX structure
```
GIVEN the app is in .idle state
  AND recording mode is set to "toggle"
  AND microphone permission is granted
WHEN the user presses the recording hotkey (Ctrl+Shift+Space)
  AND waits 1 second
  AND presses ESC
THEN the pipeline state changes to .idle within 500ms
  AND the recording overlay disappears within 500ms
  AND no transcript is saved to history
  AND no text is placed on the clipboard
```

#### test_esc_cancels_recording_started_from_menu
**Suite**: cancel_recording
**Layers**: CGEvent, AX value, AX structure, clipboard
```
GIVEN the app is in .idle state
WHEN the user clicks the menu bar status item
  AND clicks "Start Recording"
  AND waits 1 second
  AND presses ESC
THEN the pipeline state changes to .idle within 500ms
  AND the recording overlay disappears within 500ms
  AND no text is placed on the clipboard
```
**Note**: This is the exact scenario from Bug 1 (feedback-2026-02-21).

#### test_esc_cancels_push_to_talk_recording
**Suite**: cancel_recording
**Layers**: CGEvent, AX value, AX structure
```
GIVEN the app is in .idle state
  AND recording mode is set to "push-to-talk"
  AND the push-to-talk modifier is Option
WHEN the user holds the Option key (modifier down)
  AND the pipeline enters .recording state
  AND presses ESC while still holding Option
THEN the pipeline state changes to .idle within 500ms
  AND the recording overlay disappears within 500ms
  AND releasing Option is a no-op (no transcription)
```

### P1: High

#### test_esc_noop_when_idle
**Suite**: cancel_recording
**Layers**: CGEvent, process metrics
```
GIVEN the app is in .idle state (not recording)
WHEN the user presses ESC
THEN nothing happens
  AND the app does not crash
  AND the pipeline remains in .idle state
  AND memory does not spike
```

#### test_esc_no_clipboard_write
**Suite**: cancel_recording
**Layers**: CGEvent, clipboard
```
GIVEN the clipboard contains "SENTINEL_VALUE"
  AND the user starts recording
WHEN ESC is pressed to cancel
THEN the clipboard still contains "SENTINEL_VALUE"
  AND no transcription text was written to clipboard
```

#### test_rapid_start_cancel_start
**Suite**: cancel_recording
**Layers**: CGEvent, AX value, process metrics
```
GIVEN the app is in .idle state
WHEN the user starts recording
  AND immediately presses ESC (within 200ms)
  AND immediately starts recording again
THEN the second recording starts cleanly
  AND no stale audio samples from the first recording contaminate the second
  AND the app does not crash
```

#### test_esc_during_transcribing_is_noop
**Suite**: cancel_recording
**Layers**: CGEvent, AX value
```
GIVEN the pipeline is in .transcribing state
WHEN ESC is pressed
THEN nothing happens (ESC only cancels .recording state)
  AND the pipeline continues transcribing normally
```

### P2: Medium

#### test_esc_with_modifiers_held
**Suite**: cancel_recording
**Layers**: CGEvent, AX value
```
GIVEN the app is recording
WHEN ESC is pressed with Cmd held
  OR ESC is pressed with Shift held
THEN ESC still cancels (default cancel key has no required modifiers)
```

#### test_esc_when_app_not_frontmost
**Suite**: cancel_recording
**Layers**: CGEvent, AX value
```
GIVEN the app is recording
  AND another app (e.g., Finder) is frontmost
WHEN ESC is pressed
THEN the global monitor catches the ESC
  AND recording is cancelled
  AND the other app is not affected
```

#### test_cancel_before_speaking
**Suite**: cancel_recording
**Layers**: CGEvent, AX value
```
GIVEN the app just entered .recording state
  AND no speech has been detected by VAD
WHEN ESC is pressed immediately
THEN the pipeline returns to .idle cleanly
  AND no "No audio captured" error is shown
```

### P3: Low

#### test_custom_cancel_key
**Suite**: cancel_recording
**Layers**: CGEvent, AX value
```
GIVEN the cancel hotkey is configured to F12 instead of ESC
WHEN the app is recording
  AND F12 is pressed
THEN recording is cancelled
  AND ESC no longer cancels recording
```

## State Transition Matrix

| Current State  | ESC Pressed       | Expected Result              | Side Effects to Verify                   |
|----------------|-------------------|------------------------------|------------------------------------------|
| .idle          | ESC               | No-op, stay in .idle         | No crash, no state change                |
| .recording     | ESC               | Cancel -> .idle              | Overlay gone, no transcript, no paste    |
| .transcribing  | ESC               | No-op, continue transcribing | Transcription completes normally         |
| .polishing     | ESC               | No-op, continue polishing    | LLM polish completes normally            |
| .complete      | ESC               | No-op                        | No effect                                |
| .error         | ESC               | No-op (or dismiss error?)    | Depends on error UX design               |

## Negative Test Checklist

- [x] ESC when not recording (no crash)
- [x] ESC when transcribing (no interference)
- [x] ESC with extra modifiers (still works)
- [x] Rapid cancel-restart sequence (clean state)
- [ ] ESC with accessibility permission revoked (graceful failure)
- [ ] ESC while microphone permission dialog is showing
