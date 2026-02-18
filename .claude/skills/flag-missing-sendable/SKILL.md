---
name: flag-missing-sendable
description: "Use when adding new model types, modifying types that cross actor boundaries, or investigating Sendable-related compiler warnings in VibeWhisper."
---

# Flag Missing Sendable Conformances

## Known Sendable Types (verify conformance is present)

Located in `Sources/VibeWhisper/Models/`:
- `ASRResult` — must conform to `Sendable`
- `Transcript` — must conform to `Sendable`
- `LLMResult` — must conform to `Sendable`
- `TranscriptSegment` — must conform to `Sendable`

These types cross the boundary between actor backends (`ParakeetBackend`, `WhisperKitBackend`) and `@MainActor` classes (`ASRManager`, `AppState`).

## Scan Locations

### 1. Model definitions
Grep `Sources/VibeWhisper/Models/` for `struct` and `class` without `Sendable`:
```
grep -n "struct\|class\|enum" Sources/VibeWhisper/Models/*.swift
```
Every type returned from an `async` protocol method must be `Sendable`.

### 2. ASRBackend and TranscriptPolisher protocols
- `Sources/VibeWhisper/ASR/ASRProtocol.swift` — return types of `transcribe(...)` must be `Sendable`
- `Sources/VibeWhisper/LLM/LLMProtocol.swift` — return types of `polish(...)` must be `Sendable`

### 3. AsyncStream element types
Any `AsyncStream<T>` where `T` crosses actor boundaries requires `T: Sendable`.
Check `AudioCaptureManager` for stream element types.

### 4. Closure captures passed to actors
Look for closures stored as properties on actor types — the closure type should be `@Sendable`.

### 5. Type-erased wrappers
`any ASRBackend` and `any TranscriptPolisher` — the existentials themselves are fine; confirm concrete types conform.

## Rules

- `struct` with all `Sendable` stored properties gains implicit `Sendable`; add explicit conformance anyway for clarity.
- `class` requires either `final` + all immutable/Sendable properties, or `@unchecked Sendable` with a documented justification comment.
- Never add `@unchecked Sendable` without a comment explaining why it is safe.
- Enums with associated values: each associated value must be `Sendable`.

## Verification

```bash
swift build 2>&1 | grep -i sendable
```
Zero warnings/errors expected after fixes.
