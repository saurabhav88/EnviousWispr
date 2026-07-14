@preconcurrency import AVFoundation
import CoreAudio
import EnviousWisprCore
import Foundation

#if DEBUG
  /// #1317 proof-bench (DEBUG only): the endpoint-facing fault status — the
  /// helper's `DebugFaultServiceStatus` fields plus the proxy's own live XPC
  /// generation. Built only by `AudioCaptureProxy.debugFaultStatus()`; a `nil`
  /// return there means fail-closed (`ERR`), never a defaulted instance of this.
  /// `package` access: read by `DebugFaultEndpoint` in the app target.
  package struct DebugFaultStatus: Sendable {
    package let armed: Bool
    package let hit: Bool
    package let trialID: String
    package let mode: String
    package let zeroedSampleCount: Int
    package let sourceIncarnation: UInt64
    package let xpcGeneration: UInt64
    package let captureSourceType: String
  }
#endif

/// XPC-backed implementation of `AudioCaptureInterface`.
///
/// Bridges the in-process `AudioCaptureInterface` contract to XPC calls against the
/// embedded `EnviousWisprAudioService`. Real audio capture runs in the service process;
/// the proxy handles connection lifecycle, buffer reconstruction, and state management.
///
/// **Connection lifecycle (#1194 single-funnel ownership):**
/// - The connection and its monotonically increasing generation live in a
///   `ConnectionSlot` whose private members make `install` / `retire` the only
///   mutation paths — compiler-enforced (private members + let-bound reference
///   type, so nothing outside the slot can touch the fields or swap the slot).
/// - Every fresh connection gets generation-stamped handlers and an
///   unconditional config replay (`replayConfig()`). There is no reinit flag —
///   no path can forget to set one.
/// - Every death signal (invalidation, interruption, watchdog wedge, per-call
///   transport error) funnels into `reportLineDeath(generation:cause:wasCapturing:)`.
///   Retirement is generation-guarded, so a stale event about a retired
///   predecessor is provably inert — including handler Tasks already queued
///   when the slot moved on.
/// - Pre-capture start ops (`start_engine` / `begin_capture` /
///   `start_engine_prewarm`) retry exactly once on a fresh connection via
///   `withStartRetry`, replaying the failed stage's service-side prefix
///   (`begin_capture` re-runs `start_engine` — a fresh connection reaches a
///   brand-new service world). `stopCapture` never retries (non-idempotent).
/// - The `engineInterrupted(cause:)` service relay is an ENGINE event with no
///   connection identity on the wire; it stays outside the funnel and keeps
///   the connection (see its doc).
@MainActor
@Observable
public final class AudioCaptureProxy: AudioCaptureInterface {

  // MARK: - Observable state

  public private(set) var isCapturing = false
  public private(set) var audioLevel: Float = 0.0

  /// Step 3: returns [] — samples accumulate in the service process.
  /// Step 5 will add getSamplesSnapshot XPC method for incremental access.
  public private(set) var capturedSamples: [Float] = []

  // MARK: - Callbacks

  public var onBufferCaptured: (@Sendable (AVAudioPCMBuffer) -> Void)?
  public var onEngineInterrupted: ((EngineInterruptionCause) -> Void)?
  public var onVADAutoStop: (() -> Void)?
  /// #1408 A3: the helper's hard sample-count backstop, relayed as a normal
  /// auto-stop event (`maxDurationReachedTriggered`), never an interruption.
  public var onMaxDurationReached: (() -> Void)?
  /// #1224: the bundled VAD model is unavailable. Bound by `AudioEventRouter`
  /// alongside `onVADAutoStop`, which decides eligibility (auto-stop setting)
  /// and shows the honest notice via `RecordingOverlayPanel`.
  public var onVADModelUnavailable: (() -> Void)?

  // MARK: - Round-4 telemetry callbacks (issue #285)

  public var onCaptureStalled: ((CaptureStallContext) -> Void)?
  public var onXPCServiceError: ((XPCErrorContext) -> Void)?
  public var onXPCReplyFailed: ((XPCReplyFailureContext) -> Void)?
  public var onRouteResolved: ((CaptureRouteDecision, _ sourceTypeChanged: Bool) -> Void)?

  /// #1194: fires once per resolved start-op retry (recovered or exhausted).
  /// Diagnostic-only — consumers must not branch control flow on it.
  public var onAudioStartRetryResolved: ((AudioStartRetryContext) -> Void)?

  /// Monotonic capture-session counter — returns `activeCaptureGeneration` so
  /// the id stays stable across the `stopCapture` bump (which flips
  /// `captureGeneration` early to reject stale XPC callbacks). The pipeline's
  /// dedup flag relies on this stability; using `captureGeneration` would
  /// produce two distinct sessions for a single stall-then-empty incident.
  public var currentCaptureSessionID: UInt64 { activeCaptureGeneration }

  /// Authoritative capture-active predicate.
  public var isActivelyCapturing: Bool { isCapturing }

  /// Concrete capture backend tag for Sentry attribution. Always "xpc_proxy"
  /// — actual sample capture happens service-side and is not visible here.
  public let captureSourceType: String = "xpc_proxy"

  // MARK: - Configuration (stored locally, forwarded to service)

  public var selectedInputDeviceUID: String = ""
  public var preferredInputDeviceIDOverride: String = ""

  /// Cached warm engine policy -- forwarded to service, replayed after crash.
  public var warmEnginePolicy: WarmEnginePolicy = .seconds30 {
    didSet {
      guard oldValue != warmEnginePolicy else { return }
      serviceProxy { [self] proxy in
        proxy.setWarmEnginePolicy(warmEnginePolicy.rawValue)
      }
    }
  }

  // MARK: - XPC connection state (#1194 single-funnel ownership)

  /// Sole owner of the XPC connection + its generation. Mutation is possible
  /// ONLY through `install` / `retire` — compiler-enforced: the members are
  /// `private` to the nested type (invisible to the outer class), and the
  /// proxy holds it as a `let`-bound reference type, so the slot can neither
  /// be reached around nor swapped wholesale. The TYPE is internal (not
  /// private) solely so unit tests can exercise install/retire semantics
  /// in isolation via `@testable import`.
  @MainActor
  final class ConnectionSlot {
    private(set) var generation: UInt64 = 0
    private var connection: NSXPCConnection?

    var current: (connection: NSXPCConnection, generation: UInt64)? {
      connection.map { ($0, generation) }
    }

    /// Retire generation `gen`. No-op (returns false) unless `gen` is current —
    /// this is the stale-event guard. Neutralizes handlers before invalidating
    /// as best-effort hygiene; correctness does NOT depend on it (an
    /// already-queued handler Task is stopped by ITS generation check).
    func retire(_ gen: UInt64) -> Bool {
      guard gen == generation, let conn = connection else { return false }
      conn.invalidationHandler = nil
      conn.interruptionHandler = nil
      conn.invalidate()
      connection = nil
      return true
    }

    /// Install a fresh connection, retiring any current one. Returns the new
    /// generation for handler stamping.
    func install(_ conn: NSXPCConnection) -> UInt64 {
      _ = retire(generation)
      generation &+= 1
      connection = conn
      return generation
    }
  }

  private let slot = ConnectionSlot()

  /// AsyncStream continuation for buffer delivery from service → pipeline.
  private var bufferContinuation: AsyncStream<AVAudioPCMBuffer>.Continuation?

  /// Generation counter to reject stale callbacks from previous capture sessions.
  /// Incremented on beginCapturePhase, stopCapture, and interruption.
  /// Checked in audioBufferCaptured (inside @MainActor Task) before yielding.
  private var captureGeneration: UInt64 = 0

  /// The generation that was active when the current capture session began.
  /// Set in beginCapturePhase, compared in audioBufferCaptured.
  private var activeCaptureGeneration: UInt64 = 0

  /// #1408 A3 (Codex code-diff r6): the begin `operationID` that owns the live
  /// session, nil outside one. The helper echoes it in
  /// `maxDurationReachedTriggered`; equality against this field is the
  /// session-identity check the generation counters cannot provide (both are
  /// CURRENT fields, equal during any active session). Set on successful
  /// begin; cleared wherever `isCapturing` goes false.
  private var activeCaptureOperationID: String?

  /// #455: uptime-ns at the moment `beginCapturePhase` flipped `isCapturing`
  /// to true. Read in the XPC interrupt/invalidate handlers to surface
  /// `recording_duration_ms` in the captureError breadcrumb. Reset to 0 on
  /// every clean stop / interrupt / invalidate so a stale value cannot bleed
  /// into the next session.
  private var captureStartUptimeNs: UInt64 = 0

  /// #1317 (cloud review P2, PR #1512, round 2): device resolved via
  /// `AudioDeviceEnumerator.resolveEffectiveInputDevice` and frozen inside
  /// `awaitStartEnginePhaseReply` — the same synchronous snapshot used for
  /// THIS attempt's XPC `preferredDeviceUID`/`selectedDeviceUID` send
  /// (including retries, since that whole function re-runs on resend).
  /// `evaluateDeadAirDetector` evaluates the alive/mute discriminator
  /// against THIS device, not a live re-read — a device switch applied
  /// mid-recording (settings apply immediately; the active capture source
  /// does not rebuild until the next recording) must not retroactively
  /// change which device this session's zero-signal check evaluates.
  /// `nil` if no session has started, or none could be resolved. Exposed
  /// via `AudioCaptureInterface.zeroSignalDiscriminatorDeviceID` so the
  /// pipeline layer's STOP-time backstop reads this SAME frozen value —
  /// which it does AFTER capture has already ended — a normal `stopCapture()`
  /// OR any interruption/line-death teardown path, both of which run their
  /// own cleanup BEFORE the kernel's read happens (the kernel falls through
  /// a salvageable interruption into the SAME normal stop tail that reads
  /// this). INVARIANT: no teardown path may clear this field — the next
  /// `startEnginePhase()` overwrites it for the next session, and nothing
  /// ever reads a stale cross-session value in between, so clearing it
  /// early only ever loses the CURRENT session's read (cloud review round
  /// 6 P1 caught this in `stopCapture()`; round 7 P2 caught the same class
  /// in both files' interruption paths — audit every write site against
  /// this invariant before adding a new one).
  private var effectiveDiscriminatorDeviceID: AudioDeviceID?

  public var zeroSignalDiscriminatorDeviceID: AudioDeviceID? { effectiveDiscriminatorDeviceID }

  /// #1317 (cloud review round 2, P2; scope narrowed round 3, P2): true
  /// once the CURRENT trailing all-zero run (not the whole session — see
  /// below) has been observed while the device discriminator was
  /// ineligible (muted, or mute-unknown). The device's mute state can
  /// change mid-recording — the discriminator legitimately re-checks it
  /// live on every buffer — but a STOP-time discriminator check that ONLY
  /// reads the CURRENT (possibly since-unmuted) state would mislabel a
  /// recording that was genuinely muted during its silent stretch as the
  /// harness glitch, just because the user unmuted right before releasing.
  /// This latch makes that earlier ineligible result stick for THAT run.
  /// Scoped to the current run, not session-wide: `evaluateDeadAirDetector`
  /// clears it the moment a non-zero sample breaks the trailing zero-run
  /// (`consecutiveExactZeroSuffix` resets), because an earlier resolved
  /// mute must not blind the backstop to a later, unrelated genuine
  /// zero-signal failure elsewhere in the same recording (round 3: a
  /// session-wide latch did exactly that). Reset in `beginCapturePhase`
  /// alongside `deadAirDetector` (same session-scope as the reactive
  /// detector itself); per the invariant on `effectiveDiscriminatorDeviceID`
  /// above, no teardown path may clear it early.
  private var sawIneligibleZeroSignalDuringSession = false

  public var zeroSignalDiscriminatorSawIneligible: Bool { sawIneligibleZeroSignalDuringSession }

  // MARK: - Capture-liveness watchdog (issue #285)

  /// Private serial queue that fires the stall `DispatchWorkItem`.
  private static let stallQueue = DispatchQueue(
    label: "com.enviouswispr.audio.capture-stall.proxy"
  )
  /// Pending stall watchdog. Cancelled on stop / interrupt / invalidate /
  /// on every new session's arm. Fires on MainActor via Task hop.
  private var stallWorkItem: DispatchWorkItem?
  /// Flips true on the MainActor inside `audioBufferCaptured` when any buffer
  /// for the active session reaches us. Reset to false when arming.
  private var hasReceivedBufferThisSession: Bool = false

  /// #1317: per-capture-generation all-zero harness-glitch detector state.
  /// Reset alongside `hasReceivedBufferThisSession` at every fresh
  /// `beginCapturePhase`.
  private var deadAirDetector = DeadAirStreamingDetector()

  /// #1317 (Codex code-diff review r3): `AudioCaptureInterface.onCaptureStalled`
  /// is documented as at-most-once per session, but the no-buffer watchdog
  /// (`captureStallWatchdogFired`) and the all-zero detector
  /// (`evaluateDeadAirDetector`) are two INDEPENDENT firing paths, each
  /// guarded only by its own state (`hasReceivedBufferThisSession` /
  /// `deadAirDetector.fired`). A delayed-buffer race — the watchdog fires on
  /// zero buffers, then late buffers arrive before the async stop completes
  /// and happen to cross the all-zero threshold — could fire BOTH,
  /// duplicating the callback and its telemetry. This flag is the ONE shared
  /// latch both paths check-and-set before calling `onCaptureStalled`.
  private var captureStallReported = false

  /// 16kHz mono Float32 format used for buffer reconstruction.
  /// Matches AudioCaptureManager.targetSampleRate / targetChannels.
  nonisolated(unsafe) private static let targetFormat = AVAudioFormat(
    commonFormat: .pcmFormatFloat32,
    sampleRate: 16000,
    channels: 1,
    interleaved: false
  )!

  /// Derived at startEnginePhase time from the same BT detection logic as CaptureRouteResolver.
  public private(set) var currentAudioRoute: String = "unknown"

  /// App-side route resolver run at every capture (re)start so the proxy's
  /// derived route carries the full reason, not just the coarse BT label
  /// (#1376). `.automatic` policy — the proxy never uses the debug overrides.
  private let routeResolver = CaptureRouteResolver()
  /// The last app-side route decision — backs the changed-only `onRouteResolved`
  /// fire and the derived `currentResolvedRoute`.
  private var lastRouteDecision: CaptureRouteDecision?
  /// The resolved-route transports observed for the current session (#1376).
  /// Telemetry-only observation — nothing branches capture on it.
  public private(set) var currentResolvedRoute: ResolvedRouteTransports?

  #if DEBUG
    /// V2 fault-injection seam (issue #291). When > 0, the next N captured
    /// buffers are silently dropped before reaching the continuation or
    /// `onBufferCaptured`. Decrements per drop until 0, then normal delivery
    /// resumes. Drives Lane A scenario A5 ("forced audio buffer stall") via
    /// the DEBUG localhost endpoint; can also be set directly from Lane C
    /// tests via `@testable import EnviousWisprAudio`.
    ///
    /// `package` access: callable from `DebugFaultEndpoint` in the app target
    /// (same SPM package). Inert in release builds — this property does not
    /// exist outside DEBUG.
    ///
    /// See `Tests/RuntimeUAT/SCENARIOS.md` for negative-control documentation.
    package var forceStallRemainingBuffers: Int = 0

    /// #1194 fault-injection seam: when > 0, the next N START operations
    /// (`start_engine` / `begin_capture` / `start_engine_prewarm`, including
    /// their retry/prefix stages) are treated as wedged by
    /// `withAudioXPCOperationSignal` before dispatch — no transport error, no
    /// invalidation: exactly the watchdog-only wedge shape. Decrements per
    /// forced wedge until 0. Never touches `stop_capture`.
    ///
    /// `package` access: driven end-to-end via `DebugFaultEndpoint`
    /// (`force_audio_wedge_start(N)`) → `Tests/RuntimeUAT/faultInjection.py`.
    /// Inert in release builds — this property does not exist outside DEBUG.
    package var forceWedgeNextStartOps: Int = 0
  #endif

  public init() {}

  // MARK: - Core lifecycle

  /// Run the full route resolver app-side and stash the derived route facts so
  /// `currentAudioRoute` + `currentResolvedRoute` reflect the last actual start
  /// (#1376). Called from every path that (re)starts capture. Replaces the
  /// former coarse inline Bluetooth-output check; the coarse label is preserved
  /// exactly via `CaptureRouteReason.coarseAudioRouteLabel`. Fires
  /// `onRouteResolved` per the interface's changed-only contract.
  private func deriveResolvedRoute() {
    let decision = routeResolver.resolve(
      preferredInputDeviceUID: preferredInputDeviceIDOverride
    )
    let prior = lastRouteDecision
    lastRouteDecision = decision
    currentAudioRoute = decision.reason.coarseAudioRouteLabel
    currentResolvedRoute = ResolvedRouteTransports.derive(
      decision: decision,
      preferredInputDeviceIDOverride: preferredInputDeviceIDOverride,
      selectedInputDeviceUID: selectedInputDeviceUID
    )
    guard CaptureRouteDecision.routeResolvedChanged(from: prior, to: decision) else { return }
    onRouteResolved?(decision, prior.map { $0.sourceType != decision.sourceType } ?? false)
  }

  #if DEBUG
    /// Test seam (#1533): drive the app-side telemetry route derivation without
    /// an XPC connection, so a test can prove the proxy still owns a working
    /// `CaptureRouteResolver` and the second (telemetry-only) consumer of the
    /// shared resolver cannot silently disappear.
    func deriveResolvedRouteForTest() { deriveResolvedRoute() }
  #endif

  public func startEnginePhase() async throws {
    try await withStartRetry(stage: "start_engine") { operationID in
      // Derive INSIDE the operation so it re-runs on the retry (a fresh
      // connection resends start_engine using current device/output state) —
      // a device/output change between attempts is otherwise lost (#1387).
      self.deriveResolvedRoute()
      try await self.awaitStartEnginePhaseReply(operationID: operationID)
    }
  }

  private func awaitStartEnginePhaseReply(operationID: String) async throws {
    // #1317 (cloud review P2, round 2): snapshot the UIDs used for THIS
    // specific attempt (including retries — this whole function re-runs on
    // each retry) and freeze the discriminator device against that SAME
    // snapshot, not a live re-read at some later point. This is the moment
    // closest to the actual XPC device bind.
    let preferredUID = preferredInputDeviceIDOverride
    let selectedUID = selectedInputDeviceUID
    effectiveDiscriminatorDeviceID = AudioDeviceEnumerator.resolveEffectiveInputDevice(
      preferredOverride: preferredUID, selected: selectedUID)
    try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, any Error>) in
      let guard_ = OneShotContinuation(cont)
      serviceProxy { proxy in
        proxy.startEnginePhase(
          operationID: operationID,
          preferredDeviceUID: preferredUID,
          selectedDeviceUID: selectedUID
        ) { nsError in
          if let error = nsError { guard_.resume(throwing: error) } else { guard_.resume() }
        }
      } onProxyError: {
        guard_.resume(throwing: XPCTransportError.serviceUnreachable)
      }
    }
  }

  public func beginCapturePhase(recoveryPayload: Data?) async throws
    -> AsyncStream<AVAudioPCMBuffer>
  {
    // Finish any stale continuation from a previous session.
    bufferContinuation?.finish()
    bufferContinuation = nil

    captureGeneration &+= 1
    activeCaptureGeneration = captureGeneration

    let stream = AsyncStream<AVAudioPCMBuffer> { continuation in
      self.bufferContinuation = continuation
    }

    // Retry prefix: a fresh connection reaches a brand-new service world with
    // no engine, so a `begin_capture` resend must re-run `start_engine` first
    // (device UIDs ride the message; config was replayed at acquisition).
    try await withStartRetry(
      stage: "begin_capture",
      prefix: {
        // A retry re-sends start_engine on a fresh line — re-derive so the
        // route reflects the actual (possibly changed) start (#1376).
        self.deriveResolvedRoute()
        try await self.withAudioXPCOperationSignal(stage: "start_engine_retry_prefix") {
          operationID in
          try await self.awaitStartEnginePhaseReply(operationID: operationID)
        }
      }
    ) { operationID in
      try await self.awaitBeginCaptureReply(
        operationID: operationID, recoveryPayload: recoveryPayload)
      // #1408 A3 (Codex code-diff r6): remember which begin op owns this
      // session — the max-duration relay echoes it, and a mismatch is a stale
      // event from an EARLIER session that must not stop this one. Set only on
      // the SUCCESSFUL attempt (a #1194 retry mints a fresh id; the helper
      // stored whichever begin actually ran).
      self.activeCaptureOperationID = operationID
    }

    isCapturing = true
    captureStartUptimeNs = DispatchTime.now().uptimeNanoseconds  // #455
    // #1317: `effectiveDiscriminatorDeviceID` is NOT (re-)frozen here — it is
    // already frozen by `awaitStartEnginePhaseReply` (round 2 fix), which ran
    // as part of the preceding `startEnginePhase()` (or this call's own
    // retry-prefix on a resend). Re-freezing here would re-read live UIDs at
    // a LATER point, reintroducing the exact race cloud review flagged.
    hasReceivedBufferThisSession = false
    deadAirDetector = DeadAirStreamingDetector()
    captureStallReported = false
    sawIneligibleZeroSignalDuringSession = false
    armCaptureStallWatchdog()
    return stream
  }

  private func awaitBeginCaptureReply(operationID: String, recoveryPayload: Data?) async throws {
    try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, any Error>) in
      let guard_ = OneShotContinuation(cont)
      serviceProxy { proxy in
        proxy.beginCapture(operationID: operationID, recoveryPayload: recoveryPayload) { nsError in
          if let error = nsError { guard_.resume(throwing: error) } else { guard_.resume() }
        }
      } onProxyError: {
        guard_.resume(throwing: XPCTransportError.serviceUnreachable)
      }
    }
  }

  /// Arm the one-shot stall watchdog for the current `activeCaptureGeneration`.
  private func armCaptureStallWatchdog() {
    stallWorkItem?.cancel()
    let armedSession = activeCaptureGeneration
    let armedAtNs = DispatchTime.now().uptimeNanoseconds
    let item = Self.makeStallWorkItem(
      armedSession: armedSession, armedAtNs: armedAtNs, proxy: self)
    stallWorkItem = item
    Self.stallQueue.asyncAfter(
      deadline: .now() + .milliseconds(TimingConstants.audioCaptureStallWindowMs),
      execute: item
    )
  }

  /// Build the watchdog closure in a nonisolated context so it does NOT inherit
  /// the enclosing `@MainActor` isolation. Swift 6 otherwise inserts executor
  /// checks that fire `dispatch_assert_queue_fail` when the work item runs on
  /// the stall queue. Same escape-hatch pattern as `makeInterruptionHandler`.
  nonisolated private static func makeStallWorkItem(
    armedSession: UInt64,
    armedAtNs: UInt64,
    proxy: AudioCaptureProxy
  ) -> DispatchWorkItem {
    return DispatchWorkItem { [weak proxy] in
      Task { @MainActor [weak proxy] in
        proxy?.captureStallWatchdogFired(
          armedSession: armedSession, armedAtNs: armedAtNs)
      }
    }
  }

  private func captureStallWatchdogFired(armedSession: UInt64, armedAtNs: UInt64) {
    guard activeCaptureGeneration == armedSession else { return }
    guard isCapturing else { return }
    guard !hasReceivedBufferThisSession else { return }
    guard !captureStallReported else { return }

    let ctx = CaptureStallContext(
      sessionID: armedSession,
      armedAtUptimeNs: armedAtNs,
      firedAtUptimeNs: DispatchTime.now().uptimeNanoseconds,
      route: currentAudioRoute,
      sourceType: "xpc_proxy",
      engineStartedSuccessfully: true,
      tapInstalled: true,
      formatMismatchObserved: false,
      inputDeviceUIDPreferred: preferredInputDeviceIDOverride.isEmpty
        ? nil : preferredInputDeviceIDOverride,
      inputDeviceUIDSystemDefault: AudioDeviceEnumerator.defaultInputDeviceUID(),
      failureMode: .noBuffers,
      selectedTransport: currentResolvedRoute?.selected,
      effectiveTransport: currentResolvedRoute?.effective,
      routeReason: currentResolvedRoute?.routeReason,
      routeFallbackReason: currentResolvedRoute?.routeFallbackReason,
      inputSelectionMode: currentResolvedRoute?.inputSelectionMode,
      outputTransport: currentResolvedRoute?.outputTransport,
      routeResolutionSource: currentResolvedRoute?.routeResolutionSource
    )
    captureStallReported = true
    onCaptureStalled?(ctx)
  }

  /// #1317: feed this buffer's raw samples into the per-generation all-zero
  /// harness-glitch detector; when it crosses a confidence threshold, run the
  /// §3.0 device-alive + not-muted discriminator and — only if it passes —
  /// fire `onCaptureStalled` with the matching failure mode. A muted or
  /// mute-unknown device fails closed: no fire, today's honest no-speech
  /// path is untouched, and the next buffer re-evaluates (mute state can
  /// legitimately change mid-recording).
  private func evaluateDeadAirDetector(buffer: AVAudioPCMBuffer, sessionID: UInt64) {
    guard !deadAirDetector.fired, !captureStallReported,
      let channelData = buffer.floatChannelData
    else { return }
    let frameCount = Int(buffer.frameLength)
    guard frameCount > 0 else { return }
    let suffixBefore = deadAirDetector.consecutiveExactZeroSuffix
    deadAirDetector.ingest(UnsafeBufferPointer(start: channelData[0], count: frameCount))
    // #1317 (cloud review round 3, P2): a non-zero sample anywhere in this
    // buffer breaks the trailing zero-run — `consecutiveExactZeroSuffix`
    // after ingest is then strictly less than `suffixBefore + frameCount`
    // (it only counts zeros AFTER the last non-zero sample). Any earlier
    // ineligible (muted) result applied to THAT run, not this new one, so it
    // must not suppress detection of a later, unrelated zero-signal failure
    // (an earlier accidental mute-then-unmute must not blind the backstop
    // to a genuine harness glitch later in the same recording).
    if deadAirDetector.consecutiveExactZeroSuffix != suffixBefore + frameCount {
      sawIneligibleZeroSignalDuringSession = false
    }

    let mode: CaptureStallFailureMode
    if deadAirDetector.isAllZeroFromStart {
      mode = .allZeroFromStart
    } else if deadAirDetector.isBecameZeroMidCapture {
      mode = .becameZeroMidCapture
    } else {
      return
    }

    // #1317 (cloud review P2, round 2): evaluate against the device FROZEN
    // inside `awaitStartEnginePhaseReply` at engine-start, not a live
    // re-read — `preferredInputDeviceIDOverride`/`selectedInputDeviceUID`
    // can already reflect a device the user switched to mid-recording,
    // before the active capture source itself rebuilds.
    guard
      let deviceID = effectiveDiscriminatorDeviceID,
      ZeroSignalDeviceDiscriminator.isEligible(deviceID: deviceID)
    else {
      // #1317 (cloud review round 2, P2): a zero-signal-candidate buffer was
      // observed while ineligible (muted) — latch it so the STOP-time
      // backstop can't later see a since-unmuted live state and misclassify
      // this genuinely-muted stretch as the harness glitch.
      sawIneligibleZeroSignalDuringSession = true
      return
    }

    deadAirDetector.fired = true
    captureStallReported = true
    let ctx = CaptureStallContext(
      sessionID: sessionID,
      armedAtUptimeNs: captureStartUptimeNs,
      firedAtUptimeNs: DispatchTime.now().uptimeNanoseconds,
      route: currentAudioRoute,
      sourceType: "xpc_proxy",
      engineStartedSuccessfully: true,
      tapInstalled: true,
      formatMismatchObserved: false,
      inputDeviceUIDPreferred: preferredInputDeviceIDOverride.isEmpty
        ? nil : preferredInputDeviceIDOverride,
      inputDeviceUIDSystemDefault: AudioDeviceEnumerator.defaultInputDeviceUID(),
      failureMode: mode,
      selectedTransport: currentResolvedRoute?.selected,
      effectiveTransport: currentResolvedRoute?.effective,
      routeReason: currentResolvedRoute?.routeReason,
      routeFallbackReason: currentResolvedRoute?.routeFallbackReason,
      inputSelectionMode: currentResolvedRoute?.inputSelectionMode,
      outputTransport: currentResolvedRoute?.outputTransport,
      routeResolutionSource: currentResolvedRoute?.routeResolutionSource
    )
    onCaptureStalled?(ctx)
  }

  // periphery:ignore - protocol conformance (AudioCaptureInterface)
  public func startCapture() async throws -> AsyncStream<AVAudioPCMBuffer> {
    guard !isCapturing else { return AsyncStream { $0.finish() } }
    try await startEnginePhase()
    return try await beginCapturePhase()
  }

  public func stopCapture() async -> CaptureResult {
    // Cancel any pending stall watchdog before the session id rolls.
    stallWorkItem?.cancel()
    stallWorkItem = nil
    // Snapshot the session id BEFORE the generation bump so reply-path
    // failures report the session the caller was actually stopping.
    let endingSession = activeCaptureGeneration
    // Bump generation so stale callbacks from this session don't leak into the next.
    captureGeneration &+= 1

    var result = CaptureResult(samples: [])
    do {
      // Cleanup must outlive forward-path task cancellation. `finishTerminal`
      // cancels that task while stop may already be in flight; returning early
      // would mark capture resources released before the service actually stops.
      result = try await withAudioXPCOperationSignal(
        stage: "stop_capture",
        parentCancellationBehavior: .waitForResolution
      ) { operationID in
        try await self.awaitStopCaptureReply(
          operationID: operationID,
          endingSession: endingSession
        )
      }
    } catch {
      if error is XPCOperationSignalWedgeError {
        reportXPCReplyFailure(stage: "stop_capture_signal_watchdog", sessionID: endingSession)
      }
      // XPC error — service crashed during stopCapture. Samples are lost.
      // The interruptionHandler fires independently and handles pipeline notification.
      // Do NOT call onEngineInterrupted here to avoid double-firing.
      Task {
        await AppLogger.shared.log(
          "[AudioCaptureProxy] stopCapture failed — service unreachable, samples lost: \(error)",
          level: .info, category: "XPC"
        )
      }
    }

    isCapturing = false
    activeCaptureOperationID = nil  // #1408 A3: session over, relay echoes are stale now
    captureStartUptimeNs = 0  // #455
    // #1317 (cloud review P1, round 6): do NOT clear `effectiveDiscriminatorDeviceID`
    // here — `RecordingSessionKernel` reads `zeroSignalDiscriminatorDeviceID`
    // via the STOP-time backstop AFTER this `stopCapture()` call returns.
    // Clearing it here made the backstop permanently see `nil` and silently
    // disabled it on every real capture. The next `startEnginePhase()`
    // already overwrites it for the next session.
    audioLevel = 0
    bufferContinuation?.finish()
    bufferContinuation = nil
    return result
  }

  private func awaitStopCaptureReply(
    operationID: String,
    endingSession: UInt64
  ) async throws -> CaptureResult {
    try await withCheckedThrowingContinuation {
      (cont: CheckedContinuation<CaptureResult, any Error>) in
      let guard_ = OneShotContinuation(cont)
      // capturingTeardownOnCallError: false — stopCapture owns its own state
      // teardown (below the await) and deliberately does NOT fire
      // onEngineInterrupted on a stop failure; a call-error here is
      // retire-only and onXPCReplyFailed is the sole caller-visible signal.
      serviceProxy(
        { proxy in
          proxy.stopCapture(operationID: operationID) { sampleData, vadData, metadataData in
            let samples = Self.dataToFloats(sampleData)
            let segments = Self.decodeVADSegments(vadData)
            // #1434: decode the helper's capture-health metadata back into the
            // SAME struct the in-process path attaches — decode failure
            // degrades to nil (diagnostic limb; never fails the stop).
            let metadata = Self.decodeCaptureStopMetadata(metadataData)
            guard_.resume(
              returning: CaptureResult(
                samples: samples, vadSegments: segments, metadata: metadata))
          }
        },
        onProxyError: { [weak self] in
          self?.reportXPCReplyFailure(stage: "stop_capture", sessionID: endingSession)
          guard_.resume(returning: CaptureResult(samples: []))
        },
        capturingTeardownOnCallError: false
      )
    }
  }

  public func rebuildEngine() {
    serviceProxy { proxy in proxy.rebuildEngine() }
  }

  public func preWarm() async throws {
    let proxyStart = ContinuousClock.now

    acquireConnection()
    let connMs = Self.ms(ContinuousClock.now - proxyStart)
    // Phase 1: start engine
    let enginePhaseStart = ContinuousClock.now
    do {
      try await withStartRetry(stage: "start_engine_prewarm") { operationID in
        // Derive INSIDE the operation (re-runs on the retry) so telemetry is
        // populated even when startEnginePhase() is skipped on the next
        // recording (warm reuse), and reflects each attempt's state (#1387).
        self.deriveResolvedRoute()
        try await self.awaitStartEnginePhaseReply(operationID: operationID)
      }
    } catch {
      Task {
        await AppLogger.shared.log(
          "[AudioCaptureProxy] preWarm failed: \(error)",
          level: .info, category: "XPC"
        )
      }
      // Issue #289: propagate so the pipeline / the former root state can abort the
      // recording cleanly instead of flipping isPreWarmed=true against a
      // dead capture path.
      throw error
    }
    let enginePhaseMs = Self.ms(ContinuousClock.now - enginePhaseStart)
    // Phase 2: wait for format stabilization
    let stabStart = ContinuousClock.now
    _ = await waitForFormatStabilization(maxWait: 1.5, pollInterval: 0.2)
    let stabMs = Self.ms(ContinuousClock.now - stabStart)
    let totalMs = Self.ms(ContinuousClock.now - proxyStart)
    Task {
      await AppLogger.shared.log(
        "COLD-START [XPC proxy] preWarm: total=\(totalMs)ms | conn=\(connMs)ms enginePhase=\(enginePhaseMs)ms formatStab=\(stabMs)ms",
        level: .info, category: "XPC"
      )
    }
  }

  /// Convert Duration to milliseconds for logging.
  private static func ms(_ d: Duration) -> Int {
    let (seconds, attoseconds) = d.components
    return Int(seconds) * 1000 + Int(attoseconds / 1_000_000_000_000_000)
  }

  public func abortPreWarm() {
    serviceProxy { proxy in proxy.abortPreWarm() }
  }

  public func waitForFormatStabilization(maxWait: TimeInterval, pollInterval: TimeInterval) async
    -> Bool
  {
    await withCheckedContinuation { cont in
      serviceProxy { proxy in
        proxy.waitForFormatStabilization(maxWait: maxWait, pollInterval: pollInterval) { result in
          cont.resume(returning: result)
        }
      } onProxyError: {
        cont.resume(returning: false)
      }
    }
  }

  private func withAudioXPCOperationSignal<T: Sendable>(
    stage: String,
    parentCancellationBehavior: WatcherParentCancellationBehavior = .returnCancellation,
    _ work: @MainActor @escaping (String) async throws -> T
  ) async throws -> T {
    // Record the generation this operation dispatches on, so a wedge retires
    // exactly the line it observed — never a fresh replacement (§3.3).
    let dispatchedGen = slot.current?.generation

    #if DEBUG
      // #1194 fault-injection: watchdog-only wedge shape for UAT scenario 5.
      if forceWedgeNextStartOps > 0, Self.isStartStage(stage) {
        forceWedgeNextStartOps -= 1
        let remaining = forceWedgeNextStartOps
        Task {
          await AppLogger.shared.log(
            "[AudioCaptureProxy] forced wedge (DEBUG) stage=\(stage) remaining=\(remaining)",
            level: .info, category: "XPC"
          )
        }
        if let dispatchedGen {
          reportLineDeath(generation: dispatchedGen, cause: .wedged, wasCapturing: false)
        }
        throw XPCOperationSignalWedgeError(
          service: "Audio", stage: stage, observedPhase: "forced_wedge")
      }
    #endif

    let operationID = UUID().uuidString
    let signal = XPCOperationSignalWatcher(file: .audio, operationID: operationID)
    signal.start()
    nonisolated(unsafe) let unsafeWork = work
    let operationTask = Task { @MainActor in
      try await unsafeWork(operationID)
    }
    let outcome = await raceWithSignalWatcher(
      watcher: signal.progressWatcher,
      parentCancellationBehavior: parentCancellationBehavior
    ) {
      try await operationTask.value
    }
    let snapshot = signal.snapshot
    signal.stop()

    switch outcome {
    case .completed(let value):
      return value
    case .threw(let error):
      throw error
    case .wedged:
      operationTask.cancel()
      Task {
        await AppLogger.shared.log(
          "[AudioCaptureProxy] signal watchdog fired stage=\(stage) operationID=\(operationID) phase=\(snapshot.lastObservedPhase) silenceMs=\(snapshot.silenceMs)",
          level: .info, category: "XPC"
        )
      }
      // The wedge is a first-class line-death event in the same funnel as the
      // handlers (§3.3). Retire-only (`wasCapturing: false`): the thrown error
      // below is the caller-visible signal, and the only wedge-able stage with
      // an active capture (`stop_capture`) owns its own state teardown.
      if let dispatchedGen {
        reportLineDeath(generation: dispatchedGen, cause: .wedged, wasCapturing: false)
      }
      throw XPCOperationSignalWedgeError(
        service: "Audio",
        stage: stage,
        observedPhase: snapshot.lastObservedPhase
      )
    }
  }

  #if DEBUG
    /// Stages eligible for the `forceWedgeNextStartOps` fault seam — the three
    /// pre-capture start ops plus their retry/prefix stages. Never `stop_capture`.
    nonisolated private static func isStartStage(_ stage: String) -> Bool {
      stage.hasPrefix("start_engine") || stage.hasPrefix("begin_capture")
    }
  #endif

  // MARK: - Start-op retry (#1194)

  /// Runs one idempotent pre-capture start op with a bounded single retry.
  ///
  /// The three start ops are retry-safe: `isCapturing` is false throughout
  /// (flipped only after `beginCapturePhase`'s XPC call succeeds), so no audio
  /// exists to lose or duplicate. The retry always lands on a NEW connection,
  /// which reaches a brand-new service-side world (fresh `AudioServiceHandler`
  /// + fresh `AudioCaptureManager` per accepted connection) — duplicate
  /// delivery to a surviving world is structurally impossible.
  ///
  /// Bounded-once semantics: exactly one reacquire-and-resend per public call,
  /// shared across both error shapes (wedge / unreachable) and including the
  /// `prefix` — a prefix failure counts as exhaustion, never a nested retry.
  /// Exhaustion propagates the retry's error unchanged (same types as today).
  /// Internal (not private) so unit tests can drive it with injected operations.
  func withStartRetry<T: Sendable>(
    stage: String,
    prefix: (@MainActor () async throws -> Void)? = nil,
    _ operation: @MainActor @escaping (String) async throws -> T
  ) async throws -> T {
    let firstGen = acquireConnection()
    do {
      return try await withAudioXPCOperationSignal(stage: stage, operation)
    } catch let firstError where isLineDeathSignature(firstError) {
      let retryStarted = ContinuousClock.now
      // Converge, don't stack: the wedge branch / per-call error path already
      // reported this generation's death, making this a guarded no-op there;
      // it is the primary reporter only when the failure surfaced without a
      // death report (e.g. dispatch on an already-empty slot). If a sibling
      // already retired firstGen and acquired a fresh line, acquireConnection
      // below reuses it instead of stacking a second connection.
      reportLineDeath(
        generation: firstGen, cause: Self.lineDeathCause(of: firstError), wasCapturing: false)
      acquireConnection()
      do {
        try await prefix?()
        let value = try await withAudioXPCOperationSignal(stage: "\(stage)_retry", operation)
        emitRetryResolved(
          stage: stage, trigger: firstError, outcome: "recovered", since: retryStarted)
        return value
      } catch {
        emitRetryResolved(
          stage: stage, trigger: firstError, outcome: "exhausted", since: retryStarted)
        throw error
      }
    }
  }

  /// The two dead-line signatures that trigger the single start retry. Device
  /// errors and service-reply NSErrors never match — they propagate unretried.
  private func isLineDeathSignature(_ error: any Error) -> Bool {
    if error is XPCOperationSignalWedgeError { return true }
    if case XPCTransportError.serviceUnreachable = error { return true }
    return false
  }

  nonisolated private static func lineDeathCause(of error: any Error) -> LineDeathCause {
    error is XPCOperationSignalWedgeError ? .wedged : .callError
  }

  private func emitRetryResolved(
    stage: String, trigger: any Error, outcome: String, since: ContinuousClock.Instant
  ) {
    let ctx = AudioStartRetryContext(
      stage: stage,
      trigger: trigger is XPCOperationSignalWedgeError ? "wedged" : "service_unreachable",
      outcome: outcome,
      recoveryMs: Self.ms(ContinuousClock.now - since)
    )
    Task {
      await AppLogger.shared.log(
        "[AudioCaptureProxy] start retry resolved stage=\(ctx.stage) trigger=\(ctx.trigger) outcome=\(ctx.outcome) recoveryMs=\(ctx.recoveryMs)",
        level: .info, category: "XPC"
      )
    }
    onAudioStartRetryResolved?(ctx)
  }

  // MARK: - XPC connection management (#1194)

  /// The single acquisition funnel. Fully synchronous — no suspension between
  /// create, stamp, install handlers, and config replay — so it is atomic on
  /// the MainActor and cannot race itself. Reuses a live line when one exists.
  /// Internal (not private) so unit tests can observe generation movement.
  @discardableResult
  func acquireConnection() -> UInt64 {
    if let live = slot.current { return live.generation }

    let conn = NSXPCConnection(serviceName: XPCServiceName.audioService)
    conn.remoteObjectInterface = NSXPCInterface(with: AudioServiceProtocol.self)
    conn.exportedInterface = NSXPCInterface(with: AudioServiceClientProtocol.self)
    conn.exportedObject = self

    let gen = slot.install(conn)

    // CRITICAL: interruptionHandler and invalidationHandler run on XPC dispatch
    // queues, NOT MainActor. Closures defined inside @MainActor methods inherit
    // that isolation in Swift 6, causing dispatch_assert_queue_fail when XPC
    // calls them. Extract to nonisolated static to break the inheritance. Each
    // handler is stamped with THIS connection's generation.
    conn.interruptionHandler = Self.makeInterruptionHandler(proxy: self, generation: gen)
    conn.invalidationHandler = Self.makeInvalidationHandler(proxy: self, generation: gen)

    conn.resume()

    // Unconditional config replay on every fresh line — there is no reinit
    // flag to forget. The sends also trigger launchd to spawn the service.
    replayConfig()
    return gen
  }

  /// Replays stored configuration to a freshly acquired connection. Both items
  /// are fire-and-forget; per-item ordering against the start ops is proven in
  /// the plan (§3.2): VAD is applied synchronously on delivery service-side (the
  /// one start-critical item), the warm-engine policy is not consumed in the
  /// start window.
  private func replayConfig() {
    serviceProxy { [self] proxy in
      if let vad = vadConfig {
        proxy.configureVAD(
          autoStop: vad.autoStop, silenceTimeout: vad.silenceTimeout,
          sensitivity: vad.sensitivity, energyGate: vad.energyGate)
      }
      proxy.setWarmEnginePolicy(warmEnginePolicy.rawValue)
    }
  }

  /// Gets the remote proxy with error handling.
  /// `onProxyError` is called if the proxy can't be obtained (no live line or
  /// cast fails) AND if the XPC framework delivers a per-call error (service
  /// crashed mid-call). This is critical: when the service dies after a call is
  /// dispatched but before it replies, the XPC error handler fires but the
  /// reply handler does NOT. Without routing the error to `onProxyError`, any
  /// pending continuation hangs forever.
  ///
  /// #1194: every per-call transport error also reports line death for the
  /// generation the call dispatched on (the v1 hole where this path mutated
  /// nothing, leaving a half-dead connection for the next use, is closed
  /// structurally). The report precedes `onProxyError` so a retrying caller
  /// always finds the slot already retired.
  ///
  /// `wasCapturing` is read LIVE at error time (Codex code-diff r1 [P2]):
  /// because `retire` stale-guards the connection-level handlers, the per-call
  /// error is often the ONLY observer of a mid-capture service death (e.g. a
  /// streaming `getSamplesSnapshot` or a live `setWarmEnginePolicy` send in
  /// flight when the helper dies) — hard-coding `false` here would skip the
  /// capturing teardown forever and wedge the recording. The one caller that
  /// owns its own teardown (`stopCapture`) suppresses this via
  /// `capturingTeardownOnCallError: false`, preserving its no-double-fire
  /// contract (`onXPCReplyFailed` stays the sole caller-visible stop signal).
  private func serviceProxy(
    _ work: (any AudioServiceProtocol) -> Void,
    onProxyError: (() -> Void)? = nil,
    capturingTeardownOnCallError: Bool = true
  ) {
    guard let live = slot.current else {
      onProxyError?()
      return
    }
    let dispatchedGen = live.generation
    let proxy = live.connection.remoteObjectProxyWithErrorHandler(
      Self.makeXPCErrorHandler { [weak self] in
        guard let self else {
          onProxyError?()
          return
        }
        self.reportLineDeath(
          generation: dispatchedGen,
          cause: .callError,
          wasCapturing: capturingTeardownOnCallError && self.isCapturing
        )
        onProxyError?()
      })
    guard let service = proxy as? AudioServiceProtocol else {
      onProxyError?()
      return
    }
    work(service)
  }

  /// Build the XPC error handler in a nonisolated context.
  /// Critical: closures defined inside @MainActor methods inherit that isolation.
  /// When XPC calls the error handler on its dispatch queue, Swift 6 asserts
  /// dispatch_assert_queue(main) and traps with EXC_BREAKPOINT. By constructing
  /// the handler in a nonisolated static method, the closure is free of @MainActor.
  /// Build the XPC per-call error handler in a nonisolated context.
  /// This handler fires when the service crashes after a call is dispatched but before it replies.
  /// It MUST call onProxyError to resume any pending continuation — otherwise the caller hangs forever.
  /// The error handler is the primary recovery signal; interruption/invalidation are secondary cleanup.
  nonisolated private static func makeXPCErrorHandler(onProxyError: (() -> Void)? = nil)
    -> @Sendable (any Error) -> Void
  {
    // Capture onProxyError as nonisolated(unsafe) — it may reference @MainActor closures
    // but we dispatch it via Task { @MainActor } so the actual call is safe.
    nonisolated(unsafe) let proxyError = onProxyError
    return { error in
      Task { @MainActor in
        await AppLogger.shared.log(
          "[AudioCaptureProxy] XPC error: \(error.localizedDescription)",
          level: .info, category: "XPC"
        )
        proxyError?()
      }
    }
  }

  /// Build the XPC interruptionHandler in a nonisolated context.
  /// Same isolation-escape pattern as makeXPCErrorHandler.
  ///
  /// #1194: stamped with the generation of the connection it is installed on.
  /// After the MainActor hop it reports line death for ITS generation only —
  /// a stale hop about a retired predecessor fails `reportLineDeath`'s retire
  /// guard and is provably inert, even when the hop's Task was already queued
  /// before the slot moved on. Internal (not private) so unit tests can invoke
  /// the constructed handler directly.
  nonisolated static func makeInterruptionHandler(
    proxy: AudioCaptureProxy, generation: UInt64
  ) -> @Sendable () -> Void {
    return { [weak proxy] in
      Task { @MainActor [weak proxy] in
        guard let proxy else { return }
        await AppLogger.shared.log(
          "[AudioCaptureProxy] XPC interruptionHandler fired gen=\(generation) wasCapturing=\(proxy.isCapturing)",
          level: .info, category: "XPC"
        )
        proxy.reportLineDeath(
          generation: generation, cause: .interrupted, wasCapturing: proxy.isCapturing)
      }
    }
  }

  /// Build the XPC invalidationHandler in a nonisolated context. Same
  /// generation-stamping contract as `makeInterruptionHandler` — the v1 race
  /// where a stale invalidation hop clobbered a freshly created replacement
  /// (the handler nil'd `connection` with no identity check) dies here.
  nonisolated static func makeInvalidationHandler(
    proxy: AudioCaptureProxy, generation: UInt64
  ) -> @Sendable () -> Void {
    return { [weak proxy] in
      Task { @MainActor [weak proxy] in
        guard let proxy else { return }
        await AppLogger.shared.log(
          "[AudioCaptureProxy] XPC invalidationHandler fired gen=\(generation) wasCapturing=\(proxy.isCapturing)",
          level: .info, category: "XPC"
        )
        proxy.reportLineDeath(
          generation: generation, cause: .invalidated, wasCapturing: proxy.isCapturing)
      }
    }
  }

  // MARK: - Line death (#1194)

  /// What killed the line. Determines which caller-visible signals fire on
  /// retirement (`reportLineDeath`) — the existing Sentry taxonomy
  /// (interruptCapturing / invalidateCapturing / invalidateIdle) is preserved
  /// per cause.
  enum LineDeathCause: String, Sendable {
    case invalidated, interrupted, wedged, callError
  }

  /// The single generation-guarded consumer for every line-death signal:
  /// connection invalidation, connection interruption, watchdog wedge, and
  /// per-call transport error all land here (§3.3). The four uncoordinated
  /// mutation paths this replaces are gone.
  ///
  /// Idempotent per generation: retiring an already-retired (or never-current)
  /// generation is a logged no-op, so double reports and stale handler hops
  /// are structurally harmless.
  ///
  /// `wasCapturing` is caller-supplied, not read from state: the wedge
  /// reporters and the stop path hard-code `false` (retire-only —
  /// `stopCapture` owns its own teardown and today deliberately does NOT fire
  /// `onEngineInterrupted` on a stop failure; that contract is preserved),
  /// while handlers and non-stop per-call errors pass the live `isCapturing`
  /// so a mid-capture death always runs the teardown exactly once.
  /// Internal (not private) so unit tests can characterize the transition.
  func reportLineDeath(generation: UInt64, cause: LineDeathCause, wasCapturing: Bool) {
    guard slot.retire(generation) else {
      // Stale event about a retired predecessor — provably inert. Log-only
      // by design: app.log is the diagnosis surface for discards.
      let currentGen = slot.generation
      Task {
        await AppLogger.shared.log(
          "[AudioCaptureProxy] stale line-death discarded gen=\(generation) cause=\(cause.rawValue) currentGen=\(currentGen)",
          level: .info, category: "XPC"
        )
      }
      return
    }
    Task {
      await AppLogger.shared.log(
        "[AudioCaptureProxy] line death gen=\(generation) cause=\(cause.rawValue) wasCapturing=\(wasCapturing)",
        level: .info, category: "XPC"
      )
    }

    let endingSession = activeCaptureGeneration
    // #455: compute duration BEFORE flipping isCapturing / resetting
    // captureStartUptimeNs so the breadcrumb has a real number. Idle deaths
    // have no active session and so no duration to report.
    let firedAt = DispatchTime.now().uptimeNanoseconds
    let durationNs: UInt64? =
      wasCapturing && captureStartUptimeNs > 0 && firedAt >= captureStartUptimeNs
      ? (firedAt - captureStartUptimeNs) : nil

    if wasCapturing {
      // Capturing-teardown side effects, byte-identical to the former
      // interruption/invalidation handlers.
      stallWorkItem?.cancel()
      stallWorkItem = nil
      isCapturing = false
      activeCaptureOperationID = nil  // #1408 A3
      captureStartUptimeNs = 0  // #455
      // #1317 (cloud review P2, round 7): NOT cleared here — see the field's
      // doc comment. A teardown-time clear (this method, an interruption
      // path) can race the kernel's STOP-time read the same way `stopCapture()`
      // did (round 6 P1): the kernel falls through interruption exits into
      // the SAME normal stop tail when the interruption's audio is salvageable.
      audioLevel = 0
      captureGeneration &+= 1
      bufferContinuation?.finish()
      bufferContinuation = nil
      // XPC connection break — `onXPCServiceError` (below) is the sole owner
      // of this capture, so tag `.xpcConnectionLost` (A3 suppresses it).
      onEngineInterrupted?(.xpcConnectionLost)
    }

    switch cause {
    case .invalidated:
      // Invalidation is always a telemetry signal — the connection is gone.
      onXPCServiceError?(
        XPCErrorContext(
          kind: wasCapturing ? .invalidateCapturing : .invalidateIdle,
          sessionID: wasCapturing ? endingSession : nil,
          recordingDurationNs: durationNs
        )
      )
    case .interrupted, .callError:
      // Idle events stay silent end-to-end (today's contract). A CAPTURING
      // call error is the transport-loss-during-capture shape whose Sentry
      // signal previously arrived via the interruption handler — that handler
      // is now stale-guarded once this retire runs, so the signal is re-homed
      // here under the same `interruptCapturing` kind (Codex code-diff r1 [P2]).
      if wasCapturing {
        onXPCServiceError?(
          XPCErrorContext(
            kind: .interruptCapturing,
            sessionID: endingSession,
            recordingDurationNs: durationNs
          )
        )
      }
    case .wedged:
      // Retire-only: the thrown error is the caller-visible signal. No
      // wedge-able stage runs while capturing — the only one that could
      // (`stop_capture`) hard-codes `wasCapturing: false` because stopCapture
      // owns its own teardown.
      break
    }
  }

  // MARK: - V2 fault-injection (DEBUG only, issue #291)

  #if DEBUG
    /// Terminates the active XPC line synchronously through the #1194 funnel:
    /// reports an `.invalidated` line death for the current generation, which
    /// retires the slot (invalidating the connection), flips
    /// `isCapturing = false`, finishes the buffer continuation, and emits the
    /// `onXPCServiceError(.invalidateCapturing / .invalidateIdle)` telemetry
    /// callback — the same observable effect as the pre-#1194
    /// `connection?.invalidate()`, now deterministic AND synchronous (no
    /// async handler hop).
    ///
    /// Drives Lane A scenario A4 ("audio XPC service kill") via the DEBUG
    /// localhost endpoint. Equivalent in effect to a real audio service crash
    /// mid-stream.
    ///
    /// `package` access: callable from `DebugFaultEndpoint` in the app target.
    /// Inert in release builds.
    package func forceConnectionTerminationNow() {
      guard let live = slot.current else { return }
      reportLineDeath(
        generation: live.generation, cause: .invalidated, wasCapturing: isCapturing)
    }

    // MARK: - #1317 proof-bench arm/status channel

    /// Arm the DEBUG all-zero injector in the helper. Returns `true` only on a
    /// helper `OK` reply; ANY failure (no live line, transport error, arm error)
    /// returns `false` so the endpoint fails closed. `package` access: driven by
    /// `DebugFaultEndpoint` (`force_zero_fill(...)`).
    package func debugArmZeroFill(_ arm: DebugZeroFillArm) async -> Bool {
      guard let payload = try? JSONEncoder().encode(arm) else { return false }
      // A freshly launched debug app has sent no configuration yet, so no audio
      // XPC line exists; the harness arms BEFORE the first recording, so
      // `serviceProxy` would hit `onProxyError` and fail closed with
      // `ERR arm_failed` before any helper is spawned.
      // Bring the line up first — `acquireConnection()` is idempotent (returns
      // the live line if one already exists), and the subsequent start reuses
      // this same slot, so the helper we arm is the helper that will record.
      // Cloud review PR #1504.
      _ = acquireConnection()
      // One-shot guard (like `stopCapture`): a reply followed by a per-call
      // transport error (or vice versa) would otherwise resume twice and trap.
      let ok: Bool? = try? await withCheckedThrowingContinuation {
        (cont: CheckedContinuation<Bool, any Error>) in
        let guard_ = OneShotContinuation(cont)
        serviceProxy { proxy in
          proxy.debugArmZeroFill(payload) { error in
            guard_.resume(returning: error == nil)
          }
        } onProxyError: {
          guard_.resume(returning: false)
        }
      }
      return ok ?? false
    }

    /// Read the injector's fault status from the helper and merge the proxy's own
    /// live XPC generation. Returns `nil` — never a defaulted status — on any
    /// no-connection / transport / decode failure OR when there is no live line to
    /// source an XPC generation from (absent-generation ⇒ fail closed ⇒ `ERR`).
    /// "Armed" is not evidence of "hit"; the caller reads `hit` for that.
    package func debugFaultStatus() async -> DebugFaultStatus? {
      // Snapshot the live generation FIRST; a nil line means no fresh-pipe
      // evidence exists, which is itself a fail-closed outcome.
      guard let xpcGeneration = slot.current?.generation else { return nil }
      // One-shot guard against a reply/error double-resume (see `debugArmZeroFill`).
      // `try?` yields a double optional (continuation payload is itself optional);
      // `?? nil` flattens it back to `DebugFaultServiceStatus?`.
      let serviceStatus: DebugFaultServiceStatus? =
        (try? await withCheckedThrowingContinuation {
          (cont: CheckedContinuation<DebugFaultServiceStatus?, any Error>) in
          let guard_ = OneShotContinuation(cont)
          serviceProxy { proxy in
            proxy.debugFaultStatus { data, _ in
              guard let data,
                let decoded = try? JSONDecoder().decode(
                  DebugFaultServiceStatus.self, from: data)
              else {
                guard_.resume(returning: nil)
                return
              }
              guard_.resume(returning: decoded)
            }
          } onProxyError: {
            guard_.resume(returning: nil)
          }
        }) ?? nil
      guard let s = serviceStatus else { return nil }
      return DebugFaultStatus(
        armed: s.armed, hit: s.hit, trialID: s.trialID, mode: s.mode,
        zeroedSampleCount: s.zeroedSampleCount, sourceIncarnation: s.sourceIncarnation,
        xpcGeneration: xpcGeneration, captureSourceType: s.captureSourceType)
    }
  #endif

  // MARK: - VAD Interface (Step 5)

  /// Stored VAD config — forwarded to service, replayed on every fresh connection via replayConfig().
  private var vadConfig:
    (autoStop: Bool, silenceTimeout: Double, sensitivity: Float, energyGate: Bool)?

  public func configureVAD(
    autoStop: Bool, silenceTimeout: Double, sensitivity: Float, energyGate: Bool
  ) {
    vadConfig = (autoStop, silenceTimeout, sensitivity, energyGate)
    serviceProxy { proxy in
      proxy.configureVAD(
        autoStop: autoStop, silenceTimeout: silenceTimeout, sensitivity: sensitivity,
        energyGate: energyGate)
    }
  }

  // periphery:ignore - XPC capture contract (invoked via NSXPC proxy)
  public func getSamplesSnapshot(fromIndex: Int) async -> (samples: [Float], totalCount: Int) {
    // Use OneShotContinuation to guarantee exactly one resume — XPC error handler and
    // reply handler can race, and double-resume is undefined behavior.
    let sessionID = activeCaptureGeneration
    do {
      return try await withCheckedThrowingContinuation {
        (cont: CheckedContinuation<(samples: [Float], totalCount: Int), any Error>) in
        let guard_ = OneShotContinuation(cont)
        serviceProxy { proxy in
          proxy.getSamplesSnapshot(fromIndex: fromIndex) { data, totalCount in
            let floats = Self.dataToFloats(data)
            guard_.resume(returning: (samples: floats, totalCount: totalCount))
          }
        } onProxyError: { [weak self] in
          self?.reportXPCReplyFailure(stage: "get_samples", sessionID: sessionID)
          guard_.resume(returning: (samples: [], totalCount: 0))
        }
      }
    } catch {
      return (samples: [], totalCount: 0)
    }
  }

  // periphery:ignore - XPC capture contract (invoked via NSXPC proxy)
  public func getVADSegments() async -> [SpeechSegment] {
    // Use OneShotContinuation to guarantee exactly one resume.
    let sessionID = activeCaptureGeneration
    do {
      return try await withCheckedThrowingContinuation {
        (cont: CheckedContinuation<[SpeechSegment], any Error>) in
        let guard_ = OneShotContinuation(cont)
        serviceProxy { proxy in
          proxy.getVADSegments { data in
            guard_.resume(returning: Self.decodeVADSegments(data))
          }
        } onProxyError: { [weak self] in
          self?.reportXPCReplyFailure(stage: "get_speech_segments", sessionID: sessionID)
          guard_.resume(returning: [])
        }
      }
    } catch {
      return []
    }
  }

  /// Invoke `onXPCReplyFailed` before a reply-path swallowed empty default
  /// surfaces to callers, so the pipeline can emit the correct root cause
  /// instead of mis-classifying as `no_audio_captured`.
  private func reportXPCReplyFailure(stage: String, sessionID: UInt64) {
    onXPCReplyFailed?(
      XPCReplyFailureContext(
        replyStage: stage,
        errorDomain: "com.enviouswispr.xpc",
        errorCode: -1,
        errorDescription: "XPC reply failed — service unreachable",
        sessionID: sessionID
      )
    )
  }

  // MARK: - Data conversion

  /// Convert raw Data to [Float]. Transport format: Float32 PCM, non-interleaved mono, 16kHz.
  /// Data is raw bytes — no header, no metadata.
  /// nonisolated: called from XPC reply callbacks which run on XPC dispatch queues, not MainActor.
  nonisolated private static func dataToFloats(_ data: Data) -> [Float] {
    guard !data.isEmpty, data.count.isMultiple(of: MemoryLayout<Float>.size) else { return [] }
    return data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
  }

  /// Decode the helper's JSON-encoded capture-health metadata (#1434).
  /// nonisolated: called from XPC reply callbacks which run on XPC dispatch
  /// queues, not MainActor — decoding inline in a closure literal written
  /// inside the (MainActor-inherited) reply block traps at runtime because
  /// the closure inherits MainActor isolation from its lexical context but
  /// actually runs on the XPC queue; hoisting to a nonisolated static
  /// function (matching dataToFloats/decodeVADSegments above) breaks that
  /// inheritance the same way #1434's live UAT crash proved was required.
  nonisolated private static func decodeCaptureStopMetadata(_ data: Data?) -> CaptureStopMetadata? {
    guard let data else { return nil }
    return try? JSONDecoder().decode(CaptureStopMetadata.self, from: data)
  }

  /// Decode packed [Int32 start, Int32 end] pairs into SpeechSegment array.
  nonisolated private static func decodeVADSegments(_ data: Data) -> [SpeechSegment] {
    let pairSize = MemoryLayout<Int32>.size * 2
    guard !data.isEmpty, data.count.isMultiple(of: pairSize) else { return [] }
    return data.withUnsafeBytes { raw in
      let int32s = raw.bindMemory(to: Int32.self)
      var segments: [SpeechSegment] = []
      segments.reserveCapacity(int32s.count / 2)
      for i in stride(from: 0, to: int32s.count, by: 2) {
        segments.append(
          SpeechSegment(
            startSample: Int(int32s[i]),
            endSample: Int(int32s[i + 1])
          ))
      }
      return segments
    }
  }
}

// MARK: - AudioServiceClientProtocol (service → host callbacks)

/// These callbacks arrive on an XPC dispatch queue (not RT, not main).
/// Each hops to @MainActor via Task before updating observable state.
extension AudioCaptureProxy: AudioServiceClientProtocol {

  /// Received audio buffer from service — reconstruct AVAudioPCMBuffer and deliver.
  nonisolated public func audioBufferCaptured(_ data: Data, frameCount: Int, audioLevel: Float) {
    // Validation guards before memcpy.
    guard frameCount > 0, frameCount <= 65536 else { return }
    guard data.count == frameCount * MemoryLayout<Float>.size else { return }
    guard
      let buffer = AVAudioPCMBuffer(
        pcmFormat: Self.targetFormat,
        frameCapacity: AVAudioFrameCount(frameCount)
      )
    else { return }

    buffer.frameLength = AVAudioFrameCount(frameCount)
    data.withUnsafeBytes { raw in
      guard let src = raw.baseAddress, let dst = buffer.floatChannelData?[0] else { return }
      memcpy(dst, src, data.count)
    }

    nonisolated(unsafe) let safeBuffer = buffer
    // Snapshot frameCount for generation check inside the MainActor Task.
    // captureGeneration is read inside the Task (MainActor-isolated), not here.

    Task { @MainActor [weak self] in
      guard let self else { return }
      // Reject stale callbacks from previous capture sessions.
      guard self.isCapturing,
        self.captureGeneration == self.activeCaptureGeneration
      else { return }
      #if DEBUG
        // V2 fault-injection (issue #291): drop buffer if forced-stall is active.
        // Intentionally does NOT flip `hasReceivedBufferThisSession` so the
        // existing stall watchdog still fires after `audioCaptureStallWindowMs`.
        if self.forceStallRemainingBuffers > 0 {
          self.forceStallRemainingBuffers -= 1
          return
        }
      #endif
      // #1317: mid-recording all-zero harness-glitch detector. After the
      // generation guard, on the already-reconstructed float buffer, before
      // yielding — no new XPC callback, no RT-thread work (§3.1).
      self.evaluateDeadAirDetector(
        buffer: safeBuffer, sessionID: self.activeCaptureGeneration)
      self.hasReceivedBufferThisSession = true
      self.audioLevel = audioLevel
      self.bufferContinuation?.yield(safeBuffer)
      self.onBufferCaptured?(safeBuffer)
    }
  }

  /// Service's audio engine was interrupted (device disconnect, emergency
  /// teardown, max-duration cap). Only fires onEngineInterrupted during
  /// active capture; idle relays are no-ops. `cause` is the relayed
  /// `EngineInterruptionCause` raw value (issue #1174 A3).
  ///
  /// #1194: deliberately OUTSIDE the line-death funnel. This is an ENGINE
  /// event, not a LINE event — it arrives over the exported-object channel
  /// with no connection identity on the wire, so it cannot be
  /// generation-guarded, and retiring the current line on it would let a
  /// stale relay from a dying predecessor world kill a healthy fresh line.
  /// The relaying service world is by definition ALIVE with its config intact
  /// (a crashed process fires the connection-level interruptionHandler
  /// instead, which IS in the funnel), so the connection is kept and nothing
  /// needs replaying — the next `start_engine` re-prepares the engine with
  /// device UIDs riding its own arguments.
  nonisolated public func engineInterrupted(cause: String) {
    Task { @MainActor [weak self] in
      guard let self else { return }
      if self.isCapturing {
        self.stallWorkItem?.cancel()
        self.stallWorkItem = nil
        self.isCapturing = false
        self.activeCaptureOperationID = nil  // #1408 A3
        self.captureStartUptimeNs = 0  // #455
        // #1317 (cloud review P2, round 7): NOT cleared here — see the
        // field's doc comment; same reasoning as the sibling teardown block
        // above.
        self.audioLevel = 0
        self.captureGeneration &+= 1
        self.bufferContinuation?.finish()
        self.bufferContinuation = nil
        // The service relays ALL its interruptions through this one channel.
        // `.deviceRemoved` survives intact (the helper ran the liveness check);
        // every other loss cause collapses to `.engineLost` (no other owner
        // across the XPC boundary — there is no capture-session relay, so an
        // XPC-mode interruptions must be captured here too).
        // The hard max-duration cap no longer travels here at all (#1408 A3:
        // `maxDurationReachedTriggered` is its own event channel).
        self.onEngineInterrupted?(EngineInterruptionCause.hostCause(forRelayedRawValue: cause))
      }
      // #1194: the former `needsReinit = true` here is deleted with nothing
      // replacing it — any FRESH line gets an unconditional config replay at
      // acquisition, and the relaying (alive) world keeps its config.
    }
  }

  /// Service-side VAD detected sustained silence after speech — auto-stop should trigger.
  /// Stale-fire protection: generation check + pipeline state guard (in the former root state handler).
  nonisolated public func vadAutoStopTriggered() {
    Task { @MainActor [weak self] in
      guard let self else { return }
      guard self.isCapturing,
        self.captureGeneration == self.activeCaptureGeneration
      else { return }
      self.onVADAutoStop?()
    }
  }

  /// #1408 A3: the helper's hard sample-count backstop tripped — a normal
  /// auto-stop, never a loss. Stale-fire protection goes one step past
  /// `vadAutoStopTriggered` above (Codex code-diff r6): the event carries the
  /// begin `operationID` that owns the emitting capture, and a mismatch against
  /// the ACTIVE session's begin op is a delayed relay from an EARLIER session —
  /// swallowed, so it can never stop a later recording. (The generation compare
  /// alone cannot answer that: both fields are CURRENT state, equal during any
  /// active session.)
  nonisolated public func maxDurationReachedTriggered(operationID: String) {
    Task { @MainActor [weak self] in
      guard let self else { return }
      guard self.isCapturing,
        let active = self.activeCaptureOperationID,
        operationID == active
      else { return }
      self.onMaxDurationReached?()
    }
  }

  /// The bundled VAD model is unavailable (missing/corrupted asset — #1224).
  /// No generation/capture-state guard, unlike the siblings above — this is a
  /// bypass notice about the model's own health, not a stop-triggering event
  /// tied to a specific capture. Never reads settings or references AppKit;
  /// the upper layer (`AudioEventRouter`) decides eligibility and UI.
  nonisolated public func vadModelUnavailable() {
    Task { @MainActor [weak self] in
      self?.onVADModelUnavailable?()
    }
  }
}

// MARK: - Helpers

/// Thread-safe one-shot continuation guard. Ensures exactly one resume,
/// preventing crashes from double-resume when XPC reply and error handler race.
private final class OneShotContinuation<T: Sendable>: @unchecked Sendable {
  private var continuation: CheckedContinuation<T, any Error>?
  private let lock = NSLock()

  init(_ continuation: CheckedContinuation<T, any Error>) {
    self.continuation = continuation
  }

  func resume(returning value: T) {
    lock.lock()
    let cont = continuation
    continuation = nil
    lock.unlock()
    cont?.resume(returning: value)
  }

  func resume(throwing error: any Error) {
    lock.lock()
    let cont = continuation
    continuation = nil
    lock.unlock()
    cont?.resume(throwing: error)
  }
}

/// Convenience overload for Void continuations.
extension OneShotContinuation where T == Void {
  func resume() {
    resume(returning: ())
  }
}

/// XPC transport errors surfaced by the proxy.
enum XPCTransportError: LocalizedError {
  case serviceUnreachable

  var errorDescription: String? {
    switch self {
    case .serviceUnreachable: return "XPC audio service is unreachable."
    }
  }
}
