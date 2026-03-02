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

Secure file-based storage via `KeychainManager` at `~/.enviouswispr-keys/` (dir 0700, files 0600). **Never UserDefaults.** Never log keys. Both `retrieve()` and `store()` may throw `KeychainError`.

**Why not macOS Keychain:** The Data Protection Keychain (`kSecUseDataProtectionKeychain`) requires entitlements unavailable to non-sandboxed, ad-hoc-signed SPM CLI builds (fails with `errSecMissingEntitlement` / -34018). The legacy Keychain's partition list / cdhash-based ACLs cause password prompts on every rebuild. File-based storage with strict POSIX permissions is standard practice for non-sandboxed macOS apps and avoids both issues.

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
- **Sparkle EdDSA key pair** — private key in macOS Keychain + `/tmp/sparkle_eddsa_private_key.txt`; public key in Info.plist.

## CI / GitHub Actions Release Gotchas

### Use `notarytool submit --wait` — NEVER Hand-Roll Polling (CRITICAL)

**`xcrun notarytool submit --wait --timeout 18000` is the correct approach.** Apple handles exponential backoff internally. Do NOT write manual polling loops — a previous Claude session hallucinated that `--wait` could "hang indefinitely" and implemented a manual polling loop instead. This was wrong. The manual polling loop caused the v1.0.0 release to fail repeatedly overnight. `--wait` with `--timeout` worked perfectly on the first try.

**Rule:** If you're tempted to replace `--wait` with manual polling, you are wrong. `--wait` is Apple's recommended approach and works reliably.

### GitHub Actions 6-Hour Job Ceiling

GitHub-hosted runners enforce a **6-hour maximum job runtime** regardless of `timeout-minutes`. Setting `timeout-minutes: 1500` (25h) does nothing — the job dies at 6h. Keep total job time well under 6h. Current release workflow completes in ~3.5 min.

### Tag-Triggered Workflows Run in Detached HEAD

When a workflow triggers on `push: tags: ['v*']`, the runner checks out the tag in **detached HEAD** state. `git checkout main` fails because no local `main` branch exists. Fix: `git fetch origin main && git checkout -B main origin/main`.

### appcast.xml Must Not Be Gitignored

The release workflow commits `appcast.xml` to main (Sparkle reads it from the raw GitHub URL). If `appcast.xml` is in `.gitignore`, `git add appcast.xml` fails silently. The file was removed from `.gitignore`; the workflow also uses `git add -f` as a safety net.

### Notarization Uses API Key Auth (Not Apple ID)

Apple ID + password auth is unreliable in headless CI (2FA hangs). Use App Store Connect API keys: `--key <.p8>`, `--key-id`, `--issuer`. Secrets: `APPLE_API_KEY_BASE64`, `APPLE_API_KEY_ID`, `APPLE_API_ISSUER_ID`.

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

## Task { @MainActor } vs DispatchQueue.main.async — Run-Loop Deferral

`Task { @MainActor in ... }` and `DispatchQueue.main.async { ... }` are NOT equivalent. `DispatchQueue.main.async` guarantees execution on the *next* run-loop cycle, while `Task { @MainActor }` may execute immediately if already on the main actor (no deferral guarantee).

This matters when creating NSHostingView during menu/overlay animations — the view must be created *after* the current animation pass completes. Using `Task { @MainActor }` caused re-entrant NSHostingView creation during menu animations → crash.

**Affected call sites:** `show()`, `showPolishing()`, `transitionToPolishing()` in the overlay layer.

**Rule:** When you need run-loop-cycle deferral (e.g., presenting views during animations), use `DispatchQueue.main.async`, not `Task { @MainActor }`.

## AVAudioEngine Device Disconnect

`AVAudioEngine` auto-stops when the audio device is disconnected (e.g., USB mic unplugged), but it does **not** clean up internal state. On `AVAudioEngineConfigurationChange` notification, first check `kAudioDevicePropertyDeviceIsAlive`. **Alive** = graceful recovery via `recoverFromCodecSwitch()` (reconfigure engine in-place, e.g., BT A2DP→SCO codec switch). **Dead** = full teardown via `emergencyTeardown()` (stop engine, remove all taps, `engine.reset()`, reconstruct from scratch). `onEngineInterrupted` callback propagates the event to `TranscriptionPipeline` to cancel in-progress work and transition to error state.

## Noise Suppression Requires Engine Rebuild

Toggling Apple Voice Processing I/O at runtime can break the AVAudioEngine — the format/graph state becomes inconsistent. Instead of toggling the flag on a live engine, use `buildEngine(noiseSuppression:)` to create a fresh `AVAudioEngine` with the desired configuration. This ensures the voice processing I/O unit is wired correctly from the start.

## PTT Pre-warm Fires Alongside Recording

`onPreWarmAudio` and `onStartRecording` both fire on key-down as parallel `Task`s. Pre-warm is fire-and-forget; `startRecording` checks `isPreWarmed` to skip the engine phase if the engine is already warm. This avoids double engine setup and ensures the BT codec switch (triggered by pre-warm) has settled before capture begins.

## TCC Permission Resets on Rebuild

The binary hash changes on every `swift build`, which invalidates the existing Accessibility TCC grant. macOS `tccutil` only supports `reset`, NOT `grant` — there is no command-line way to auto-grant Accessibility. Workarounds: (1) sign local builds with a stable Developer ID cert (TCC persists across rebuilds), or (2) re-grant manually in System Settings > Privacy & Security > Accessibility after each rebuild. See also "NEVER Use Blanket TCC Resets" above.

## installTap Before engine.start() Leaves Orphaned Tap on Failure

If `engine.start()` throws after a tap has been installed on the input node, the tap remains attached even though recording never started. A subsequent `startCapture()` call will then fail with "format mismatch" or "tap already installed". **Always remove the tap in the error path** before rethrowing. Pattern:

```swift
inputNode.installTap(...)
do {
    try engine.start()
} catch {
    inputNode.removeTap(onBus: 0)   // clean up orphaned tap
    throw error
}
```

## NSScreen.screens Can Be Empty

`NSScreen.screens` returns an empty array during display sleep/wake cycles, monitor disconnect/reconnect, or certain window server transitions. **Never force-index** with `NSScreen.screens[0]` — it will crash with an index-out-of-bounds trap. Always use `.first` with a `guard` or `??` fallback:

```swift
guard let screen = NSScreen.screens.first else { return }
```

## Streaming ASR Must End Exactly Once

`finalizeStreaming()` and `cancelStreaming()` must each be called **at most once** per session, and exactly one of them must be called on every exit path (success, error, timeout, cancellation). Multiple exit paths in a pipeline (VAD cancel, timeout, device disconnect, explicit stop) can each independently trigger cleanup and create double-finalize or double-cancel conditions, which crash or corrupt the streaming state machine. Use a `defer` block with a `Bool` flag (`streamingSetupSucceeded`) to guarantee cleanup on all paths, and guard against double sessions in the backend with an `isStreaming` flag.

## Per-Element .animation() Modifiers Create Exponential State Transitions

Applying `.animation(.easeOut(duration: 0.05), value: audioLevel)` to each of N child views (e.g., 18 bars in RainbowLipsIcon) creates N × (updates/sec) animation state transitions. Over a 2-minute recording at 12 updates/sec, that's ~43,200 transitions — overwhelming SwiftUI's view graph and causing heap corruption.

**Fix:** Use a single `.animation()` on the container view instead of per-element modifiers. One `.animation(.easeOut(duration: 0.08))` on the HStack/container achieves the same visual effect with 1/N the state transitions.

**Rule:** Never put `.animation(value:)` on individual elements inside a `ForEach` or repeated view. Always animate the container.
