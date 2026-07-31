@preconcurrency import AVFoundation
import EnviousWisprAudio
import EnviousWisprCore
import Foundation
import Testing

// #1578: the refusal conduit's value types and its source-compatibility
// contract for conformers that have no reactive detector.
//
// Deliberately a plain `import`, not `@testable`: the whole point of these two
// structures and four protocol members is that they are PUBLIC surface the
// Pipeline and AppKit modules consume, so the test exercises them exactly as a
// cross-module caller would. A `@testable` import would hide a missing `public`.
//
// The fixture is a PRIVATE conformer that overrides nothing, and that is
// load-bearing rather than convenient. This suite originally borrowed the shared
// `RouterTestAudioCapture`, on the reasoning that a real conformer is better
// evidence than a purpose-built stub. One chunk later that conformer legitimately
// gained a stored `onZeroSignalRefused` (the router tests need to invoke what the
// router installs), and this suite silently stopped testing the extension default
// while still claiming to — it went red on the assertion that would otherwise
// have quietly become meaningless.
//
// The lesson generalises: a test whose SUBJECT is "what a type that overrides
// nothing receives" cannot use a shared fixture, because any shared fixture may
// legitimately gain an override later. Its fixture has to be a type that by
// construction never will.
//
// This double is deliberately inert everywhere else, so an assertion here can
// only be describing the protocol extension.
@MainActor
@Suite("#1578 zero-signal refusal conduit — value types + conformer defaults")
struct AudioCaptureInterfaceZeroSignalDefaultsTests {

  // MARK: - The two value types

  @Test("refusal context preserves every field, and equality sees a changed one")
  func refusalContextRoundTripsAndComparesByValue() {
    let ctx = ZeroSignalRefusalContext(
      sessionID: 7,
      reason: .deviceMuted,
      transport: "usb",
      failureShape: .becameZeroMidCapture)

    #expect(ctx.sessionID == 7)
    #expect(ctx.reason == .deviceMuted)
    #expect(ctx.transport == "usb")
    #expect(ctx.failureShape == .becameZeroMidCapture)

    // Identical input compares equal — without this, the four inequality
    // assertions below would pass for a type that considered nothing equal.
    #expect(
      ctx
        == ZeroSignalRefusalContext(
          sessionID: 7, reason: .deviceMuted, transport: "usb",
          failureShape: .becameZeroMidCapture))

    // Each field participates: a dashboard that groups by reason × transport ×
    // shape depends on all four being carried, not just the reason.
    #expect(
      ctx
        != ZeroSignalRefusalContext(
          sessionID: 8, reason: .deviceMuted, transport: "usb",
          failureShape: .becameZeroMidCapture))
    #expect(
      ctx
        != ZeroSignalRefusalContext(
          sessionID: 7, reason: .muteUnverified, transport: "usb",
          failureShape: .becameZeroMidCapture))
    #expect(
      ctx
        != ZeroSignalRefusalContext(
          sessionID: 7, reason: .deviceMuted, transport: "bluetooth",
          failureShape: .becameZeroMidCapture))
    #expect(
      ctx
        != ZeroSignalRefusalContext(
          sessionID: 7, reason: .deviceMuted, transport: "usb",
          failureShape: .allZeroFromStart))
  }

  @Test("decision snapshot preserves both fields, and equality sees a changed one")
  func decisionSnapshotRoundTripsAndComparesByValue() {
    let snapshot = ZeroSignalDecisionSnapshot(
      eligibility: .identityMismatch, currentRunWasClassifiedReactively: true)

    #expect(snapshot.eligibility == .identityMismatch)
    #expect(snapshot.currentRunWasClassifiedReactively == true)

    #expect(
      snapshot
        == ZeroSignalDecisionSnapshot(
          eligibility: .identityMismatch, currentRunWasClassifiedReactively: true))
    #expect(
      snapshot
        != ZeroSignalDecisionSnapshot(
          eligibility: .notAlive, currentRunWasClassifiedReactively: true))
    #expect(
      snapshot
        != ZeroSignalDecisionSnapshot(
          eligibility: .identityMismatch, currentRunWasClassifiedReactively: false))
  }

  // MARK: - Conformer defaults, seen through the existential

  @Test("a conformer with no reactive detector reports no refusal reason")
  func defaultRefusalReasonIsNil() {
    let audioCapture: any AudioCaptureInterface = DefaultsOnlyAudioCapture()
    #expect(audioCapture.zeroSignalRefusalReason == nil)
  }

  @Test("a conformer with no reactive detector never claims it classified the run")
  func defaultReactivelyClassifiedFlagIsFalse() {
    let audioCapture: any AudioCaptureInterface = DefaultsOnlyAudioCapture()
    #expect(audioCapture.zeroSignalRunWasClassifiedReactively == false)
  }

  @Test("a conformer with no backlog hands over an empty array, synchronously")
  func defaultTakePendingReturnsEmpty() {
    let audioCapture: any AudioCaptureInterface = DefaultsOnlyAudioCapture()
    #expect(audioCapture.takePendingZeroSignalRefusals().isEmpty)
  }

  /// The settable requirement needs an explicit no-op setter in the extension;
  /// a read-only computed default would not compile against `{ get set }`. This
  /// test is the compile-time proof of that, plus the runtime proof that the
  /// discard is deliberate rather than an accidental store.
  @Test("assigning the refusal callback through the existential compiles and is discarded")
  func defaultCallbackAcceptsAssignmentAndStaysNil() {
    // `let`, not `var`: the protocol is class-bound, so its property setters are
    // non-mutating and the binding itself is never reassigned.
    let audioCapture: any AudioCaptureInterface = DefaultsOnlyAudioCapture()

    audioCapture.onZeroSignalRefused = { _ in true }

    // The default getter is `nil` by contract, so the closure above is not
    // retrievable and must never be invoked from here.
    #expect(audioCapture.onZeroSignalRefused == nil)
  }
}

/// A conformer that overrides NOTHING of the #1578 surface — no stored reason,
/// no stored flag, no stored callback, no backlog. Every zero-signal answer it
/// gives therefore comes from the protocol extension, which is the only thing
/// the four default tests above are entitled to be describing.
///
/// Everything else is inert by design. If a future assertion in this suite needs
/// this double to DO something, that assertion belongs in a different suite.
@MainActor
private final class DefaultsOnlyAudioCapture: AudioCaptureInterface {
  var isCapturing: Bool = false
  var audioLevel: Float = 0
  var capturedSamples: [Float] = []
  var currentAudioRoute: String = "built_in_mic"
  var currentResolvedRoute: ResolvedRouteTransports?
  var onBufferCaptured: (@Sendable (AVAudioPCMBuffer) -> Void)?
  var onEngineInterrupted: ((EngineInterruptionCause) -> Void)?
  var onVADAutoStop: (() -> Void)?
  var onMaxDurationReached: (() -> Void)?
  var onCaptureStalled: ((CaptureStallContext) -> Void)?
  var onRouteResolved: ((CaptureRouteDecision, _ sourceTypeChanged: Bool) -> Void)?
  var currentCaptureSessionID: UInt64 = 0
  var isActivelyCapturing: Bool = false
  var captureSourceType: String = "defaults_only_stub"
  var selectedInputDeviceUID: String = ""
  var preferredInputDeviceIDOverride: String = ""
  var warmEnginePolicy: WarmEnginePolicy = .off

  func startEnginePhase() async throws {}
  func beginCapturePhase(recoveryPayload: Data?) async throws -> AsyncStream<AVAudioPCMBuffer> {
    AsyncStream { $0.finish() }
  }
  func startCapture() async throws -> AsyncStream<AVAudioPCMBuffer> {
    AsyncStream { $0.finish() }
  }
  func stopCapture() async -> CaptureResult { CaptureResult(samples: []) }
  func rebuildEngine() {}
  func retireCapturingSource(sessionID: UInt64) -> ZeroSignalRetireResult { .sourceNotRunning }
  func preWarm() async throws {}
  func abortPreWarm() {}
  func waitForFormatStabilization(maxWait: TimeInterval, pollInterval: TimeInterval) async -> Bool {
    true
  }
  func configureVAD(autoStop: Bool, silenceTimeout: Double, sensitivity: Float, energyGate: Bool) {}
  func getSamplesSnapshot(fromIndex: Int) async -> (samples: [Float], totalCount: Int) { ([], 0) }
  func getVADSegments() async -> [SpeechSegment] { [] }
}
