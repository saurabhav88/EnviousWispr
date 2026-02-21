---
name: wispr-switch-asr-backends
description: "Use when implementing or modifying backend switching logic in ASRManager, handling the Settings UI backend picker, or debugging crashes and double-prepare bugs when the user changes ASR backend at runtime."
---

# Switch ASR Backends Safely

## Invariant

Never have two backends in a prepared state simultaneously. Switch sequence must be:
`unload current` → `reassign activeBackend` → `prepare new`.

## ASRManager.switchBackend(to:)

```swift
@MainActor @Observable final class ASRManager {
    private(set) var activeBackendType: ASRBackendType = .parakeet
    private var activeBackend: any ASRBackend = ParakeetBackend()

    func switchBackend(to newType: ASRBackendType) async throws {
        guard newType != activeBackendType else { return }  // idempotent

        // 1. Unload — must await before reassigning
        await activeBackend.unload()

        // 2. Reassign
        activeBackendType = newType
        activeBackend = makeBackend(for: newType)

        // 3. Prepare — must await; may throw (download failure, etc.)
        try await activeBackend.prepare()
    }

    private func makeBackend(for type: ASRBackendType) -> any ASRBackend {
        switch type {
        case .parakeet:  return ParakeetBackend()
        case .whisperKit: return WhisperKitBackend()
        }
    }
}
```

## UI Trigger (Settings)

The backend picker is in `SettingsView`. It calls into `AppState` which calls `ASRManager`:

```swift
// In AppState (@MainActor @Observable)
func setBackend(_ type: ASRBackendType) {
    Task {
        do {
            try await asrManager.switchBackend(to: type)
            UserDefaults.standard.set(type.rawValue, forKey: "asrBackend")
        } catch {
            // Surface error to UI — pipeline must remain in .idle state
            pipelineError = error
        }
    }
}
```

## Blocking Constraint

Never allow a transcription to start while a switch is in progress. `ASRManager` is `@MainActor`-isolated — concurrent calls to `switchBackend` and `transcribe` are serialised on the main actor automatically. No extra locking needed.

## UI Feedback via @Observable

`AppState` exposes `asrManager.activeBackendType` (or a mirrored property). SwiftUI reads it reactively. After the switch `await` completes, any view observing `activeBackendType` updates automatically.

```swift
// In SettingsView — picker binding
Picker("ASR Backend", selection: $appState.selectedBackendType) {
    Text("Parakeet v3 (English)").tag(ASRBackendType.parakeet)
    Text("WhisperKit (Multilingual)").tag(ASRBackendType.whisperKit)
}
.onChange(of: appState.selectedBackendType) { _, newValue in
    appState.setBackend(newValue)
}
```

## Error Recovery

If `prepare()` throws after `unload()`, the pipeline is backend-less. Set `isReady = false` on the new backend (it already is), surface the error to AppState, and let the user retry via Settings.

## Checklist

- [ ] `switchBackend` is idempotent (returns early if `newType == activeBackendType`)
- [ ] `unload()` is `await`-ed before the backend reference is replaced
- [ ] `prepare()` is `await`-ed and its throw is propagated to the caller
- [ ] Transcription is never called concurrently with `switchBackend` (MainActor serialisation handles this)
- [ ] Selected backend is persisted to `UserDefaults` after successful switch
