# Swift Patterns — EnviousWispr

## FluidAudio Type Qualification

FluidAudio exports a struct `FluidAudio` that shadows the module name.

```swift
// WRONG — compiler error
let manager = FluidAudio.AsrManager()

// CORRECT — use unqualified names
let manager = AsrManager()
```

## Required @preconcurrency Imports

```swift
// WRONG — Swift 6 concurrency errors
import FluidAudio

// CORRECT
@preconcurrency import FluidAudio
@preconcurrency import WhisperKit
@preconcurrency import AVFoundation
```
