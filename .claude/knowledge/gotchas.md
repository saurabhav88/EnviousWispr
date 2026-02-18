# Gotchas & Non-Obvious Patterns

Critical project-specific traps. Read before writing any code.

## FluidAudio Naming Collision

Module exports a struct `FluidAudio` that shadows the module name. **Never qualify with `FluidAudio.X`** — use unqualified names (`AsrManager`, `VadManager`, etc.) and type inference. See skill `resolve-naming-collisions` for full examples.

## Swift 6 Concurrency

- Use `@preconcurrency import` for FluidAudio, WhisperKit, and AVFoundation
- C globals like `kAXTrustedCheckOptionPrompt` need string literal workaround: `"AXTrustedCheckOptionPrompt" as CFString`
- Extract Sendable values from NSEvent before `@MainActor` dispatch — NSEvent isn't Sendable

## Audio Format

**16kHz mono Float32 throughout.** No exceptions. Defined in `AppConstants.sampleRate` and `AppConstants.audioChannels`.

## VAD Chunk Size

4096 samples (256ms at 16kHz) for Silero VAD streaming. `VadStreamState` persists across chunks — must call `reset()` before a new session.

## API Keys

macOS Keychain via `KeychainManager` (service: `"com.enviouswispr.api-keys"`). **Never UserDefaults.** Never log keys.

## ASR Backend Lifecycle

Only one backend active at a time. Always unload before switching: `await activeBackend.unload()` → swap → `await newBackend.prepare()`.
