# Phase 4: XPC Audio Service — Implementation Plan

**Bead:** ew-8y3
**Status:** In Progress (Steps 0-2 done)
**Depends on:** Phase 3 (done)
**Blocks:** Phase 5: XPC ASR Service (ew-mvx)

## Executive Summary

Move AVAudioEngine, audio capture, device management, and codec switch recovery into a separate XPC service process. CoreAudio crashes (especially from Bluetooth device management) kill only the XPC service, not the main app. The main app survives, restarts the service, and notifies the pipeline.

## 1. XPC Service Architecture

### 1.1 The SPM + XPC Bundle Problem

macOS XPC services require a `.xpc` bundle inside the host app's `Contents/XPCServices/` directory. SPM has no native support for building XPC service bundles.

**Approach: SPM executable target + manual bundling.** Create a new SPM executable target `EnviousWisprAudioService`. `swift build` produces a bare binary. Build scripts assemble the `.xpc` bundle — same pattern as existing `.app` bundle assembly.

The `.xpc` bundle structure:
```
EnviousWispr.app/
  Contents/
    XPCServices/
      com.enviouswispr.audioservice.xpc/
        Contents/
          Info.plist
          MacOS/
            EnviousWisprAudioService
```

### 1.2 New SPM Target

```swift
.executableTarget(
    name: "EnviousWisprAudioService",
    dependencies: [
        "EnviousWisprCore",
        "EnviousWisprAudio",
        "FluidAudio",  // SilenceDetector's VadManager
    ],
    path: "Sources/EnviousWisprAudioService"
)
```

### 1.3 XPC Protocol Design

```swift
// In EnviousWisprCore (shared by both processes):

/// Commands from main app to audio service.
@objc public protocol AudioServiceProtocol {
    func buildEngine(noiseSuppression: Bool)
    func startEnginePhase(preferredDeviceUID: String, selectedDeviceUID: String, reply: @escaping (NSError?) -> Void)
    func waitForFormatStabilization(maxWait: Double, pollInterval: Double, reply: @escaping (Bool) -> Void)
    func beginCapture(reply: @escaping (NSError?) -> Void)
    func stopCapture(reply: @escaping (Data) -> Void)  // Float32 samples as raw Data
    func abortPreWarm()
    func rebuildEngine()
    func emergencyTeardown()
    func setNoiseSuppressionEnabled(_ enabled: Bool)
    func setPreferredInputDeviceUID(_ uid: String)
    func setSelectedInputDeviceUID(_ uid: String)
    func isCapturing(reply: @escaping (Bool) -> Void)
    func currentAudioLevel(reply: @escaping (Float) -> Void)
    func configureVAD(autoStop: Bool, silenceTimeout: Double, sensitivity: Float, energyGate: Bool)
    func getSamplesSnapshot(fromIndex: Int, reply: @escaping (Data, Int) -> Void)  // For WhisperKit incremental worker
}

// TRANSPORT TYPE RULE: All XPC protocol parameters use @objc-compatible types only.
// Audio samples cross as Data (raw Float32 bytes). The proxy converts Data↔[Float]
// at the boundary. Swift-side interfaces (AudioCaptureInterface) use [Float] normally.

/// Callbacks from audio service to main app.
@objc public protocol AudioServiceClientProtocol {
    func audioLevelUpdated(_ level: Float)
    func engineInterrupted()
    func partialSamplesAvailable(_ count: Int)
    func deviceError(_ message: String)
    func vadAutoStopTriggered()
    func audioBufferCaptured(_ data: Data, frameCount: Int)
    func inputDevicesChanged()
    func codecSwitchDetected(deviceAlive: Bool)
}
```

### 1.4 Audio Sample Transport

At 16kHz mono Float32, data rate is ~64KB/sec. XPC uses Mach messages internally with copy-on-write page mapping for payloads >4KB. At 4096 frames × 4 bytes = 16KB per buffer, overhead is <100 microseconds per message.

Audio level monitoring: piggybacked on buffer callbacks (4 updates/second).

`stopCapture()` returns accumulated Float32 samples as raw `Data` in the reply. The proxy converts `Data` back to `[Float]` via `withUnsafeBytes`. For 2-minute recording at 16kHz, ~7.7MB — well within XPC message limits. All XPC protocol methods use `@objc`-compatible types only (`Data`, `NSError`, `Bool`, `Float`, `Double`, `String`). No Swift-only types (`[Float]`, enums, structs) cross the XPC boundary.

For streaming ASR (Parakeet): `audioBufferCaptured` callback replaces the current `onBufferCaptured` closure. Main app reconstructs `AVAudioPCMBuffer` from Data and feeds to ASR backend.

## 2. AudioCaptureManager Split

### 2.1 What Moves to XPC Service

All AVAudioEngine and CoreAudio code:
- `engine: AVAudioEngine` and all engine lifecycle
- `converter: AVAudioConverter` and format conversion
- `bufferContinuation` / AsyncStream machinery
- `TapStoppedFlag` and the tap handler
- `configChangeObserver` and `handleEngineConfigurationChange()`
- `recoverFromCodecSwitch()` and `waitForFormatStabilization()`
- `emergencyTeardown()`
- `setInputDevice(_:)` and all device selection logic
- `buildEngine(noiseSuppression:)` and engine rebuild
- `preWarm()` and `abortPreWarm()`
- Buffer accumulation (`capturedSamples`, `maxRecordingSamples`)
- `AudioDeviceEnumerator`, `AudioDeviceMonitor`
- `SilenceDetector` (VAD runs in-process with audio for lowest latency)

### 2.2 What Stays in Main App (AudioCaptureProxy)

A thin proxy conforming to `AudioCaptureInterface`:
- `@Observable` properties: `isCapturing`, `audioLevel` (updated by XPC callbacks)
- Settings properties forwarded to XPC: `noiseSuppressionEnabled`, `selectedInputDeviceUID`, etc.
- Same callbacks as AudioCaptureManager: `onBufferCaptured`, `onEngineInterrupted`, etc.
- XPC connection management + crash recovery (see Architecture Invariants for lifecycle rules)

### 2.3 VAD Decision

**VAD runs in the XPC service.** The service already has the samples. It sends `vadAutoStopTriggered()` callback when silence-after-speech detected. Eliminates need to expose `capturedSamples` across process boundary.

### 2.4 Interface Protocol

```swift
@MainActor
public protocol AudioCaptureInterface: AnyObject {
    var isCapturing: Bool { get }
    var audioLevel: Float { get }
    var noiseSuppressionEnabled: Bool { get set }
    var selectedInputDeviceUID: String { get set }
    var preferredInputDeviceIDOverride: String { get set }
    var onBufferCaptured: (@Sendable (AVAudioPCMBuffer) -> Void)? { get set }
    var onEngineInterrupted: (() -> Void)? { get set }

    func buildEngine(noiseSuppression: Bool)
    func startEnginePhase() throws
    func waitForFormatStabilization(maxWait: TimeInterval, pollInterval: TimeInterval) async -> Bool
    func beginCapturePhase() throws -> AsyncStream<AVAudioPCMBuffer>
    func startCapture() throws -> AsyncStream<AVAudioPCMBuffer>
    func stopCapture() -> [Float]
    func preWarm() async
    func abortPreWarm()
    func rebuildEngine()
}
```

Both `AudioCaptureManager` and `AudioCaptureProxy` conform. Feature flag selects which one AppState creates.

### 2.5 WhisperKit Incremental Worker

The worker currently polls `capturedSamples` every ~3s. Solution: add `getSamplesSnapshot(fromIndex:reply:)` to XPC protocol. Worker requests only new samples since last poll (~192KB per request at 3s intervals).

## 3. Testing Strategy

Phase 4 introduces protocol seams, a process boundary, a transport layer, and crash recovery — all surfaces where "builds" doesn't mean "works." No XCTest (CLI-only project). Instead: standalone test executables and targeted harnesses.

```
Tests/
└── Phase4Harnesses/           # Standalone executables, not XCTest
    ├── SeamVerification.swift  # Step 0: fake AudioCaptureInterface consumer tests
    ├── TransportProving.swift  # Step 1.5: XPC echo/latency/death/reconnect
    ├── FlagSelection.swift     # Step 2: feature flag → correct impl
    ├── DataConversion.swift    # Step 3: Data↔[Float] round-trip, edge cases
    └── RecoveryState.swift     # Step 4: service death → clean state reset
```

Each harness is a standalone Swift file compiled as part of a test executable target. Runs assertions, prints PASS/FAIL, exits 0/1. No XCTest dependency.

## 4. Migration Strategy

### Step 0: AudioCaptureInterface Protocol (~1 session)

**Goal:** Create the seam. Fully eliminate hidden concrete `AudioCaptureManager` coupling.

- Add `AudioCaptureInterface` protocol to `EnviousWisprAudio`
- Make `AudioCaptureManager` conform
- Change both pipelines to type `audioCapture` as `any AudioCaptureInterface`
- Change `PipelineSettingsSync` to use the protocol
- Change `AppState` to declare `let audioCapture: any AudioCaptureInterface`
- **Audit:** grep for any remaining `AudioCaptureManager` type references in AppState, pipelines, and settings sync — all must go through the protocol
- AppState still creates `AudioCaptureManager()` — zero behavioral change

**Verification:**
- Build + relaunch + recording works unchanged
- **Seam harness:** Create a `MockAudioCapture` conforming to `AudioCaptureInterface` with stubs. Verify it can be injected into pipeline/AppState consumer code paths without compile errors or runtime crashes. This proves consumers work against the abstraction, not concrete `AudioCaptureManager` assumptions. Specifically test:
  - Proxy can be constructed and assigned to `any AudioCaptureInterface`
  - startCapture/stopCapture lifecycle round-trips through the protocol
  - No hidden downcasts to `AudioCaptureManager` anywhere in consumers

### Step 1: XPC Protocol + Service Skeleton + TCC Verification (~1 session)

**Goal:** Service exists, connects, and can use the microphone. TCC proven early.

- Add `AudioServiceProtocol` and `AudioServiceClientProtocol` to `EnviousWisprCore`
- Create `Sources/EnviousWisprAudioService/main.swift` with `NSXPCListener.service()` boilerplate
- Add executable target to `Package.swift`
- Create XPC service Info.plist (with `NSMicrophoneUsageDescription`)
- Update `bundle-app.md` to assemble + codesign `.xpc` bundle inside `Contents/XPCServices/`

**Verification:**
- `swift build` compiles both targets
- `.xpc` bundle assembles + codesigns correctly
- Host app launches with embedded `.xpc` bundle present
- **TCC gate (CRITICAL — do not defer):** Empirically test whether the embedded non-sandboxed XPC service inherits the host app's microphone TCC grant. Test on a clean TCC state. If it doesn't inherit, resolve now (separate entitlement, signing changes) before proceeding. This is a Phase 4 gate — if TCC can't be solved, the approach needs rethinking.

### Step 1.5: Transport Proving (~1 session)

**Goal:** Prove XPC connection lifecycle in isolation, before any AVAudioEngine code moves.

**Transport harness** (standalone executable — the most important test artifact in Phase 4):
- **Connect/disconnect:** Verify `NSXPCConnection(serviceName:)` connects to embedded service
- **Heartbeat:** Service sends periodic `audioLevelUpdated(Float)` callbacks (synthetic, no real audio)
- **Small payload echo:** Send and receive ~16KB Data (one audio buffer equivalent)
- **Medium payload echo:** Send and receive ~7.7MB Data (simulating 2-min `stopCapture()` reply). Measure round-trip latency — must be <100ms
- **Service death detection:** `kill -9` the service process, observe handler behavior.
- **Reconnect under load:** Kill service while callbacks are in-flight, verify no deadlock or crash in main app.
- Log all latency measurements. This is the empirical proof that XPC transport is viable.

**Step 1.5 Empirical Results (2026-03-15):**

| Test | Result | Measurement |
|------|--------|-------------|
| Small payload echo (16KB) | PASS | 12ms round-trip |
| Medium payload echo (7.7MB) | PASS | 0.78ms round-trip (Mach COW) |
| Heartbeat callbacks (svc→host) | PASS | 14 callbacks/1.5s at 10Hz |
| Service death (kill -9) | PASS | interruptionHandler in ~42ms |
| Reuse interrupted connection | PASS | Auto-relaunches service |
| Kill during active callbacks | PASS | Main app survives, reconnect works |

**XPC Connection Recovery Design Rules (empirically proven + council-validated):**

1. `kill -9` fires `interruptionHandler` ONLY — not `invalidationHandler`.
2. `interruptionHandler` = transient. Do NOT invalidate the connection. Keep the same `NSXPCConnection`. The next XPC call on it auto-relaunches the service via launchd.
3. `invalidationHandler` = terminal. Only fires if the host calls `invalidate()` or the service binary is missing. Nil the connection and recreate on next use.
4. Invalidating + creating a fresh connection after crash is WRONG — it tells launchd "I'm done" and gets bitten by the ~10s crash throttle.
5. After crash, all service-side state is lost. The proxy must re-send configuration (engine settings, noise suppression, device selection) on the first call after recovery.
6. In-flight XPC calls at crash time get error code 4097 (`NSXPCConnectionInterrupted`) via `remoteObjectProxyWithErrorHandler`. The proxy must handle these gracefully.
7. launchd applies ~10s crash throttle after abnormal termination. The queued message on the same connection waits through the throttle and delivers automatically.

### Step 2: AudioCaptureProxy + Feature Flag (~1 session)

**Goal:** Proxy exists, wired into app, feature-flagged off.

- Create `AudioCaptureProxy` conforming to `AudioCaptureInterface`
- Implement XPC connection management following the recovery design rules from Step 1.5:
  - `interruptionHandler`: mark `needsReinit = true`, do NOT invalidate, keep same connection
  - `invalidationHandler`: nil connection, recreate on next use
  - On next call after crash: re-send config (engine settings, noise suppression, device UID)
  - Use `remoteObjectProxyWithErrorHandler` for all calls (error 4097 on in-flight crash)
  - Fire `onEngineInterrupted` callback so pipelines transition to error state
- Add `useXPCAudioService: Bool` to SettingsManager (default `false`)
- AppState checks flag: creates `AudioCaptureManager` or `AudioCaptureProxy`
- Both conform to `AudioCaptureInterface`, so pipelines work either way

**Verification:**
- Build passes
- **Flag selection harness:** Verify flag off → `AudioCaptureManager` instantiated, flag on → `AudioCaptureProxy` instantiated. Both exercise the same `AudioCaptureInterface` call surface. AppState startup succeeds under both branches without regression.
- Flag off: app works identically to pre-Phase-4
- Flag on: proxy connects to service (no audio yet)

**Step 2 Results (2026-03-15):**
- `AudioCaptureProxy` in `EnviousWisprAudio` — full `AudioCaptureInterface` conformance with documented stubs
- `XPCServiceName` in `EnviousWisprCore` — derives dev/prod from host bundle ID at runtime
- `useXPCAudioService` cold flag in `SettingsManager` (no `onChange`, UserDefaults-only)
- `AppState.init()` reads flag from `UserDefaults.standard` and branches implementation
- `ensureConnection()` creates + resumes connection + sends ping (ping triggers launchd spawn)
- Verified: flag OFF = unchanged behavior; flag ON = proxy instantiated, XPC service spawns on first lifecycle call (buildEngine → ensureConnection → ping), no false capture state
- Note: startup does NOT universally verify/spawn the service in every settings configuration. Lazy spawn happens on first actual XPC message, not connection creation alone.

### Step 3: Service-Side Capture (~2 sessions)

**Goal:** Real audio capture runs in the XPC service.

- Move AudioCaptureManager core into service protocol implementation
- Engine lifecycle: `buildEngine`, `startEnginePhase`, `beginCapturePhase`, `stopCapture`
- Tap handler, format stabilization, buffer accumulation — all in service
- Buffer → Data → XPC → proxy reconstructs `AVAudioPCMBuffer` → pipeline
- Audio level computed in tap handler, sent with each buffer callback

**Verification:**
- **Data↔Float conversion harness:**
  - Raw Float32 samples encoded as Data and decoded back — values match exactly
  - Empty payload → empty array (not crash)
  - Sample count integrity: encode N floats, decode N floats
  - Repeated stopCapture conversions (10x cycle) — no drift or leak
  - Truncated/malformed Data → graceful error, not crash
- **stopCapture risk path — dedicated tests:**
  - Short recording (5s, ~320KB) — transfer + conversion
  - Medium recording (30s, ~1.9MB) — transfer + conversion
  - Max recording (2min, ~7.7MB) — transfer + conversion, latency measured
- **Repeated lifecycle:** 10x start/stop cycles — no resource leak, no stale state
- Toggle feature flag to test. In-process path must remain functional.

### Step 4: Device Management + Crash Recovery (~1 session)

**Goal:** Full BT crash isolation working. This is the whole point.

- Device enumeration runs in service, forwarded via `inputDevicesChanged()` callback
- `AudioDeviceList` in main app receives updates from service
- Codec switch recovery runs entirely in service
- Crash recovery follows Step 1.5 design rules: `interruptionHandler` → log crash, mark needsReinit, keep connection → `onEngineInterrupted` → pipeline error state. Next call re-sends config and auto-relaunches service.

**Verification:**
- **Recovery state harness:**
  - Recording interrupted by service death → pipeline transitions to known error/idle state (not stuck in recording)
  - Next recording after crash starts clean — no stale capture state, no partial prior recording reused
  - Proxy/service reconnection does not leave dangling callbacks or zombie tasks
  - Service crash during `stopCapture()` → pipeline shows error, not crash, samples are lost (acceptable)
- **Crash testing (manual):**
  - `kill -9` service during capture — main app survives
  - BT disconnect during capture — service recovers or crashes, main app survives either way
  - User can start new recording after crash recovery

### Step 5: Service-Side VAD (~1 session)

**Goal:** VAD monitoring runs entirely in the service process.

- **Only start this after Steps 3-4 are stable.** Basic capture transport and stopCapture must be proven first.
- Move SilenceDetector usage from both pipelines to service
- Service creates and manages SilenceDetector
- Service sends `vadAutoStopTriggered()` callback to proxy
- On `stopCapture()`, service returns both samples and speech segment data
- WhisperKit incremental worker: service provides `getSamplesSnapshot(fromIndex:reply:)` XPC method
- Pipeline VAD monitoring code replaced with proxy callback listener

**Verification:**
- VAD auto-stop fires correctly from service (integration test with real audio)
- WhisperKit incremental worker receives sample snapshots
- Manual smoke test: speak → pause → VAD stops recording automatically

### Step 6: BT Chaos Testing + Feature Flag Decision (~1 session)

**Goal:** Prove stability under real-world Bluetooth conditions before removing the flag.

- **Keep feature flag through this step.** Do not remove until BT chaos is proven.
- Test matrix (manual — BT/device churn is not trustworthy via pure unit tests):
  - BT headphones connected at app launch → record → stop
  - Connect BT headphones during recording
  - Disconnect BT headphones during recording
  - BT hot-swap (disconnect + reconnect within 5s)
  - AirPods connect/disconnect
  - Switch between BT mic and built-in mic mid-recording
- Each test: verify main app survives, pipeline shows appropriate state
- If any test crashes the main app: diagnose, fix, re-test before proceeding

### Step 7: Remove Feature Flag + Cleanup (~0.5 session)

**Goal:** XPC audio is the default and only path.

- Remove flag, always use `AudioCaptureProxy`
- Keep `AudioCaptureManager` for service target
- Update architecture docs

### Rollback Plan

Feature flag reverts to in-process audio at any step. `AudioCaptureInterface` protocol ensures both paths compile.

## 4. Risk Analysis

## Phase 4 Architecture Invariants (empirically established)

These are the proven truths from Steps 0–2. Future steps must not contradict them.

**Implementation model:**
- `AudioCaptureManager` = in-process implementation (existing, unchanged)
- `AudioCaptureProxy` = host-side XPC-backed stub (Step 2), becoming real transport in Step 3+
- Both conform to `AudioCaptureInterface` — consumers are agnostic
- App-level implementation selection happens in `AppState.init()` via cold feature flag
- XPC service owns real audio engine/capture complexity as migration continues

**XPC connection lifecycle (Step 1.5, empirically proven + council-validated):**
- Interruption != invalidation. They are different signals requiring different handling.
- `interruptionHandler` = transient. Do NOT invalidate. Keep the same `NSXPCConnection`. Next message auto-relaunches.
- `invalidationHandler` = terminal. Nil the connection, recreate on next use.
- Invalidating on interruption was the wrong recovery model — it breaks relaunch.
- Service-side state is lost after crash/relaunch. Host must re-send config on next real use.
- In-flight calls get error 4097 (`NSXPCConnectionInterrupted`) via `remoteObjectProxyWithErrorHandler`.
- launchd applies ~10s crash throttle after abnormal termination.

**Service spawn semantics:**
- `ensureConnection()` creates + resumes `NSXPCConnection` + sends ping (liveness check).
- The ping is the first XPC message — launchd spawns the service process in response.
- Creating/resuming the connection object alone does NOT spawn the service.
- Startup does not universally verify/spawn the service — lazy spawn on first lifecycle call.

**Step 2 stub semantics (must not roll forward as real behavior):**
- `capturedSamples` returns `[]` — not a valid recording result
- `stopCapture()` returns `[]` — not a valid recording result
- `onBufferCaptured` is stored but never called — no real buffers
- `isCapturing` is never set to `true` — no false capture state
- These stubs must be replaced with real XPC transport in Step 3

**Step 3 findings (2026-03-15):**
- Real audio capture through XPC service works end-to-end (record → transcribe)
- Callback collision: both pipelines share one `audioCapture` instance. `onEngineInterrupted` must NOT be set from pipeline `init()` — the last init overwrites the previous. Fixed: unified handler in AppState routes to the active pipeline via `handleEngineInterruption()` public method.
- `capturedSamples` returns `[]` on proxy (Step 5 will add `getSamplesSnapshot`)
- `onPartialSamples` not bridged — samples in service lost on crash (acceptable)

**Anti-patterns to avoid:**
- Do not create a new god object by mixing transport, app state, pipeline logic, and service logic in one place
- Do not smuggle startup responsibilities into random property setters to force service spawn
- Do not treat empty stub returns as valid capture outcomes in any downstream code path
- Do not set `audioCapture.onEngineInterrupted` from pipeline `init()` — use the unified AppState handler

**Packaging gotchas:**
- Full clean bundle required after XPC changes (quick rebundle leaves stale XPC binaries)
- XPC service name must match `CFBundleIdentifier` in the `.xpc` bundle's Info.plist exactly
- Inside-out codesigning: Sparkle → XPC services → main app. `xattr -cr` before signing.

---

## 4. Risk Analysis

| Risk | Level | Mitigation | Status |
|------|-------|------------|--------|
| TCC microphone permissions for XPC | MEDIUM | Embedded services typically inherit host grants | **PROVEN Step 1** — .authorized inherited |
| XPC connection lifecycle | MEDIUM-HIGH | `interruptionHandler` = keep connection, auto-relaunch | **PROVEN Step 1.5** — see design rules above |
| XPC latency for audio | LOW | Mach COW pages, ~100us per 16KB buffer | **PROVEN Step 1.5** — 0.78ms for 7.7MB |
| stopCapture() full-sample transfer | MEDIUM | Dedicated test coverage for 5s/30s/2min payloads | **Step 3** (7.7MB echo proven viable in 1.5) |
| SPM can't produce .xpc bundles | MEDIUM | Manual assembly in build scripts (same as .app bundle today) | **PROVEN Step 1** — works with inside-out signing |
| Crash during stopCapture() loses samples | MEDIUM | Acceptable — crash isolation is the point; pipeline shows error state | **Step 4** |
| WhisperKit incremental worker data access | MEDIUM | `getSamplesSnapshot()` XPC method, ~192KB per 3s poll | **Step 5** |
| BT chaos under XPC | HIGH | Feature flag kept through dedicated BT chaos testing | **Step 6** (gate for flag removal) |

## 5. Open Questions

1. ~~**TCC inheritance:** Does non-sandboxed embedded XPC service inherit host's microphone grant?~~ **YES** — .authorized inherited, no entitlement or separate grant needed (Step 1).
2. ~~**XPC Data throughput:** Can 7.7MB transfer in <100ms via XPC reply?~~ **YES** — 0.78ms for 7.7MB via Mach COW pages (Step 1.5).
3. **FluidAudio in XPC service:** Does Silero VAD model load correctly in service process? *(Step 5)*
4. ~~**Dev signing for .xpc:** Does existing dev cert correctly sign the embedded service?~~ **YES** — inside-out signing order: Sparkle → XPC → main app. xattr -cr before signing required (Step 1).
5. **AsyncStream from XPC:** Performance of reconstructing `AVAudioPCMBuffer` from received `Data`? *(Step 3)*

## 6. Definition of Done

### Functional
- [ ] Audio capture works identically to current behavior
- [ ] Both pipelines work with XPC audio service
- [ ] VAD auto-stop works from service
- [ ] WhisperKit incremental worker receives data from service
- [ ] Device enumeration/selection work across process boundary
- [ ] Noise suppression toggle works (engine rebuild in service)
- [ ] Audio level visualization works in overlay

### Crash Isolation (primary goal)
- [ ] Simulated CoreAudio crash does NOT crash main app
- [ ] Service auto-restarts after crash
- [ ] Pipeline transitions to error state on service crash
- [ ] User can start new recording after crash recovery

### Performance
- [ ] XPC buffer delivery latency < 1ms
- [ ] No perceptible change in recording start latency
- [ ] No perceptible change in pipeline total latency
- [ ] Audio level visualization remains smooth (4+ updates/sec)

### Architecture
- [ ] No lower-level module imports upward
- [ ] `AudioCaptureProxy` conforms to `AudioCaptureInterface`
- [ ] XPC service correctly assembled and codesigned
- [ ] Feature flag allows fallback during development
- [ ] `swift build` compiles both targets
