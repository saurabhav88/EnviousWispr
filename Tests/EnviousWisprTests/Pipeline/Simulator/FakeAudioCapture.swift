@preconcurrency import AVFoundation
import EnviousWisprCore
import Foundation

@testable import EnviousWisprAudio

// MARK: - FakeAudioCapture (epic #827, PR-2 plan §3.3; Codex grounded review revision 3)
//
// Conforms to the FULL production `AudioCaptureInterface` (~31 members). The
// behaviorally-active members the simulator drives: the `beginCapturePhase()`/
// `startCapture()` buffer streams, `onBufferCaptured`, `onEngineInterrupted`,
// `onVADAutoStop`, `onCaptureStalled`, `stopCapture()`, `configureVAD`,
// `getSamplesSnapshot`, `getVADSegments`, `preWarm`/`abortPreWarm`. The rest
// are inert: observable properties return constants, the XPC-only telemetry
// callbacks stay nil exactly as a direct (non-XPC) source leaves them.
//
// The fake synthesizes real `AVAudioPCMBuffer`s (16 kHz mono Float32) because
// the interface streams and callbacks are typed in `AVAudioPCMBuffer` — there
// is no zero-`AVFoundation` path for the capture fake. `AudioBufferHandoff`
// (which `FakeEngine` consumes) is a separate, synthetic-Float32 carrier.

/// A configurable failure a `FakeAudioCapture` can be told to raise.
enum FakeCaptureError: Error, Sendable {
  case engineStartFailed
  case captureStartFailed
  case permissionDenied
}

@MainActor
final class FakeAudioCapture: AudioCaptureInterface {

  // MARK: Configurable failure injection

  /// `startEnginePhase()` throws `.engineStartFailed` when set.
  var failEngineStart = false
  /// `beginCapturePhase()` / `startCapture()` throw `.captureStartFailed`.
  var failCaptureStart = false
  /// `startEnginePhase()` throws `.permissionDenied` (mic permission revoked).
  var permissionDenied = false
  /// `preWarm()` throws this when non-nil (#903 — lets a test drive the real
  /// `RecordingSessionKernel.preWarm()` rethrow path). Nil = preWarm succeeds.
  var preWarmError: Error?

  // MARK: Observed counters (for FakeAudioCaptureTests teardown assertion)

  private(set) var stopCaptureCallCount = 0
  private(set) var beginCapturePhaseCallCount = 0
  private(set) var preWarmCallCount = 0
  private(set) var abortPreWarmCallCount = 0
  private(set) var deliveredBufferCount = 0

  // MARK: #1445 format-stabilization scripting

  /// Scripted results for successive `waitForFormatStabilization` calls. Empty
  /// (default) => every call returns `true` (stable), preserving every
  /// pre-#1445 scenario. A `[false, true]` script drives the kernel's
  /// one-rebuild-then-diagnostic-re-verify path: the first `false` triggers the
  /// single rebuild, the second is the post-rebuild re-verify.
  var stabilizationResults: [Bool] = []
  private(set) var stabilizationCallCount = 0
  private(set) var rebuildEngineCallCount = 0
  // Heartpath 5b (#1520): record signal-only source retirements + the session ids
  // they targeted, so the kernel test can assert the retire fired (and NOT the old
  // eligibility-gated rebuild) on an ineligible zero-signal take.
  private(set) var retireCapturingSourceCallCount = 0
  private(set) var retiredCaptureSessionIDs: [UInt64] = []
  /// Heartpath 5b: the fence outcome this fake returns. Defaults to `.retired`
  /// so kernel telemetry tests exercise the arming path; set to any no-op result
  /// (e.g. `.sourceNotRunning`) to exercise the "emit event 1 but do not arm"
  /// branch.
  var retireCapturingSourceResult: ZeroSignalRetireResult = .retired
  private(set) var startEnginePhaseCallCount = 0

  /// When set, the Nth (1-based) `waitForFormatStabilization` call parks on a
  /// continuation until `releaseStabilizationGate()`, letting a test interleave
  /// a cancel while the post-rebuild re-verify is in flight (#1445).
  var gateStabilizationCall: Int?
  private var gateContinuation: CheckedContinuation<Void, Never>?
  private var gateReachedContinuation: CheckedContinuation<Void, Never>?
  private var gateReached = false

  /// #1578: same shape for `stopCapture()`. When set, the Nth (1-based) stop
  /// parks until `releaseStopCaptureGate()`, so a test can conclude the session
  /// by cancel while the normal STOP path is suspended mid-`await`.
  var gateStopCaptureCall: Int?
  private var stopGateContinuation: CheckedContinuation<Void, Never>?
  private var stopGateReachedContinuation: CheckedContinuation<Void, Never>?
  private var stopGateReached = false

  // MARK: Captured audio

  private var accumulatedSamples: [Float] = []
  private var segments: [SpeechSegment] = []

  // MARK: Buffer stream

  private var bufferStream: AsyncStream<AVAudioPCMBuffer>?
  private var bufferContinuation: AsyncStream<AVAudioPCMBuffer>.Continuation?

  // MARK: AudioCaptureInterface — observable state (inert constants)

  private(set) var isCapturing = false
  var audioLevel: Float { 0 }
  var capturedSamples: [Float] { accumulatedSamples }
  /// #1780: tests mutate this to prove the record-start markers carry the
  /// route captured at monitor start, not a later value. Default unchanged.
  var routeOverride: String = "fake"
  var currentAudioRoute: String { routeOverride }
  var currentResolvedRoute: ResolvedRouteTransports? { nil }
  private(set) var currentCaptureSessionID: UInt64 = 0
  var isActivelyCapturing: Bool { isCapturing }
  var captureSourceType: String { "hal_device_input" }

  // MARK: #1844 — observing what the kernel's PRODUCTION snapshot closure reads
  //
  // Overriding the protocol's nil default lets a test hand the kernel a frozen bind
  // and, crucially, COUNT whether the closure consulted it. The count is the only
  // way to discriminate "read the frozen bind and refused" from "refused without
  // looking" — since #1578 the closure returns a categorical reason, and several
  // distinct paths can produce the same non-eligible one, so the returned value
  // alone still cannot carry the claim.

  /// The frozen bind this fake publishes. nil models an invalidated attempt.
  var stubbedZeroSignalDiscriminatorDevice: BoundInputDevice?
  /// Incremented on every read of `zeroSignalDiscriminatorDevice`.
  private(set) var zeroSignalDiscriminatorDeviceReadCount = 0
  var zeroSignalDiscriminatorDevice: BoundInputDevice? {
    zeroSignalDiscriminatorDeviceReadCount += 1
    return stubbedZeroSignalDiscriminatorDevice
  }

  // #1578: the categorical replacements for the old boolean saw-ineligible
  // seam, which is deleted here rather than kept. The kernel no longer
  // reads the legacy Boolean at all, so stubbing it here would model a path
  // production does not take. `zeroSignalDiscriminatorSawIneligible` now comes
  // from the protocol's own compatibility default.

  /// The reason the reactive producer froze for the current run, if any. Read by
  /// the production snapshot closure when the run was classified reactively.
  var stubbedZeroSignalRefusalReason: ZeroSignalEligibility?
  /// Whether the current run was already classified by the reactive producer.
  /// True must short-circuit BEFORE the frozen bind is consulted.
  var stubbedZeroSignalRunWasClassifiedReactively = false
  /// Contexts a rejected reactive forward left behind, handed over in order by
  /// the atomic take.
  var stubbedPendingZeroSignalRefusals: [ZeroSignalRefusalContext] = []
  /// Counts atomic takes, so a test can prove a second drain happened AND was
  /// empty rather than never happening at all.
  private(set) var takePendingZeroSignalRefusalsCallCount = 0

  var zeroSignalRefusalReason: ZeroSignalEligibility? { stubbedZeroSignalRefusalReason }

  var zeroSignalRunWasClassifiedReactively: Bool { stubbedZeroSignalRunWasClassifiedReactively }

  /// Mirrors `AudioCaptureManager`'s contract exactly: synchronous, order
  /// preserving, and empty on every call after the first.
  func takePendingZeroSignalRefusals() -> [ZeroSignalRefusalContext] {
    takePendingZeroSignalRefusalsCallCount += 1
    let pending = stubbedPendingZeroSignalRefusals
    stubbedPendingZeroSignalRefusals.removeAll(keepingCapacity: true)
    return pending
  }

  // MARK: AudioCaptureInterface — callbacks

  var onBufferCaptured: (@Sendable (AVAudioPCMBuffer) -> Void)?
  var onEngineInterrupted: ((EngineInterruptionCause) -> Void)?
  var onVADAutoStop: (() -> Void)?
  var onMaxDurationReached: (() -> Void)?
  var onCaptureStalled: ((CaptureStallContext) -> Void)?
  var onRouteResolved: ((CaptureRouteDecision, _ sourceTypeChanged: Bool) -> Void)?

  // MARK: AudioCaptureInterface — configuration (inert storage)

  var selectedInputDeviceUID = ""
  var preferredInputDeviceIDOverride = ""
  var warmEnginePolicy: WarmEnginePolicy = .off

  init() {}

  // MARK: AudioCaptureInterface — core lifecycle

  func startEnginePhase() async throws {
    startEnginePhaseCallCount += 1
    if permissionDenied { throw FakeCaptureError.permissionDenied }
    if failEngineStart { throw FakeCaptureError.engineStartFailed }
  }

  func beginCapturePhase(recoveryPayload: Data?) async throws -> AsyncStream<AVAudioPCMBuffer> {
    beginCapturePhaseCallCount += 1
    if failCaptureStart { throw FakeCaptureError.captureStartFailed }
    currentCaptureSessionID += 1
    isCapturing = true
    // Clear prior-session audio + VAD evidence at the session boundary —
    // production capture starts each session fresh; a reused fake must too, or
    // it feeds stale audio into the next session (engine-switch / reset cases).
    accumulatedSamples.removeAll()
    segments.removeAll()
    let (stream, continuation) = AsyncStream.makeStream(of: AVAudioPCMBuffer.self)
    bufferStream = stream
    bufferContinuation = continuation
    return stream
  }

  func startCapture() async throws -> AsyncStream<AVAudioPCMBuffer> {
    try await startEnginePhase()
    return try await beginCapturePhase()
  }

  func stopCapture(sessionID: UInt64) async -> CaptureResult {
    stopCaptureCallCount += 1
    isCapturing = false
    bufferContinuation?.finish()
    bufferContinuation = nil
    bufferStream = nil
    let result = CaptureResult(samples: accumulatedSamples, vadSegments: segments)
    // #1578: park the Nth stop so a test can land a cancel while the normal STOP
    // is suspended — the exact race the drain-before-await ordering exists for.
    // Modelled on `gateStabilizationCall` above; signal-based, never a sleep, so
    // it satisfies the simulator's wall-clock ban.
    if let gate = gateStopCaptureCall, gate == stopCaptureCallCount {
      stopGateReached = true
      stopGateReachedContinuation?.resume()
      stopGateReachedContinuation = nil
      await withCheckedContinuation { stopGateContinuation = $0 }
    }
    return result
  }

  /// Suspend until the gated `stopCapture()` call has parked. Returns
  /// immediately if it already parked.
  func awaitStopCaptureGateReached() async {
    if stopGateReached { return }
    await withCheckedContinuation { stopGateReachedContinuation = $0 }
  }

  /// Resume the parked `stopCapture()` call.
  func releaseStopCaptureGate() {
    stopGateContinuation?.resume()
    stopGateContinuation = nil
  }

  func rebuildEngine() { rebuildEngineCallCount += 1 }

  func retireCapturingSource(sessionID: UInt64) -> ZeroSignalRetireResult {
    retireCapturingSourceCallCount += 1
    retiredCaptureSessionIDs.append(sessionID)
    return retireCapturingSourceResult
  }

  func preWarm() async throws {
    preWarmCallCount += 1
    if let preWarmError { throw preWarmError }
  }

  func abortPreWarm() {
    abortPreWarmCallCount += 1
  }

  func waitForFormatStabilization(maxWait: TimeInterval, pollInterval: TimeInterval) async
    -> Bool
  {
    stabilizationCallCount += 1
    let thisCall = stabilizationCallCount
    let result =
      thisCall <= stabilizationResults.count
      ? stabilizationResults[thisCall - 1]
      : true
    if let gate = gateStabilizationCall, gate == thisCall {
      gateReached = true
      gateReachedContinuation?.resume()
      gateReachedContinuation = nil
      await withCheckedContinuation { gateContinuation = $0 }
    }
    return result
  }

  /// Suspend until the gated `waitForFormatStabilization` call has parked (see
  /// `gateStabilizationCall`). Returns immediately if it already parked.
  func awaitStabilizationGateReached() async {
    if gateReached { return }
    await withCheckedContinuation { gateReachedContinuation = $0 }
  }

  /// Resume the parked `waitForFormatStabilization` call.
  func releaseStabilizationGate() {
    gateContinuation?.resume()
    gateContinuation = nil
  }

  // MARK: AudioCaptureInterface — VAD

  func configureVAD(
    autoStop: Bool, silenceTimeout: Double, sensitivity: Float, energyGate: Bool
  ) {}

  func getSamplesSnapshot(fromIndex: Int) async -> (samples: [Float], totalCount: Int) {
    let total = accumulatedSamples.count
    guard fromIndex >= 0, fromIndex < total else { return ([], total) }
    return (Array(accumulatedSamples[fromIndex...]), total)
  }

  func getVADSegments() async -> [SpeechSegment] {
    segments
  }

  // MARK: Harness control surface (scenario `CaptureDirective`s)

  /// Deliver one synthetic 16 kHz mono Float32 buffer onto the capture stream
  /// and through `onBufferCaptured`. `amplitude` controls the constant sample
  /// value — the default 0.1 is well above the kernel's #964 dead-air floor; a
  /// sub-floor value (e.g. 0.001) lets a scenario express a genuinely silent
  /// capture so the no-speech gate can be exercised end-to-end.
  func deliverBuffer(
    frameCount: Int = AudioConstants.captureBufferSize, amplitude: Float = 0.1
  ) {
    let samples = [Float](repeating: amplitude, count: frameCount)
    accumulatedSamples.append(contentsOf: samples)
    deliveredBufferCount += 1
    guard let buffer = Self.makeBuffer(samples: samples) else { return }
    bufferContinuation?.yield(buffer)
    onBufferCaptured?(buffer)
  }

  /// Record one VAD speech segment (so `stopCapture()` reports speech evidence).
  func addSpeechSegment(startSample: Int, endSample: Int) {
    segments.append(SpeechSegment(startSample: startSample, endSample: endSample))
  }

  /// Raise an engine interruption (mic disconnect / route change mid-session) —
  /// the audio-interruption path. Defaults to `.engineLost` (the captured case)
  /// so existing callers keep their behavior; pass a cause to exercise the
  /// suppress paths.
  func raiseEngineInterruption(cause: EngineInterruptionCause = .engineLost) {
    onEngineInterrupted?(cause)
  }

  /// Fire the VAD auto-stop callback.
  func fireVADAutoStop() {
    onVADAutoStop?()
  }

  /// #1408 A3: fire the hard-cap backstop callback (a normal auto-stop event,
  /// mirroring the manager/proxy relay).
  func fireMaxDurationReached() {
    onMaxDurationReached?()
  }

  /// Fire the capture-stall callback (C3 / C4 — the liveness watchdog observed
  /// zero buffers within the stall window).
  func fireCaptureStalled() {
    onCaptureStalled?(makeStallContext())
  }

  /// Construct a synthetic capture-stall context against the fake's current
  /// session counter. Used by the simulator's `ScenarioRunner` to route a
  /// stall directly into the kernel's `externalCaptureStalled(_:)` entry
  /// method (PR-4b.1) — the kernel no longer subscribes to
  /// `onCaptureStalled`, so the simulator drives the FSM transition through
  /// the new entry instead of firing the callback.
  func makeStallContext() -> CaptureStallContext {
    CaptureStallContext(
      sessionID: currentCaptureSessionID,
      armedAtUptimeNs: 0,
      firedAtUptimeNs: 0,
      route: "fake",
      sourceType: captureSourceType,
      engineStartedSuccessfully: true,
      tapInstalled: true,
      formatMismatchObserved: false,
      inputDeviceUIDPreferred: nil,
      inputDeviceUIDSystemDefault: nil,
      failureMode: .noBuffers)
  }

  // MARK: Helpers

  /// Synthesize one 16 kHz mono Float32 `AVAudioPCMBuffer` from samples.
  /// `internal` so other test fixtures (`FakeEngineTests`,
  /// `ParakeetEngineAdapterTests`) build `AudioBufferHandoff`s without
  /// reimplementing buffer construction.
  static func makeBuffer(samples: [Float]) -> AVAudioPCMBuffer? {
    guard
      let format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: AudioConstants.sampleRate,
        channels: AVAudioChannelCount(AudioConstants.channels),
        interleaved: false),
      let buffer = AVAudioPCMBuffer(
        pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))
    else { return nil }
    buffer.frameLength = AVAudioFrameCount(samples.count)
    if let channel = buffer.floatChannelData?[0] {
      samples.withUnsafeBufferPointer { src in
        channel.update(from: src.baseAddress!, count: samples.count)
      }
    }
    return buffer
  }
}
