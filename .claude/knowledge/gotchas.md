# Gotchas & Non-Obvious Patterns

Critical project-specific traps. Read before writing any code.

## FluidAudio Naming Collision

Module exports a struct `FluidAudio` that shadows the module name. **Never qualify with `FluidAudio.X`** — use unqualified names (`AsrManager`, `VadManager`, etc.) and type inference. See skill `resolve-naming-collisions` for full examples.

## Swift 6 Concurrency

- Use `@preconcurrency import` for FluidAudio, WhisperKit, and AVFoundation
- Extract Sendable values from NSEvent before `@MainActor` dispatch — NSEvent isn't Sendable
- Use `nonisolated(unsafe)` when crossing actor boundaries with non-Sendable types that are immediately consumed (e.g., AVAudioPCMBuffer). Comment why it's safe.
- Hotkeys use Carbon `RegisterEventHotKey` (no Accessibility needed). Paste uses `CGEvent.post` which **requires Accessibility permission** on modern macOS — both `.cghidEventTap` and `.cgSessionEventTap` require it for posting events.

## Carbon Hotkey Timing (CRITICAL)

**Carbon `RegisterEventHotKey` must be called AFTER `NSApplication.run()` starts.** Registration during `AppState.init()` or before `applicationDidFinishLaunching` returns `noErr` (success) but events are silently never delivered. Always register hotkeys from `applicationDidFinishLaunching` or later. See `AppState.startHotkeyServiceIfEnabled()`.

## CGEvent Paste Requires Accessibility

**`CGEvent.post()` requires Accessibility permission on modern macOS (14+) regardless of tap level.** Both `.cghidEventTap` and `.cgSessionEventTap` need the app to be trusted via `AXIsProcessTrusted()`. Use `.cghidEventTap` + `.combinedSessionState` (matching enigo/Handy's proven approach). Without Accessibility, events post silently but are never delivered to the target app. Accessibility can be revoked at runtime. App now monitors with 5s polling and re-arms warning UI on revocation.

## Audio Format

**16kHz mono Float32 throughout.** No exceptions. Defined in `AppConstants.sampleRate` and `AppConstants.audioChannels`.

## VAD Chunk Size

4096 samples (256ms at 16kHz) for Silero VAD streaming. `VadStreamState` persists across chunks — must call `reset()` before a new session.

## API Keys

macOS Keychain via `KeychainManager` (service: `"com.enviouswispr.api-keys"`). **Never UserDefaults.** Never log keys. Both `retrieve()` and `store()` may throw `KeychainError`. Uses `#if DEBUG` pattern: file-based storage (`~/.enviouswispr-keys/`, 0600 perms) in debug builds, real macOS Keychain (`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`) in release builds.

## Ollama Local LLM

Requires Ollama server running locally (`ollama serve`). `OllamaSetupService` checks availability. If server is down, polish silently fails — check connectivity first.

## NEVER Use Blanket TCC Resets

**`tccutil reset Accessibility` wipes permissions for ALL apps on the system, not just EnviousWispr.** This breaks other apps that rely on Accessibility (window managers, automation tools, screen readers, etc.).

- **NEVER run** `tccutil reset Accessibility` or `tccutil reset Microphone` (no bundle-ID argument)
- **To reset only EnviousWispr**: `tccutil reset Accessibility com.enviouswispr.app`
- **Even better**: just re-grant manually in System Settings > Privacy > Accessibility after a rebuild
- After a rebuild, the binary hash changes so macOS invalidates the old TCC grant — this is expected behavior, not a bug to "fix" with a blanket reset

## UAT Runner Must Run in Background

`python3 Tests/UITests/uat_runner.py run` **must** be executed with `run_in_background: true` in the Bash tool. Foreground execution silently fails. Always use background mode and retrieve results via `TaskOutput`. Listing tests (`uat_runner.py list`) works fine in the foreground.

## ASR Backend Lifecycle

Only one backend active at a time. Always unload before switching: `await activeBackend.unload()` → swap → `await newBackend.prepare()`.

## Distribution

- **arm64 only** — FluidAudio uses Float16, unavailable on x86_64. Build with `--arch arm64`.
- **Sparkle needs `@preconcurrency import`** — not fully Sendable-annotated, same as FluidAudio/WhisperKit.
- **Sparkle.framework must be in bundle** — `build-dmg.sh` copies it; without it the app crashes on launch.
- **Codesigning without Xcode** — use `codesign` CLI directly with `--options runtime` and entitlements file.
- **Notarization requires app-specific password** — not the Apple ID password itself.
- **Sparkle EdDSA key pair** — private key in macOS Keychain + `/tmp/sparkle_eddsa_private_key.txt`; public key in Info.plist.

## Streaming ASR — Parakeet Only

ParakeetBackend supports streaming via FluidAudio's `StreamingAsrManager`. WhisperKit is batch-only (`supportsStreaming` defaults to `false`). Always call `cancelStreaming()` or `finalizeStreaming()` before `unload()` — incomplete cleanup leaves streaming state dangling.

## nonisolated(unsafe) for AVAudioPCMBuffer

`AVAudioPCMBuffer` is not Sendable. When crossing actor boundaries (e.g., audio callback to MainActor), use `nonisolated(unsafe) let safeBuffer = buffer`. Comment why it's safe. See TranscriptionPipeline and BenchmarkSuite for examples.

## Accessibility Auto-Refresh Monitoring

Accessibility permission can be revoked at runtime. App monitors with `startAccessibilityMonitoring()` (5s poll via `TimingConstants.accessibilityPollIntervalSec`). `resetAccessibilityWarningDismissal()` re-arms warning banner on revocation. Always call `refreshAccessibilityStatus()` on app activate.

## CFString Literal Workaround

`kAXTrustedCheckOptionPrompt` isn't exposed as a Swift symbol. Use `"AXTrustedCheckOptionPrompt" as CFString` string literal cast instead. See PermissionsService.swift line 45.

## Gemini SSE Streaming

When `onToken` callback is provided, GeminiConnector switches from `generateContent` to `streamGenerateContent?alt=sse`. Uses `LLMNetworkSession.shared.session` singleton. SSE lines parsed manually from `stream.lines` — each "data: " prefixed line contains JSON.

## Ollama Silent Failure

When Ollama server is down, polish operations may silently fail. Detection: check binary existence, then server reachability, then model availability. Server runs on `http://localhost:11434` with 3-second strict timeout.

## WhisperKitBackend Missing @preconcurrency

`WhisperKitBackend.swift` imports AVFoundation WITHOUT `@preconcurrency` prefix but should match all other import sites. Risk: Swift 6 concurrency strictness with non-Sendable AVFoundation types.
