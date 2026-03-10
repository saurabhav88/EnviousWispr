# Wispr Flow Hands-Free Mode — Reverse Engineering Report

**Date:** 2026-03-10
**Source:** Static analysis of Wispr Flow v1.4.484 (`app.asar` bundle)
**Method:** Offline extraction and code analysis — no app launched, no telemetry triggered

---

## Overview

Wispr Flow's default mode is push-to-talk (PTT). A **double-press** of the record key within 500ms switches to "hands-free" (persistent/locked) recording. They internally call this **"POPO"** mode and track it with an `isLocked` boolean on their dictation state object.

---

## Core Constants

```
DICTATION_DEBOUNCE_DELAY = 500ms   // Double-press detection window
```

This single constant serves triple duty:
1. Double-press detection window (second press within 500ms → lock)
2. Minimum PTT threshold (release within 500ms → delay stop, wait for possible double-press)
3. Triple-press detection (third press within 500ms while locked → cancel)

---

## State Machine

### Dictation State Object (`p.ZZ`)

```
status: Idle | Listening | Processing | Retrying | Testing | Initializing | Dismissed | Error
isLocked: boolean        // true = hands-free/persistent recording
isCommandMode: boolean   // true = Wispr Lens (AI assistant) mode
startTime: number        // Date.now() when recording started
transcriptCommand: "ptt" | "popo" | "command" | "lens"
```

### Processing States (spam guard)

```
processingStates = [Initializing, Processing, Retrying]
```

The `ne()` function returns `true` when status is in any of these — blocks ALL new recording attempts.

---

## Action Down (Key Press) — Function `ie()`

```
1. GUARD: mic testing mode → reject
2. GUARD: status in processingStates → reject
   - If lastActionTime > 500ms ago → show "still processing" notification
   - If lastActionTime < 500ms ago → silently ignore (don't spam notifications)
3. GUARD: onboarding not complete → reject

4. Clear isCommandMode

5. IF status !== Listening:
   → isLocked = false
   → startDictation()           // Normal PTT start
   → startSuggestPOPOTimer()    // After 60s, nudge user about hands-free

6. ELSE IF (now - startTime < 500ms) AND !wasCommandMode:
   a. IF isLocked:
      → "Action dismiss on quick triple action press"
      → dismiss/cancel everything (DebounceTriplePress)
   b. ELSE:
      → "Action down twice in quick succession --> lock"
      → isLocked = true
      → show POPO UI indicator
      → clear suggestPOPO timer

7. ELSE IF isLocked:
   → stopDictation()            // Single press while locked = stop
```

### Key insight — Step 6a (Triple Press)

If you accidentally lock, pressing a third time within 500ms of the *original* start cancels everything. This is the escape valve.

### Key insight — Step 5 (POPO Nudge)

After 60 seconds of normal PTT recording, they show a "Switch to hands-free mode" notification:
```
title: "Switch to hands-free mode"
body: "Press space for hands-free mode or Fn+space to start a new hands-free recording"
```
This teaches the feature organically.

---

## Action Up (Key Release) — Function `oe()`

```
1. IF status !== Listening OR isLocked:
   a. IF status !== Listening → warn "Action up but not listening"
   b. IF isLocked → info "Action up but dictation is locked"
   → RETURN (ignore release entirely)

2. IF (now - startTime < 500ms):
   → pe()   // Start debounce timer — DON'T stop yet

3. ELSE:
   → clearTimeout(suggestPOPOTimer)
   → stopDictation()            // Normal PTT stop
```

### Debounce Timer — Function `pe()`

```
clearTimeout(existingDebounceTimer)   // Cancel any prior debounce
debounceTimer = setTimeout(() => {
    if (status === Listening AND !isLocked):
        "PTT stopping after timeout waiting for double press"
        dismiss(DebouncePTT)
}, 500ms)
```

This is the critical timing mechanism. When the user releases quickly:
- The timer starts a 500ms countdown
- If the user presses again within 500ms → Action Down fires, detects `startTime < 500ms`, locks
- If the user doesn't press again → timer fires, stops recording as normal PTT

---

## Stop Dictation — Function `fe()`

```
lastActionTime = Date.now()
if (status === Listening):
    stopListening()
    isLocked = false              // Always clear lock on stop
    clearTimeout(durationWarning)
    clearTimeout(durationTimeout)
    clearTimeout(processingDelay)
else:
    warn "stopDictation called when not listening"
```

---

## Anti-Spam Layers (5 Total)

### Layer 1: Processing State Gate
```
ne() = processingStates.includes(status)
→ Blocks ALL new recording while transcribing/processing/retrying
```

### Layer 2: lastActionTime Throttle
```
if (Date.now() - lastActionTime > DEBOUNCE_DELAY):
    show notification
else:
    silently ignore
→ Prevents notification spam during rapid key pressing
```

### Layer 3: Shortcut Collision Detection
```
if (status === Listening AND !isLocked AND timeSinceStart < 1000ms):
    if (other modifier keys detected):
        "Dismissing PTT because user is trying to get to other shortcut"
        cancel recording (OtherShortcut)
→ Auto-cancels if user was reaching for Cmd+C etc.
```

### Layer 4: Triple-Press Escape Valve
```
if (double-pressed to lock, then pressed again within 500ms of startTime):
    cancel everything (DebounceTriplePress)
→ Safety hatch for accidental locks
```

### Layer 5: Release Suppression When Locked
```
Action Up when isLocked → completely ignored
→ Recording only stops via explicit next single-press or cancel
```

---

## POPO-Specific Start (Separate Entry Point)

There's also a separate entry point for POPO that doesn't go through the double-press path — likely for the Fn+Space shortcut or deeplink:

```
if (status === Listening AND (isLocked OR source === StatusIndicator)):
    if (isLocked AND timeSinceStart < 500ms):
        "POPO dismiss on quick double press"
        dismiss(DebouncePOPO)
    else:
        stopDictation()

if (status !== Listening):
    startDictation()

isCommandMode = false
isLocked = true
show POPO indicator
```

---

## Deeplink API

They also support hands-free via URL scheme:
```
wispr-flow://start-hands-free  → Start hands-free if idle/dismissed
wispr-flow://stop-hands-free   → Stop if listening AND isLocked
```

---

## UI Indicators

When `isLocked = true`:
- Status window receives `LF.POPO` message (distinct visual from PTT)
- `transcriptCommand` set to `"popo"` for analytics
- Suggest-POPO timer is cleared (user already knows the feature)

---

## Timing Summary

| Event | Timing | Effect |
|-------|--------|--------|
| Quick release (< 500ms hold) | Starts 500ms debounce timer | Waits for possible double-press |
| Second press within 500ms | Detected by `startTime` comparison | Locks into hands-free |
| Third press within 500ms | Detected by `isLocked + startTime` | Triple-press cancel |
| Release while locked | Immediately | Ignored (no-op) |
| Press while locked (after 500ms) | Immediately | Stops recording |
| Press during processing | Immediately | Blocked by `ne()` guard |
| Shortcut collision (< 1000ms) | Detected by other keys held | Auto-cancel recording |
| Long PTT (> 60s) | Timer fires | Suggest hands-free nudge |

---

## Implications for EnviousWispr

1. **Single constant (500ms)** simplifies the design — no need for separate thresholds
2. **Triple-press escape** is essential UX — prevents frustration from accidental locks
3. **Release suppression** is the key architectural change — HotkeyService must distinguish "release while locked" from "release as PTT stop"
4. **Processing gate** prevents state corruption from key spam during transcription
5. **Shortcut collision** is a nice-to-have but not critical for v1
6. **POPO nudge at 60s** is clever organic feature discovery — consider for later
7. **The debounce timer on quick release** is the most subtle piece — without it, quick PTT taps would stop immediately and never give the double-press window a chance
