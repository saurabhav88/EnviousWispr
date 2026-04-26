@preconcurrency import AVFoundation
import AppKit
import EnviousWisprASR
import EnviousWisprAudio
import EnviousWisprCore
import EnviousWisprStorage
import Foundation
import Testing

@testable import EnviousWisprPipeline

@MainActor
@Suite("Heart Path Integration — Finalizer layer (mocked ASR + paste)")
struct HeartPathIntegrationTests {
  // Scope note. The tests in this file exercise `TranscriptFinalizer` with
  // mocked ASR and paste boundaries, plus one true `TranscriptionPipeline`
  // cancellation test. The full pipeline heart-path (audio capture through
  // delivery) cannot be exercised end-to-end until `TranscriptionPipeline`
  // gains DI seams for the finalizer and paste executor (#394).
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
          text: "hello world",
          language: "en",
          duration: fixture.durationSeconds,
          processingTime: 0.04,
          backendType: .parakeet
        )
      )
    )
    let pasteSink = CapturingPasteSink()
    let polish = MockPolishStep(mode: .success("Hello, world."))

    let harness = HeartPathHarness(
      audioCapture: audioCapture,
      asrManager: asrManager,
      pasteSink: pasteSink,
      steps: [polish]
    )

    let result = try await harness.run()

    #expect(audioCapture.loadedSampleCount == 16_000)
    #expect(asrManager.transcribeCallCount == 1)
    #expect(asrManager.lastTranscribedSampleCount == 16_000)

    #expect(result.usedASRFallback == false)
    #expect(result.finalization.transcript.text == "hello world")
    #expect(result.finalization.transcript.polishedText == "Hello, world.")
    #expect(result.finalization.transcript.displayText == "Hello, world.")
    #expect(result.finalization.polishError == nil)

    #expect(pasteSink.pastedTexts == ["Hello, world. "])
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

    let pipeline = TranscriptionPipeline(
      audioCapture: audioCapture,
      asrManager: asrManager,
      transcriptStore: TranscriptStore()
    )
    #expect(pipeline.currentSessionConfig == nil)

    let config = DictationSessionConfig.testDefault(
      autoPasteToActiveApp: true,
      vadSensitivity: 0.73,
      languageMode: .locked("fr"),
      llmProvider: .openAI,
      llmModel: "gpt-test"
    )
    await pipeline.startRecording(config: config)

    // Phase B freeze contract: the pipeline captures the config handed in by
    // AppState, and external readers see the frozen snapshot for the
    // recording's lifetime.
    let captured = pipeline.currentSessionConfig
    #expect(captured?.autoPasteToActiveApp == true)
    #expect(captured?.vadSensitivity == 0.73)
    #expect(captured?.languageMode == LanguageMode.locked("fr"))
    #expect(captured?.llmProvider == LLMProvider.openAI)
    #expect(captured?.llmModel == "gpt-test")

    let reachedRecording = await pollUntil(timeout: .seconds(1)) {
      pipeline.state == .recording
    }
    #expect(reachedRecording)

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
          text: "hello world",
          language: "en",
          duration: fixture.durationSeconds,
          processingTime: 0.03,
          backendType: .parakeet
        )
      )
    )
    let pasteSink = CapturingPasteSink()
    let polish = MockPolishStep(mode: .failure(MockFailure.polishOffline))

    let harness = HeartPathHarness(
      audioCapture: audioCapture,
      asrManager: asrManager,
      pasteSink: pasteSink,
      steps: [polish]
    )

    let result = try await harness.run()

    #expect(result.usedASRFallback == false)
    #expect(result.finalization.transcript.text == "hello world")
    #expect(result.finalization.transcript.polishedText == nil)
    #expect(result.finalization.transcript.displayText == "hello world")
    #expect(result.finalization.polishError == MockFailure.polishOffline.localizedDescription)
    #expect(pasteSink.pastedTexts == ["hello world "])
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
          text: "hello world",
          language: "en",
          duration: fixture.durationSeconds,
          processingTime: 0.03,
          backendType: .parakeet
        )
      )
    )
    let pasteSink = CapturingPasteSink()
    let polish = MockPolishStep(
      maxDuration: .milliseconds(50),
      mode: .sleepThenSuccess(.milliseconds(250), "Hello, world.")
    )

    let harness = HeartPathHarness(
      audioCapture: audioCapture,
      asrManager: asrManager,
      pasteSink: pasteSink,
      steps: [polish]
    )

    let result = try await harness.run()

    #expect(result.usedASRFallback == false)
    #expect(result.finalization.transcript.text == "hello world")
    #expect(result.finalization.transcript.polishedText == nil)
    #expect(result.finalization.transcript.displayText == "hello world")
    #expect(
      result.finalization.polishError
        == TimeoutError(seconds: 0.05).localizedDescription
    )
    #expect(pasteSink.pastedTexts == ["hello world "])
  }
}

// MARK: - Harness

@MainActor
private struct HeartPathHarnessResult {
  let finalization: FinalizationResult
  let usedASRFallback: Bool
}

@MainActor
private final class HeartPathHarness {
  private let audioCapture: FixtureAudioCapture
  private let asrManager: MockASRManager
  private let pasteSink: CapturingPasteSink
  private let steps: [any TextProcessingStep]

  init(
    audioCapture: FixtureAudioCapture,
    asrManager: MockASRManager,
    pasteSink: CapturingPasteSink,
    steps: [any TextProcessingStep]
  ) {
    self.audioCapture = audioCapture
    self.asrManager = asrManager
    self.pasteSink = pasteSink
    self.steps = steps
  }

  func run() async throws -> HeartPathHarnessResult {
    try await audioCapture.startEnginePhase()
    _ = try await audioCapture.beginCapturePhase()
    let captureResult = await audioCapture.stopCapture()

    let duration = Double(captureResult.samples.count) / AudioConstants.sampleRate

    let asrResult = try await asrManager.transcribe(
      audioSamples: captureResult.samples,
      options: .default
    )

    let finalizer = TranscriptFinalizer(
      save: { _ in },
      deliverPaste: { [pasteSink] request in
        await pasteSink.deliver(request)
      }
    )

    let finalization = try await finalizer.finalize(
      FinalizationRequest(
        asrText: asrResult.text,
        language: asrResult.language,
        duration: duration,
        processingTime: asrResult.processingTime,
        backendType: asrResult.backendType,
        targetApp: nil,
        targetElement: nil,
        autoCopyToClipboard: false,
        autoPasteToActiveApp: true,
        restoreClipboardAfterPaste: false,
        steps: steps
      )
    )

    return HeartPathHarnessResult(
      finalization: finalization,
      usedASRFallback: false
    )
  }
}

// MARK: - Fixture generation

private struct SyntheticAudioFixture {
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
private final class FixtureAudioCapture: AudioCaptureInterface {
  var isCapturing: Bool = false
  var audioLevel: Float = 0
  var capturedSamples: [Float] = []
  var currentAudioRoute: String = "synthetic-fixture"
  var onBufferCaptured: (@Sendable (AVAudioPCMBuffer) -> Void)?
  var onEngineInterrupted: (() -> Void)?
  var onVADAutoStop: (() -> Void)?
  var onCaptureStalled: ((CaptureStallContext) -> Void)?
  var onCaptureSessionInterruption: ((CaptureSessionInterruptionContext) -> Void)?
  var onXPCServiceError: ((XPCErrorContext) -> Void)?
  var onXPCReplyFailed: ((XPCReplyFailureContext) -> Void)?
  var onRouteResolved: ((CaptureRouteDecision, _ sourceTypeChanged: Bool) -> Void)?
  var currentCaptureSessionID: UInt64 = 0
  var isActivelyCapturing: Bool = false
  var captureSourceType: String = "fixture_mock"
  var noiseSuppressionEnabled: Bool = false
  var selectedInputDeviceUID: String = ""
  var preferredInputDeviceIDOverride: String = ""
  var warmEnginePolicy: WarmEnginePolicy = .off

  private let loadedSamples: [Float]
  private(set) var startEnginePhaseCallCount = 0
  private(set) var beginCapturePhaseCallCount = 0
  private(set) var stopCaptureCallCount = 0

  var loadedSampleCount: Int { loadedSamples.count }

  init(fixtureURL: URL) throws {
    self.loadedSamples = try Self.readSamples(from: fixtureURL)
    self.audioLevel = loadedSamples.reduce(0) { max($0, abs($1)) }
  }

  func startEnginePhase() async throws {
    startEnginePhaseCallCount += 1
  }

  func beginCapturePhase() async throws -> AsyncStream<AVAudioPCMBuffer> {
    beginCapturePhaseCallCount += 1
    currentCaptureSessionID += 1
    isCapturing = true
    isActivelyCapturing = true
    capturedSamples = loadedSamples
    return AsyncStream { continuation in
      continuation.finish()
    }
  }

  func startCapture() async throws -> AsyncStream<AVAudioPCMBuffer> {
    try await startEnginePhase()
    return try await beginCapturePhase()
  }

  func stopCapture() async -> CaptureResult {
    stopCaptureCallCount += 1
    isCapturing = false
    isActivelyCapturing = false
    return CaptureResult(
      samples: loadedSamples,
      vadSegments: [SpeechSegment(startSample: 0, endSample: loadedSamples.count)]
    )
  }

  func rebuildEngine() {}
  func buildEngine(noiseSuppression: Bool) {}

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
private final class MockASRManager: ASRManagerInterface {
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

  private let transcribeBehavior: TranscribeBehavior
  private(set) var transcribeCallCount = 0
  private(set) var lastTranscribedSampleCount: Int?

  init(transcribeBehavior: TranscribeBehavior) {
    self.transcribeBehavior = transcribeBehavior
  }

  func loadModel() async throws {}
  func loadModelSilently() async {}
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
}

@MainActor
private final class CapturingPasteSink {
  private(set) var pastedTexts: [String] = []

  func deliver(_ request: PasteDeliveryRequest) async -> PasteDeliveryResult {
    pastedTexts.append(request.text)
    return PasteDeliveryResult(
      tier: .cgEvent,
      durationMs: 1,
      outcome: .delivered(tier: .cgEvent, durationMs: 1)
    )
  }
}

@MainActor
private final class MockPolishStep: TextProcessingStep {
  enum Mode {
    case success(String)
    case failure(Error)
    case sleepThenSuccess(Duration, String)
  }

  let name = "LLM Polish"
  let isEnabled = true
  let maxDuration: Duration
  let errorSurfacePolicy: ErrorSurfacePolicy = .surface

  private let mode: Mode

  init(
    maxDuration: Duration = .seconds(5),
    mode: Mode
  ) {
    self.maxDuration = maxDuration
    self.mode = mode
  }

  func process(_ context: TextProcessingContext) async throws -> TextProcessingContext {
    switch mode {
    case .success(let polished):
      var next = context
      next.polishedText = polished
      next.llmProvider = "mock"
      next.llmModel = "mock-polisher"
      return next

    case .failure(let error):
      throw error

    case .sleepThenSuccess(let delay, let polished):
      try await Task.sleep(for: delay)
      var next = context
      next.polishedText = polished
      next.llmProvider = "mock"
      next.llmModel = "mock-polisher"
      return next
    }
  }
}

// MARK: - Helpers

private enum FixtureError: Error {
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

@MainActor
private func pollUntil(
  timeout: Duration,
  interval: Duration = .milliseconds(10),
  condition: @escaping @MainActor () -> Bool
) async -> Bool {
  let deadline = ContinuousClock.now + timeout
  while ContinuousClock.now < deadline {
    if condition() {
      return true
    }
    try? await Task.sleep(for: interval)
  }
  return condition()
}

/*
FINDINGS

1. Missing injection seam in `TranscriptionPipeline`:
   `TranscriptionPipeline.init(...)` constructs its own `TranscriptFinalizer`, and that
   finalizer owns the only clean paste seam (`deliverPaste`) plus the real text-processing
   runner. That prevents a true pipeline-level integration test from injecting a mock paste
   executor or alternate LLM step through the orchestrator itself. This file uses a small
   harness around real `TranscriptFinalizer` to cover those behaviors.

2. Heart-path contract mismatch in `TranscriptionPipeline.stopAndTranscribe()`:
   a thrown ASR error currently lands in the outer `catch` and sets
   `.error("Transcription failed: ...")` without any fallback paste. That contradicts the
   stated requirement that the heart path never fails and should still deliver something.

3. Heart-vs-limb ambiguity in `TranscriptFinalizer.finalize(...)`:
   `emptyAfterProcessing` is terminal. If ASR fallback is allowed to degrade to an empty
   string, the finalizer rejects it. The spec needs to decide whether empty string is valid
   heart-path output or whether a documented sentinel is required.

4. Existing brittleness in `TextProcessingRunner`:
   polish failure surfacing is keyed off the literal step name `"LLM Polish"`, not a typed
   capability. Renaming the step changes user-visible degradation behavior.

5. Observable coverage gap for real pipeline cancellation:
   cancellation is testable through `TranscriptionPipeline`, but paste non-occurrence is only
   indirectly observable today because the paste path is not injectable at the pipeline layer.
*/
