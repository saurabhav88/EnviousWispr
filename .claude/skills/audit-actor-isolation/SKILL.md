---
name: audit-actor-isolation
description: "Use when reviewing Swift concurrency correctness, adding new actors or @MainActor types, or investigating data race warnings in VibeWhisper."
---

# Audit Actor Isolation

## Files to Check

### Actor types (verify isolation boundaries)
- `Sources/VibeWhisper/ASR/ParakeetBackend.swift` — actor; all methods must be `async`; no stored mutable state accessible without `await`
- `Sources/VibeWhisper/ASR/WhisperKitBackend.swift` — actor; same rules
- `Sources/VibeWhisper/Audio/SilenceDetector.swift` — actor; check `VadManager` usage is fully awaited

### @MainActor classes (verify UI-connected annotations)
- `Sources/VibeWhisper/App/AppState.swift` — must be `@MainActor`; all `@Observable` mutations on main
- `Sources/VibeWhisper/Audio/AudioCaptureManager.swift` — `@MainActor`; audio tap callbacks are NOT on main (see unsafe-dispatch skill)
- `Sources/VibeWhisper/ASR/ASRManager.swift` — `@MainActor`; verify backend calls are awaited
- `Sources/VibeWhisper/Services/HotkeyService.swift` — `@MainActor`; NSEvent extractions must happen before `Task { @MainActor in }`
- `Sources/VibeWhisper/Pipeline/TranscriptionPipeline.swift` — `@MainActor`; state mutations synchronous, backend calls awaited
- `Sources/VibeWhisper/Services/PermissionsService.swift` — `@MainActor`
- `Sources/VibeWhisper/Utilities/BenchmarkSuite.swift` — `@MainActor`

## What to Look For

1. **Missing `await`** — any call to an actor method or `@MainActor` method from a different context that lacks `await`.
2. **Synchronous cross-actor access** — reading an actor's property without `await` outside its isolation domain.
3. **Escaping non-Sendable values** — closures or values passed across actor boundaries; cross-reference with flag-missing-sendable skill.
4. **`nonisolated` misuse** — `nonisolated` on a method that mutates actor state is a bug; `nonisolated static let` for constants is fine.
5. **Force-unwrapped pipeline** — `TranscriptionPipeline` is intentionally force-unwrapped at app launch; do not flag as a bug.

## Verification Steps

1. Run `swift build 2>&1 | grep -E "actor|isolation|Sendable|MainActor"` to surface compiler diagnostics.
2. Grep for `DispatchQueue` usage: any non-main queue touching `@MainActor` state is suspect.
3. Grep for `Task {` blocks — confirm they are `Task { @MainActor [weak self] in }` when capturing UI state.
4. Confirm all `async` protocol requirements on `ASRBackend` are fulfilled with `async` implementations.
