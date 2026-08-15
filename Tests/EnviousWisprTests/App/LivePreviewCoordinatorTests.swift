@preconcurrency import AVFoundation
import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprAppKit
@testable import EnviousWisprAudio
@testable import EnviousWisprServices

/// #1988 — the live preview's limb contract.
///
/// These tests deliberately do NOT drive Apple's recognizer. Building a
/// `SpeechAnalyzer` needs macOS 26, a reserved locale and possibly a model
/// download, none of which belong in a unit test and none of which the CI runner
/// has. What IS unit-testable is the part that protects the heart: the gate that
/// decides whether any of that happens at all, and the bound on what the feature
/// retains. Live behaviour is covered by UAT.
@MainActor
struct LivePreviewCoordinatorTests {

  // MARK: - The gate

  @Test("Disabled: the preview stays off and never reads the audio buffer")
  func disabledNeverTouchesAudio() async {
    let capture = CountingAudioCapture()
    let coordinator = LivePreviewCoordinator(
      audioCapture: capture,
      isEnabled: { false },
      languageMode: { .locked("en") }
    )

    coordinator.setRecording(true)
    #expect(coordinator.display == .off)

    // This asserts a NEGATIVE (no feed loop was started), and there is no signal
    // to wait on for something that must never happen. The paired
    // `enabledStartsAndLeavesOff` test is the control proving the start path
    // works, so a vacuous pass here would be caught there.
    // settle: proving absence; a started loop polls every 100 ms so it could not hide inside this window
    try? await Task.sleep(for: .milliseconds(250))
    #expect(
      capture.snapshotCallCount == 0,
      "a disabled preview must not read captured audio at all")
    #expect(coordinator.display == .off)
  }

  /// The two-way control for the test above. Without it, `disabledNeverTouchesAudio`
  /// would pass just as happily against a coordinator whose start path was broken
  /// or deleted, which is the shape of a vacuous guard test.
  @Test("Enabled: the start path runs and the pill leaves the off state")
  func enabledStartsAndLeavesOff() {
    let coordinator = LivePreviewCoordinator(
      audioCapture: CountingAudioCapture(),
      isEnabled: { true },
      languageMode: { .locked("en") }
    )

    coordinator.setRecording(true)
    // Set synchronously by `setRecording`, before any async work, so this holds on
    // every macOS version including ones where the recognizer cannot exist.
    #expect(coordinator.display == .waiting)
  }

  @Test("A new recording never opens showing the previous one's words")
  func startClearsPreviousText() {
    let coordinator = LivePreviewCoordinator(
      audioCapture: CountingAudioCapture(),
      isEnabled: { true },
      languageMode: { .locked("en") }
    )
    coordinator.setRecording(true)
    coordinator.setRecording(false)
    #expect(coordinator.display == .waiting)

    coordinator.setRecording(true)
    #expect(
      coordinator.display == .waiting,
      "the next press must reset the pill before its panel is created")
  }

  @Test("Stop is safe before any start, and start is safe twice")
  func lifecycleIsIdempotent() {
    let coordinator = LivePreviewCoordinator(
      audioCapture: CountingAudioCapture(),
      isEnabled: { true },
      languageMode: { .locked("en") }
    )
    // Two call sites push recording intent (the first overlay push and every
    // state-driven one), and `hide()` reports a stop that may already have
    // happened. All the orders below occur in practice.
    coordinator.setRecording(false)
    coordinator.setRecording(true)
    coordinator.setRecording(true)
    coordinator.setRecording(false)
    coordinator.setRecording(false)
    #expect(coordinator.display != .off)
  }

  // MARK: - Language policy

  @Test("A locked language previews in that language; Auto follows the system")
  func languagePolicy() {
    #expect(LivePreviewCoordinator.previewLanguageCode(.locked("de")) == "de")
    let auto = LivePreviewCoordinator.previewLanguageCode(.auto)
    let system = Locale.current.language.languageCode?.identifier ?? "en"
    #expect(auto == system)
    #expect(auto.isEmpty == false)
  }

  // MARK: - Bounding

  @Test("Short text is returned untouched")
  func shortTextUnbounded() {
    let text = "the quick brown fox"
    #expect(LivePreviewTextBound.apply(text) == text)
  }

  @Test("Long text keeps the tail, drops the head, and does not cut a word in half")
  func longTextKeepsTail() {
    // The pill shows the newest words, so the END is the part that must survive.
    let long = String(repeating: "alpha ", count: 1000)  // 6000 characters
    let bounded = LivePreviewTextBound.apply(long)

    #expect(bounded.count <= LivePreviewTextBound.maxCharacters)
    #expect(bounded.isEmpty == false)
    #expect(long.hasSuffix(bounded), "the retained text must be a suffix of the original")
    #expect(
      bounded.hasPrefix("alpha"),
      "trimming must land on a word boundary, not mid-word")
  }

  @Test("Bounding a string with no spaces still bounds it")
  func boundingWithoutWordBoundaries() {
    // A CJK sentence carries no spaces, and neither does a pathological URL. The
    // word-boundary step must not be able to turn the bound off.
    let long = String(repeating: "語", count: 5000)
    let bounded = LivePreviewTextBound.apply(long)
    #expect(bounded.count <= LivePreviewTextBound.maxCharacters)
    #expect(long.hasSuffix(bounded))
  }

  /// The bound is idempotent, which is what lets the producer apply it on every
  /// update without the text creeping.
  @Test("Applying the bound twice changes nothing the second time")
  func boundIsIdempotent() {
    let long = String(repeating: "alpha ", count: 1000)
    let once = LivePreviewTextBound.apply(long)
    #expect(LivePreviewTextBound.apply(once) == once)
  }

  // MARK: - Shipped default

  @Test("Live preview ships off")
  func shipsOff() {
    // Off by default is the founder-approved shipped state: it costs screen
    // attention some users explicitly asked to be able to decline, and it needs
    // macOS 26, so on by default would read as broken on every older Mac.
    #expect(SettingsDefaultValues.livePreviewEnabled == false)
  }
}

/// #1988 — counts reads of the capture buffer so a test can assert that a disabled
/// preview performs none.
@MainActor
private final class CountingAudioCapture: AudioCaptureInterface {
  private(set) var snapshotCallCount = 0

  var isCapturing: Bool = false
  var audioLevel: Float = 0
  var capturedSamples: [Float] = []
  var currentAudioRoute: String = "built_in_mic"
  var currentResolvedRoute: ResolvedRouteTransports? = nil
  var onBufferCaptured: (@Sendable (AVAudioPCMBuffer) -> Void)?
  var onEngineInterrupted: ((EngineInterruptionCause) -> Void)?
  var onVADAutoStop: (() -> Void)?
  var onMaxDurationReached: (() -> Void)?
  var onCaptureStalled: ((CaptureStallContext) -> Void)?
  var onRouteResolved: ((CaptureRouteDecision, _ sourceTypeChanged: Bool) -> Void)?
  var currentCaptureSessionID: UInt64 = 0
  var isActivelyCapturing: Bool = false
  var captureSourceType: String = "hal_device_input"
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
  func stopCapture(sessionID: UInt64) async -> CaptureResult { CaptureResult(samples: []) }
  func rebuildEngine() {}
  func retireCapturingSource(sessionID: UInt64) -> ZeroSignalRetireResult { .sourceNotRunning }
  func preWarm() async throws {}
  func abortPreWarm() {}
  func waitForFormatStabilization(maxWait: TimeInterval, pollInterval: TimeInterval) async -> Bool {
    true
  }
  func configureVAD(autoStop: Bool, silenceTimeout: Double, sensitivity: Float, energyGate: Bool) {}
  func getSamplesSnapshot(fromIndex: Int) async -> (samples: [Float], totalCount: Int) {
    snapshotCallCount += 1
    return ([], 0)
  }
  func getVADSegments() async -> [SpeechSegment] { [] }
}
