---
name: resolve-naming-collisions
description: "Use when writing or fixing code that imports FluidAudio, encounters 'FluidAudio.X' qualifier errors, or hits ambiguous type errors between FluidAudio-exported types and EnviousWispr's own types (e.g. ASRResult, ASRManager)."
---

# Resolve FluidAudio Naming Collisions

## The Problem

FluidAudio exports a struct named `FluidAudio` that shadows the module name. Using
`FluidAudio.AsrManager` or `FluidAudio.VadManager` causes a compiler error because
the compiler resolves `FluidAudio` as the struct, not the module.

## Rules

1. NEVER qualify FluidAudio types with the module name (`FluidAudio.X` is always wrong).
2. Use unqualified names: `AsrManager`, `AsrModels`, `VadManager`, `VadConfig`, `VadStreamState`, `VadSegmentationConfig`, `VadStreamResult`.
3. When our type (`ASRResult`) collides with a FluidAudio type, rely on protocol return type context to let the compiler pick ours. Use a distinct local variable name for the FluidAudio value.
4. Always use `@preconcurrency import FluidAudio` at the top of the file.

## Before / After

### Qualifying types (WRONG)
```swift
import FluidAudio

let manager = FluidAudio.AsrManager(config: .default)   // ERROR
let vad = FluidAudio.VadManager(config: VadConfig())    // ERROR
```

### Unqualified types (CORRECT)
```swift
@preconcurrency import FluidAudio

let manager = AsrManager(config: .default)
let vad = VadManager(config: VadConfig(defaultThreshold: 0.5))
```

### ASRResult collision (WRONG)
```swift
func transcribe(audioURL: URL) async throws -> ASRResult {
    let result: ASRResult = try await fluidAsrManager.transcribe(url: audioURL) // ambiguous
    return result
}
```

### ASRResult collision (CORRECT)
```swift
func transcribe(audioURL: URL) async throws -> ASRResult {
    // local name 'fluidResult' avoids collision; protocol return type resolves ours
    let fluidResult = try await fluidAsrManager.transcribe(url: audioURL)
    return ASRResult(text: fluidResult.text, language: "en", duration: fluidResult.duration)
}
```

## Checklist

- [ ] No `FluidAudio.` prefixes anywhere in the file
- [ ] `@preconcurrency import FluidAudio` present
- [ ] Local variable names for FluidAudio values are distinct (e.g. `fluidAsrManager`, `fluidResult`)
- [ ] Protocol return types drive compiler disambiguation of `ASRResult`
