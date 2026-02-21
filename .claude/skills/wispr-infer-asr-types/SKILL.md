---
name: wispr-infer-asr-types
description: "Use when writing FluidAudio code that produces type ambiguity between FluidAudio's types and EnviousWispr's own parallel types (ASRManager vs AsrManager, ASRResult vs FluidAudio result), or when the compiler cannot infer the correct type from context."
---

# Infer ASR Types Correctly

## The Ambiguity Landscape

| FluidAudio name | Our name | Resolution |
|---|---|---|
| `AsrManager` | `ASRManager` (our class) | Use local alias or distinct variable name |
| `AsrModels` | N/A | No conflict; use unqualified |
| return type of `asrManager.transcribe()` | `ASRResult` (our struct) | Protocol return type drives resolution |
| `VadManager` | N/A | No conflict; use unqualified |

## Pattern 1 — Store FluidAudio manager under a distinct name

```swift
// In ParakeetBackend actor
private var fluidAsrManager: AsrManager?   // unqualified; distinct from our ASRManager class
private var fluidModels: AsrModels?        // unqualified; no collision
```

Never name it `asrManager` — that shadows the outer `ASRManager` orchestrator visible in the same file.

## Pattern 2 — Let protocol return type resolve ASRResult

Our `ASRBackend` protocol declares:
```swift
func transcribe(audioURL: URL) async throws -> ASRResult
```

Inside the conformance, don't annotate the local FluidAudio result:

```swift
// CORRECT — compiler infers FluidAudio result type; final return is our ASRResult
func transcribe(audioURL: URL) async throws -> ASRResult {
    guard let mgr = fluidAsrManager else { throw ASRError.notReady }
    let fluidResult = try await mgr.transcribe(url: audioURL)   // inferred FluidAudio type
    return ASRResult(                                           // our type from context
        text: fluidResult.text,
        language: "en",
        duration: fluidResult.duration
    )
}

// WRONG — explicit annotation creates ambiguity
let result: ASRResult = try await mgr.transcribe(url: audioURL)  // which ASRResult?
```

## Pattern 3 — Disambiguate with a type alias when truly needed

If a single file must reference both, add a private alias at the top:

```swift
@preconcurrency import FluidAudio
private typealias FluidASRResult = AsrModels.TranscriptionResult  // example; use real type name
```

## Pattern 4 — AsrModels generic parameter inference

```swift
// Type param inferred from assignment context
let fluidModels = try await AsrModels.downloadAndLoad(version: .v3)
// fluidModels is AsrModels — no annotation needed
```

## Checklist

- [ ] FluidAudio manager stored as `fluidAsrManager` (not `asrManager`)
- [ ] No explicit `: ASRResult` annotation on local FluidAudio result variables
- [ ] Protocol conformance return type supplies context for our `ASRResult`
- [ ] All FluidAudio type names are unqualified
