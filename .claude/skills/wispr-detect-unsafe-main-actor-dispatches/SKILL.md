---
name: wispr-detect-unsafe-main-actor-dispatches
description: "Use when modifying NSEvent monitors, audio tap callbacks, or any code that dispatches from a background thread to @MainActor state in EnviousWispr."
---

# Detect Unsafe Main-Actor Dispatches

## High-Risk Call Sites

- `Sources/EnviousWispr/Services/HotkeyService.swift` — NSEvent global monitors
- `Sources/EnviousWispr/Audio/AudioCaptureManager.swift` — AVAudioEngine tap callback
- `Sources/EnviousWispr/Audio/SilenceDetector.swift` — VAD result handling

## Pattern: NSEvent Monitors

### UNSAFE (do not write)
```swift
NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { event in
    Task { @MainActor [weak self] in
        self?.handleKey(event)          // NSEvent is NOT Sendable
    }
}
```

### CORRECT
```swift
NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { event in
    let keyCode = event.keyCode         // extract Sendable value (UInt16)
    let modifiers = event.modifierFlags // extract Sendable value (NSEvent.ModifierFlags)
    Task { @MainActor [weak self] in
        self?.handleKey(keyCode: keyCode, modifiers: modifiers)
    }
}
```
Extract all needed values from `NSEvent` before entering the `Task` closure. `NSEvent` is not `Sendable`.

## Pattern: Audio Tap Callback

AVAudioEngine tap callbacks run on a real-time audio thread. Never access `@MainActor` state synchronously.

### UNSAFE
```swift
inputNode.installTap(...) { buffer, time in
    self.processBuffer(buffer)          // self is @MainActor — data race
}
```

### CORRECT
```swift
inputNode.installTap(...) { buffer, time in
    let data = Array(UnsafeBufferPointer(...))   // copy off audio thread
    Task { @MainActor [weak self] in
        self?.processBuffer(data)
    }
}
```

## Pattern: Actor to @MainActor

Actors calling `@MainActor` methods must use `await`, never `DispatchQueue.main.sync`.

### UNSAFE
```swift
DispatchQueue.main.sync { appState.transcription = result }
```

### CORRECT
```swift
await MainActor.run { appState.transcription = result }
// or simply call the @MainActor method with await
```

## Known Non-Bug

`DispatchQueue.main.asyncAfter` in `LLMSettingsView` for UI debounce is intentional — do not flag.

## Verification

```bash
grep -rn "addGlobalMonitor\|installTap\|DispatchQueue.main.sync" Sources/EnviousWispr/
```
Every hit must be checked against the correct patterns above.
