# UAT Scenarios: Cancel Hotkey During Recording

## Feature Summary

The cancel shortcut (Escape by default, configurable) ends an active recording.
**What it then does depends on the Escape Recovery setting (#2087), so every
scenario below states which state it assumes.**

- **Escape Recovery OFF (the default, and what every scenario below assumes
  unless it says otherwise):** the recording is discarded immediately — audio
  dropped, nothing transcribed, nothing pasted, nothing saved.
- **Escape Recovery ON:** the recording is KEPT. It finishes transcribing and
  polishing, the text is held for 24 hours in History, and a pill offers to
  paste it. Nothing is pasted unless the user asks.

**The Cancel BUTTON in the main window discards immediately in BOTH states.**
Only the shortcut recovers. A scenario that presses the button is testing the
destructive path whatever the setting says.

**This file was rewritten rather than replaced when Escape Recovery shipped.**
The off-path scenarios below are the regression suite for the promise that
carries almost every user: with the setting off, cancel behaves exactly as it
did before the feature existed.

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


---

## Escape Recovery ON (#2087)

Every scenario in this section requires **Settings → Shortcuts → Escape
Recovery** switched ON. Turn it back OFF afterwards: it is off by default and a
left-on toggle silently changes the meaning of every scenario above.

### P0: Critical

#### test_shortcut_keeps_recording_when_escape_recovery_on
**Suite**: escape_recovery
**Layers**: CGEvent, AX value, AX structure, clipboard
```
GIVEN the app is in .idle state
  AND Escape Recovery is ON
  AND recording mode is set to "toggle"
WHEN the user presses the recording hotkey
  AND dictates a sentence
  AND presses the cancel shortcut
THEN the recording is NOT discarded
  AND transcription and polish run to completion
  AND NOTHING is pasted into the active app
  AND the clipboard is unchanged
  AND a pill appears offering to paste the kept text
  AND the text appears in History with a Kept badge and a countdown
```
**Why the clipboard assertion matters**: delivery reports `.suppressed`, which
must never be confused with the clipboard-only fallback. A clipboard write here
would mean the user was told to press paste for text that was never put there.

#### test_cancel_button_still_discards_when_escape_recovery_on
**Suite**: escape_recovery
**Layers**: CGEvent, AX value, AX structure
```
GIVEN the app is in .idle state
  AND Escape Recovery is ON
WHEN the user starts a recording
  AND dictates a sentence
  AND clicks the Cancel BUTTON in the main window
THEN the recording is discarded immediately
  AND no transcript is saved to history
  AND no pill appears
```
**Why**: a click on a button labelled Cancel is unambiguous intent to destroy. A
press of a key people also use to dismiss popovers is not. This distinction is
the feature's core safety property.

#### test_second_shortcut_press_abandons_the_output
**Suite**: escape_recovery
**Layers**: CGEvent, AX structure
```
GIVEN a recovery is transcribing (the scenario above, mid-flight)
WHEN the user presses the cancel shortcut a SECOND time
THEN the kept text is abandoned — no pill, no History row
  AND the app stays busy until the transcription actually returns
  AND a new recording cannot start until it does
```
**Why the wait cannot be shortened**: cancelling the decode does not stop it, and
starting a second recording on top of a running one is the hazard the toggle
never disclosed. Abandonment discards the OUTPUT, never the WAIT.

### P1: High

#### test_kept_text_pastes_from_the_pill
**Suite**: escape_recovery
**Layers**: CGEvent, AX value, clipboard
```
GIVEN a pill is offering kept text
WHEN the user presses Paste on the pill
THEN the text lands in the app the dictation was originally aimed at
  AND the History row stops showing a countdown
```

#### test_kept_text_survives_relaunch
**Suite**: escape_recovery
**Layers**: AX structure
```
GIVEN kept text is in History with a countdown
WHEN the app is quit and relaunched
THEN the row is still there with a countdown
  AND Keep makes it permanent
```
**Why**: the 24-hour window starts when the user pressed cancel, not when the
app last started. A row whose countdown restarts on relaunch is a bug.

#### test_off_by_default_for_a_fresh_install
**Suite**: escape_recovery
**Layers**: AX structure
```
GIVEN a fresh install with no prior settings
WHEN the user opens Settings and finds Shortcuts
THEN Escape Recovery is OFF
  AND the cancel hotkey description says the recording is discarded
```
**Why**: opt-in is a founder decision, not a default worth drifting. The
description assertion catches the case where the toggle ships off but the copy
already describes the on behaviour.
