@preconcurrency import AVFoundation
import AppKit
import EnviousWisprAudio
import EnviousWisprCore
import EnviousWisprLLM
import EnviousWisprServices
import EnviousWisprStorage
import Foundation
import Testing

@testable import EnviousWisprASR
@testable import EnviousWisprPipeline

@MainActor
@Suite("Heart Path Integration — Finalizer layer (mocked ASR + paste)", .tags(.productOutcome))
struct HeartPathIntegrationTests {
  // Scope note. The tests in this file exercise `KernelFinalizationWiring` with
  // mocked ASR and paste boundaries, plus one true the old Parakeet pipeline
  // cancellation test.
  //
  // This note used to say end-to-end coverage was blocked on #394. **#394 CLOSED 2026-04-20** and nobody
  // returned, so the claim sat here for four months asserting a blocker that no longer existed — which is
  // how the #2141 audit found the suite at ZERO tests crossing a real boundary while carrying 5,801
  // tests. When you clear a blocker, grep for the tests that named it.
  // Real-boundary coverage is now tracked work, NOT a blocked state: see
  // `.claude/rules/testing-philosophy.md` RULE: the-heart-crosses-a-real-boundary-at-least-once.
  // These four remain correct and useful at what they do; they are not, and never were, proof that
  // dictation works.
  //
  // Do NOT add tests here that claim graceful ASR-failure degradation —
  // production currently terminates with .error on ASR failure (#392), and a
  // harness that smuggles in fallback text produces test theater rather
  // than coverage.

  @Test("happy path: fixture -> ASR -> polish -> paste")
  func happyPathFixtureToPolishToPaste() async throws {
    let fixture = try SyntheticAudioFixture.make(
      fileName: "heart-path-happy.wav",
      pattern: .toneBurst
    )

    let audioCapture = try FixtureAudioCapture(fixtureURL: fixture.url)
    let asrManager = MockASRManager(
      transcribeBehavior: .success(
        ASRResult(
          text: "hello world this is a test",
          language: "en",
          duration: fixture.durationSeconds,
          processingTime: 0.04,
          backendType: .parakeet
        )
      )
    )
    let pasteSink = CapturingPasteSink()
    let harness = HeartPathHarness(
      audioCapture: audioCapture,
      asrManager: asrManager,
      pasteSink: pasteSink,
      polisher: FixedPolisher(polished: "Hello, world. This is a test.")
    )

    let result = try await harness.run()

    #expect(audioCapture.loadedSampleCount == 16_000)
    #expect(asrManager.transcribeCallCount == 1)
    #expect(asrManager.lastTranscribedSampleCount == 16_000)

    #expect(result.usedASRFallback == false)
    #expect(result.outcome.transcript?.text == "hello world this is a test")
    #expect(result.outcome.transcript?.polishedText == "Hello, world. This is a test.")
    // ASR metadata must reach the stored transcript through the same adapter.
    #expect(result.outcome.transcript?.language == "en")
    #expect(result.outcome.transcript?.duration == fixture.durationSeconds)
    #expect(result.outcome.transcript?.processingTime == 0.04)
    #expect(result.outcome.transcript?.displayText == "Hello, world. This is a test.")
    #expect(result.outcome.polishError == nil)

    // Exact legacy payload, trailing space appended exactly once.
    #expect(pasteSink.pastedTexts == ["Hello, world. This is a test. "])
  }

  @Test("early cancellation: recording starts, pipeline cancels, no transcript or paste path runs")
  func earlyCancellationDoesNotCrashOrDeliver() async throws {
    let fixture = try SyntheticAudioFixture.make(
      fileName: "heart-path-cancel.wav",
      pattern: .toneBurst
    )

    let audioCapture = try FixtureAudioCapture(fixtureURL: fixture.url)
    let asrManager = MockASRManager(
      transcribeBehavior: .success(
        ASRResult(
          text: "should never be used",
          language: "en",
          duration: fixture.durationSeconds,
          processingTime: 0.02,
          backendType: .parakeet
        )
      )
    )

    let vad = KernelDictationDriverFactory.makeSharedVADSignalSource(
      audioCapture: audioCapture)
    let pipeline = KernelDictationDriverFactory.makeForParakeet(
      inputs: .init(
        audioCapture: audioCapture,
        asrManager: asrManager,
        vadSignalSource: vad,
        transcriptStore: TranscriptStore(),
        keychainManager: KeychainManager(),
        captureTelemetry: CaptureTelemetryState(),
        pasteCompletionRegistry: PasteCompletionRegistry(),
        engineMutationScope: .alwaysAllowedForTesting
      ))
    let stateWaiter = PipelineStateWaiter(pipeline)
    #expect(pipeline.currentSessionConfig == nil)

    let config = DictationSessionConfig.testDefault(
      autoPasteToActiveApp: true,
      vadSensitivity: 0.73,
      languageMode: .locked("fr"),
      llmProvider: .openAI,
      llmModel: "gpt-test"
    )
    try await pipeline.handle(event: .toggleRecording(config))

    // Phase B freeze contract: the pipeline captures the config handed in by
    // the former root state, and external readers see the frozen snapshot for the
    // recording's lifetime.
    let captured = pipeline.currentSessionConfig
    #expect(captured?.autoPasteToActiveApp == true)
    #expect(captured?.vadSensitivity == 0.73)
    #expect(captured?.languageMode == LanguageMode.locked("fr"))
    #expect(captured?.llmProvider == LLMProvider.openAI)
    #expect(captured?.llmModel == "gpt-test")

    await stateWaiter.wait(for: .recording)
    #expect(pipeline.state == .recording)

    await pipeline.cancelRecording()

    #expect(pipeline.state == .idle)
    #expect(pipeline.currentTranscript == nil)
    #expect(asrManager.transcribeCallCount == 0)
    #expect(audioCapture.stopCaptureCallCount == 1)
    #expect(audioCapture.isCapturing == false)
  }

  @Test("polish failure degrades to raw ASR output")
  func polishFailureFallsBackToRawASR() async throws {
    let fixture = try SyntheticAudioFixture.make(
      fileName: "heart-path-polish-failure.wav",
      pattern: .toneBurst
    )

    let audioCapture = try FixtureAudioCapture(fixtureURL: fixture.url)
    let asrManager = MockASRManager(
      transcribeBehavior: .success(
        ASRResult(
          text: "hello world this is a test",
          language: "en",
          duration: fixture.durationSeconds,
          processingTime: 0.03,
          backendType: .parakeet
        )
      )
    )
    let pasteSink = CapturingPasteSink()
    let harness = HeartPathHarness(
      audioCapture: audioCapture,
      asrManager: asrManager,
      pasteSink: pasteSink,
      polisher: ThrowingPolisher(error: MockFailure.polishOffline)
    )

    let result = try await harness.run()

    #expect(result.usedASRFallback == false)
    #expect(result.outcome.transcript?.text == "hello world this is a test")
    #expect(result.outcome.transcript?.polishedText == nil)
    #expect(result.outcome.transcript?.displayText == "hello world this is a test")
    // The live path maps a limb failure to USER-FACING copy. The retired seam
    // surfaced the raw error description, so this mapping was never covered.
    #expect(
      result.outcome.polishError
        == "AI polish failed: an unexpected error stopped it. Your original text was pasted unchanged."
    )
    #expect(pasteSink.pastedTexts == ["hello world this is a test "])
  }

  @Test("polish timeout degrades to raw ASR output")
  func polishTimeoutFallsBackToRawASR() async throws {
    let fixture = try SyntheticAudioFixture.make(
      fileName: "heart-path-polish-timeout.wav",
      pattern: .toneBurst
    )

    let audioCapture = try FixtureAudioCapture(fixtureURL: fixture.url)
    let asrManager = MockASRManager(
      transcribeBehavior: .success(
        ASRResult(
          text: "hello world this is a test",
          language: "en",
          duration: fixture.durationSeconds,
          processingTime: 0.03,
          backendType: .parakeet
        )
      )
    )
    let pasteSink = CapturingPasteSink()
    // #794: the mock's 50ms `maxDuration` becomes a 0.05s budget; the
    // 0.1 discriminator throws `TimeoutError` for it deterministically,
    // so the test no longer races the mock's 250ms sleep against a real
    // wall clock. The `.sleepThenSuccess` body never runs — the fake
    // intercepts before `op()`.
    let harness = HeartPathHarness(
      audioCapture: audioCapture,
      asrManager: asrManager,
      pasteSink: pasteSink,
      polisher: FixedPolisher(polished: "Hello, world. This is a test."),
      // The real `.openAI` polish budget is 5s. A 6s discriminator throws
      // TimeoutError for it before the polisher body runs — deterministic, no
      // wall clock, no sleep.
      textProcessingRunner: finalizerRunner(throwBelowSeconds: 6)
    )

    let result = try await harness.run()

    #expect(result.usedASRFallback == false)
    #expect(result.outcome.transcript?.text == "hello world this is a test")
    #expect(result.outcome.transcript?.polishedText == nil)
    #expect(result.outcome.transcript?.displayText == "hello world this is a test")
    // The real step's `.openAI` budget is 5s; the fake executor throws for any
    // budget below 6s, so polish times out deterministically with no wall clock.
    // The live path maps a timeout to its own user-facing copy, distinct from
    // the generic failure message above.
    #expect(
      result.outcome.polishError
        == "AI cleanup skipped: the dictation took too long. Your original text was pasted unchanged."
    )
    #expect(pasteSink.pastedTexts == ["hello world this is a test "])
  }
}

// MARK: - Harness

@MainActor
private struct HeartPathHarnessResult {
  /// The live wiring's side-channel — the same object the kernel reads.
  let outcome: KernelFinalizationOutcome
  let usedASRFallback: Bool
}

/// A `TextProcessingRunner` whose timeout executor is deterministic.
///
/// #794 (2026-05-19): the default `TextProcessingRunner()` delegates to the
/// real `withThrowingTimeout`, which races a wall clock. On a contended CI
/// runner a polish step's 5s budget can expire and the runner silently
/// degrades to raw ASR text — a false failure unrelated to the test's
/// intent. `throwBelowSeconds: 0.0` never throws (every step runs);
/// `throwBelowSeconds: 0.1` discriminates a 50ms slow-step budget from the
/// 5s default so the `polishTimeoutFallsBackToRawASR` test can exercise the
/// real timeout-degradation path deterministically.
@MainActor
private func finalizerRunner(throwBelowSeconds: Double = 0.0) -> TextProcessingRunner {
  TextProcessingRunner(
    timeoutExecutor: FakeTimeoutExecutor(throwBelowSeconds: throwBelowSeconds).run)
}

private enum HeartPathHarnessError: Error {
  case unexpectedASROutcome
}

/// Drives the REAL `KernelFinalizationWiring` closures — process, store,
/// deliver — over a fixture audio file and a mocked ASR boundary.
///
/// It deliberately does not reimplement finalization. The old harness used a
/// production-dead test seam, so its assertions did not exercise shipped
/// behaviour. Running the live wiring means a regression in the real delivery
/// path fails here.
///
/// Polish is a real `LLMPolishStep` with an injected polisher, so the chain,
/// its ordering, and its fallback behaviour are production code.
@MainActor
private final class HeartPathHarness {
  private let audioCapture: FixtureAudioCapture
  private let asrManager: MockASRManager
  private let pasteSink: CapturingPasteSink
  private let polisher: (any TranscriptPolisher)?
  private let textProcessingRunner: TextProcessingRunner

  init(
    audioCapture: FixtureAudioCapture,
    asrManager: MockASRManager,
    pasteSink: CapturingPasteSink,
    polisher: (any TranscriptPolisher)?,
    textProcessingRunner: TextProcessingRunner = finalizerRunner()
  ) {
    self.audioCapture = audioCapture
    self.asrManager = asrManager
    self.pasteSink = pasteSink
    self.polisher = polisher
    self.textProcessingRunner = textProcessingRunner
  }

  func run() async throws -> HeartPathHarnessResult {
    try await audioCapture.startEnginePhase()
    _ = try await audioCapture.beginCapturePhase()
    let captureResult = await audioCapture.stopCapture(
      sessionID: audioCapture.currentCaptureSessionID)

    // ONE adapter drives both transcription and the wiring, so the stored
    // language, duration and processing time come from the same result the
    // test asserts. Transcribing separately and handing the wiring a different
    // adapter silently disconnects that metadata.
    let adapter = ParakeetEngineAdapter(asrManager: asrManager)
    try await adapter.beginSession(SessionID(), options: .default, streaming: false)
    let asrResult: ASRResult
    switch await adapter.finalize(batchSamples: captureResult.samples) {
    case .transcript(let result): asrResult = result
    default: throw HeartPathHarnessError.unexpectedASROutcome
    }

    let polishStep = LLMPolishStep(keychainManager: KeychainManager())
    // `.openAI` only selects the 5 s budget and enables the step; the injected
    // polisher replaces the connector entirely, so no key or network is used.
    polishStep.llmProvider = .openAI
    if let polisher {
      polishStep.makePolisher = { _, _, _ in polisher }
    }

    let outcome = KernelFinalizationOutcome()
    outcome.asrStartedAtSeconds = 0
    outcome.asrEndedAtSeconds = asrResult.processingTime

    let context = KernelSessionContext()
    context.config = .testDefault(autoPasteToActiveApp: true)

    let wiring = KernelFinalizationWiring(
      outcome: outcome,
      context: context,
      adapter: adapter,
      steps: LimbSteps(
        wordCorrection: WordCorrectionStep(),
        fillerRemoval: FillerRemovalStep(),
        emojiFormatter: EmojiFormatterStep(),
        inverseTextNormalization: InverseTextNormalizationStep(),
        llmPolish: polishStep,
        emojiRestore: EmojiRestoreStep()),
      textProcessingRunner: textProcessingRunner,
      save: { _ in },
      deliverPaste: { [pasteSink] request in
        await pasteSink.deliver(request)
      },
      pasteCompletionRegistry: nil,
      currentTime: { 0 },
      telemetryState: KernelTelemetryState())

    // The live order the kernel uses: process, then store, then deliver.
    let displayText = try await wiring.processText(asrResult.text) {}
    try await wiring.store(displayText, UUID())
    _ = await wiring.deliver(displayText)

    return HeartPathHarnessResult(outcome: outcome, usedASRFallback: false)
  }
}

// MARK: - Fixture generation

internal struct SyntheticAudioFixture {
  let url: URL
  let durationSeconds: TimeInterval

  enum Pattern {
    case toneBurst
    case silence
  }

  static func make(
    fileName: String,
    pattern: Pattern,
    sampleRate: Int = 16_000,
    durationSeconds: TimeInterval = 1.0
  ) throws -> SyntheticAudioFixture {
    let frameCount = Int(Double(sampleRate) * durationSeconds)

    let samples: [Float] =
      switch pattern {
      case .toneBurst:
        makeToneBurstSamples(frameCount: frameCount, sampleRate: sampleRate)
      case .silence:
        Array(repeating: 0, count: frameCount)
      }

    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString)
      .appendingPathComponent(fileName)

    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )

    try writeWAV(samples: samples, sampleRate: sampleRate, to: url)

    return SyntheticAudioFixture(url: url, durationSeconds: durationSeconds)
  }

  private static func makeToneBurstSamples(frameCount: Int, sampleRate: Int) -> [Float] {
    let silencePrefix = Int(Double(sampleRate) * 0.20)
    let toneFrames = Int(Double(sampleRate) * 0.60)
    let silenceSuffix = max(0, frameCount - silencePrefix - toneFrames)
    let frequency = 440.0
    let amplitude: Float = 0.35

    var result = Array(repeating: Float.zero, count: frameCount)

    for frame in 0..<toneFrames {
      let index = silencePrefix + frame
      let phase = 2.0 * Double.pi * frequency * Double(frame) / Double(sampleRate)
      result[index] = sin(Float(phase)) * amplitude
    }

    if silenceSuffix > 0 {
      let tailStart = silencePrefix + toneFrames
      for index in tailStart..<frameCount {
        result[index] = 0
      }
    }

    return result
  }

  private static func writeWAV(samples: [Float], sampleRate: Int, to url: URL) throws {
    let bitsPerSample: UInt16 = 16
    let channelCount: UInt16 = 1
    let bytesPerSample = Int(bitsPerSample / 8)
    let dataSize = UInt32(samples.count * bytesPerSample)
    let byteRate = UInt32(sampleRate) * UInt32(channelCount) * UInt32(bytesPerSample)
    let blockAlign = channelCount * UInt16(bytesPerSample)
    let riffSize = 36 + dataSize

    var data = Data()
    data.appendASCII("RIFF")
    data.appendLE(riffSize)
    data.appendASCII("WAVE")

    data.appendASCII("fmt ")
    data.appendLE(UInt32(16))
    data.appendLE(UInt16(1))
    data.appendLE(channelCount)
    data.appendLE(UInt32(sampleRate))
    data.appendLE(byteRate)
    data.appendLE(blockAlign)
    data.appendLE(bitsPerSample)

    data.appendASCII("data")
    data.appendLE(dataSize)

    for sample in samples {
      let clamped = max(-1, min(1, sample))
      let pcm = Int16(clamped * Float(Int16.max))
      data.appendLE(UInt16(bitPattern: pcm))
    }

    try data.write(to: url, options: .atomic)
  }
}

extension Data {
  fileprivate mutating func appendASCII(_ string: String) {
    append(contentsOf: string.utf8)
  }

  fileprivate mutating func appendLE(_ value: UInt16) {
    var little = value.littleEndian
    Swift.withUnsafeBytes(of: &little) { append(contentsOf: $0) }
  }

  fileprivate mutating func appendLE(_ value: UInt32) {
    var little = value.littleEndian
    Swift.withUnsafeBytes(of: &little) { append(contentsOf: $0) }
  }
}

// MARK: - Test doubles

@MainActor
internal final class FixtureAudioCapture: AudioCaptureInterface {
  var isCapturing: Bool = false
  var audioLevel: Float = 0
  var capturedSamples: [Float] = []
  var currentAudioRoute: String = "synthetic-fixture"
  var currentResolvedRoute: ResolvedRouteTransports? = nil
  var onBufferCaptured: (@Sendable (AVAudioPCMBuffer) -> Void)?
  var onEngineInterrupted: ((EngineInterruptionCause) -> Void)?
  var onVADAutoStop: (() -> Void)?
  var onMaxDurationReached: (() -> Void)?
  var onCaptureStalled: ((CaptureStallContext) -> Void)?
  var onRouteResolved: ((CaptureRouteDecision, _ sourceTypeChanged: Bool) -> Void)?
  var currentCaptureSessionID: UInt64 = 0
  var isActivelyCapturing: Bool = false
  var captureSourceType: String = "fixture_mock"
  var selectedInputDeviceUID: String = ""
  var preferredInputDeviceIDOverride: String = ""
  var warmEnginePolicy: WarmEnginePolicy = .off

  private let loadedSamples: [Float]
  private(set) var startEnginePhaseCallCount = 0
  private(set) var beginCapturePhaseCallCount = 0
  private(set) var stopCaptureCallCount = 0

  var loadedSampleCount: Int { loadedSamples.count }

  /// When true, `beginCapturePhase` delivers one buffer through
  /// `onBufferCaptured` so `bufferCountThisSession > 0`. Default false: no buffer,
  /// so the manager holds `loadedSamples` while the kernel count stays 0 — the
  /// salvage-preservation case (§3.7). A caller that needs a genuine capture-stall
  /// (async `.captureStall`, not the synchronous dead-mic `.noTransport`) opts in.
  private let deliverFirstBuffer: Bool

  init(fixtureURL: URL, deliverFirstBuffer: Bool = false) throws {
    self.loadedSamples = try Self.readSamples(from: fixtureURL)
    self.audioLevel = loadedSamples.reduce(0) { max($0, abs($1)) }
    self.deliverFirstBuffer = deliverFirstBuffer
  }

  static func makeSilentBuffer() -> AVAudioPCMBuffer? {
    guard
      let format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: AudioConstants.sampleRate,
        channels: AVAudioChannelCount(AudioConstants.channels),
        interleaved: false),
      let buffer = AVAudioPCMBuffer(
        pcmFormat: format, frameCapacity: AVAudioFrameCount(AudioConstants.captureBufferSize))
    else { return nil }
    buffer.frameLength = AVAudioFrameCount(AudioConstants.captureBufferSize)
    return buffer
  }

  func startEnginePhase() async throws {
    startEnginePhaseCallCount += 1
  }

  func beginCapturePhase(recoveryPayload: Data?) async throws -> AsyncStream<AVAudioPCMBuffer> {
    beginCapturePhaseCallCount += 1
    currentCaptureSessionID += 1
    isCapturing = true
    isActivelyCapturing = true
    capturedSamples = loadedSamples
    // #1548 D2: the forward path reaches `.live` sequentially once this returns —
    // no first-buffer delivery needed. The loaded samples above are the session's
    // audio (returned by `stopCapture()`), so salvage/decode still has real input.
    // Opt-in buffer delivery (see `deliverFirstBuffer`) bumps the kernel count for
    // callers that need a genuine capture-stall rather than a dead-mic no-transport.
    if deliverFirstBuffer, let buffer = Self.makeSilentBuffer() { onBufferCaptured?(buffer) }
    return AsyncStream { continuation in
      continuation.finish()
    }
  }

  func startCapture() async throws -> AsyncStream<AVAudioPCMBuffer> {
    try await startEnginePhase()
    return try await beginCapturePhase()
  }

  func stopCapture(sessionID: UInt64) async -> CaptureResult {
    stopCaptureCallCount += 1
    isCapturing = false
    isActivelyCapturing = false
    return CaptureResult(
      samples: loadedSamples,
      vadSegments: [SpeechSegment(startSample: 0, endSample: loadedSamples.count)]
    )
  }

  func rebuildEngine() {}
  func retireCapturingSource(sessionID: UInt64) -> ZeroSignalRetireResult { .sourceNotRunning }

  func preWarm() async throws {}

  func abortPreWarm() {
    isCapturing = false
    isActivelyCapturing = false
  }

  func waitForFormatStabilization(
    maxWait: TimeInterval,
    pollInterval: TimeInterval
  ) async -> Bool {
    true
  }

  func configureVAD(
    autoStop: Bool,
    silenceTimeout: Double,
    sensitivity: Float,
    energyGate: Bool
  ) {}

  func getSamplesSnapshot(fromIndex: Int) async -> (samples: [Float], totalCount: Int) {
    let safeIndex = max(0, min(fromIndex, loadedSamples.count))
    return (Array(loadedSamples.dropFirst(safeIndex)), loadedSamples.count)
  }

  func getVADSegments() async -> [SpeechSegment] {
    [SpeechSegment(startSample: 0, endSample: loadedSamples.count)]
  }

  private static func readSamples(from url: URL) throws -> [Float] {
    let data = try Data(contentsOf: url)

    guard data.count >= 44 else { throw FixtureError.malformedWAV }
    guard String(decoding: data[0..<4], as: UTF8.self) == "RIFF" else {
      throw FixtureError.malformedWAV
    }
    guard String(decoding: data[8..<12], as: UTF8.self) == "WAVE" else {
      throw FixtureError.malformedWAV
    }
    guard String(decoding: data[12..<16], as: UTF8.self) == "fmt " else {
      throw FixtureError.malformedWAV
    }
    guard String(decoding: data[36..<40], as: UTF8.self) == "data" else {
      throw FixtureError.malformedWAV
    }

    let bitsPerSample = Int(Self.readUInt16LE(from: data, offset: 34))
    let dataSize = Int(Self.readUInt32LE(from: data, offset: 40))

    guard bitsPerSample == 16 else { throw FixtureError.unsupportedFormat }
    guard data.count >= 44 + dataSize else { throw FixtureError.malformedWAV }

    let sampleCount = dataSize / 2
    var samples: [Float] = []
    samples.reserveCapacity(sampleCount)

    for sampleIndex in 0..<sampleCount {
      let offset = 44 + sampleIndex * 2
      let raw = Int16(bitPattern: Self.readUInt16LE(from: data, offset: offset))
      samples.append(Float(raw) / Float(Int16.max))
    }

    return samples
  }

  private static func readUInt16LE(from data: Data, offset: Int) -> UInt16 {
    let b0 = UInt16(data[offset])
    let b1 = UInt16(data[offset + 1]) << 8
    return b0 | b1
  }

  private static func readUInt32LE(from data: Data, offset: Int) -> UInt32 {
    let b0 = UInt32(data[offset])
    let b1 = UInt32(data[offset + 1]) << 8
    let b2 = UInt32(data[offset + 2]) << 16
    let b3 = UInt32(data[offset + 3]) << 24
    return b0 | b1 | b2 | b3
  }
}

@MainActor
internal final class MockASRManager: ASRManagerInterface {
  enum TranscribeBehavior {
    case success(ASRResult)
    case failure(Error)
  }

  var activeBackendType: ASRBackendType = .parakeet
  var isModelLoaded: Bool = true
  var isStreaming: Bool = false
  var downloadProgress: Double = 1
  var downloadPhase: String = "ready"
  var downloadDetail: String = ""
  var onServiceInterrupted: (() -> Void)?
  var loadProgressTickReporter: (@MainActor @Sendable (Date?, String) -> Void)?

  private let transcribeBehavior: TranscribeBehavior
  private(set) var transcribeCallCount = 0
  private(set) var lastTranscribedSampleCount: Int?

  init(transcribeBehavior: TranscribeBehavior) {
    self.transcribeBehavior = transcribeBehavior
  }

  func loadModel() async throws {}
  func unloadModel() async {}
  func setInitialBackendType(_ type: ASRBackendType) { activeBackendType = type }
  func switchBackend(to type: ASRBackendType) async { activeBackendType = type }

  var activeBackendSupportsStreaming: Bool {
    get async { false }
  }

  func transcribe(
    audioSamples: [Float],
    options: TranscriptionOptions
  ) async throws -> ASRResult {
    transcribeCallCount += 1
    lastTranscribedSampleCount = audioSamples.count

    switch transcribeBehavior {
    case .success(let result):
      return result
    case .failure(let error):
      throw error
    }
  }

  func startStreaming(options: TranscriptionOptions) async throws {
    throw MockFailure.unexpectedStreaming
  }

  func feedAudio(_ buffer: AVAudioPCMBuffer) async throws {
    throw MockFailure.unexpectedStreaming
  }

  func finalizeStreaming() async throws -> ASRResult {
    throw MockFailure.unexpectedStreaming
  }

  func cancelStreaming() async {}
  func noteTranscriptionComplete(policy: ModelUnloadPolicy) {}
  func cancelIdleTimer() {}
  func cancelInFlightLoad() {}
}

@MainActor
private final class CapturingPasteSink {
  private(set) var pastedTexts: [String] = []

  func deliver(_ request: PasteDeliveryRequest) async -> PasteDeliveryResult {
    pastedTexts.append(request.legacyText)
    return PasteDeliveryResult(
      tier: .cgEvent,
      durationMs: 1,
      outcome: .delivered(tier: .cgEvent, durationMs: 1)
    )
  }
}

@MainActor
/// Returns a fixed polished string. Replaces the whole connector, so no key,
/// no network, no wall clock.
private struct FixedPolisher: TranscriptPolisher {
  let polished: String
  func polish(
    text: String,
    instructions: PolishInstructions,
    config: LLMProviderConfig,
    onToken: (@Sendable (String) -> Void)?
  ) async throws -> LLMResult {
    LLMResult(polishedText: polished)
  }
}

/// Fails every polish. The chain must surface the error and deliver raw text.
private struct ThrowingPolisher: TranscriptPolisher {
  let error: any Error
  func polish(
    text: String,
    instructions: PolishInstructions,
    config: LLMProviderConfig,
    onToken: (@Sendable (String) -> Void)?
  ) async throws -> LLMResult {
    throw error
  }
}

// MARK: - Helpers

internal enum FixtureError: Error {
  case malformedWAV
  case unsupportedFormat
}

private enum MockFailure: LocalizedError, Equatable {
  case asrUnavailable
  case polishOffline
  case unexpectedStreaming

  var errorDescription: String? {
    switch self {
    case .asrUnavailable:
      return "ASR backend unavailable"
    case .polishOffline:
      return "Mock polish failed"
    case .unexpectedStreaming:
      return "Streaming should not be used in this integration test"
    }
  }
}

/*
FINDINGS

1. RESOLVED (#1785 Chunk 3). The old Parakeet pipeline constructed its own finalizer,
   which owned the only clean paste seam, so no pipeline-level test could inject a paste
   executor or an alternate polish path through the orchestrator. That seam became
   production-dead and is now deleted; this file's harness drives the real
   `KernelFinalizationWiring` closures, injecting only a polisher and a paste sink.

2. Heart-path contract mismatch in the old Parakeet pipeline's `stopAndTranscribe()`:
   a thrown ASR error currently lands in the outer `catch` and sets
   `.error(.asrFailed)` without any fallback paste. That contradicts the
   stated requirement that the heart path never fails and should still deliver something.

3. RESOLVED. The empty-output decision now lives in `RecordingSessionKernel`, which trims
   the chain result and finishes `.noSpeech(.emptyAfterProcessing)` BEFORE store or deliver
   runs — a quiet no-speech end, not a heart-path failure. The wiring layer passes the text
   through without inventing an error type.

4. Existing brittleness in `TextProcessingRunner`:
   polish failure surfacing is keyed off the literal step name `"LLM Polish"`, not a typed
   capability. Renaming the step changes user-visible degradation behavior.

5. Observable coverage gap for real pipeline cancellation:
   cancellation is testable through the old Parakeet pipeline, but paste non-occurrence is only
   indirectly observable today because the paste path is not injectable at the pipeline layer.
*/
