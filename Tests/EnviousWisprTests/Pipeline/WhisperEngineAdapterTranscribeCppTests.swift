@preconcurrency import AVFoundation
import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprASR
@testable import EnviousWisprPipeline
@testable import EnviousWisprTranscribeCpp

/// #3735 §3.4 / §3.2a: the Whisper adapter driving the transcribe.cpp backend.
///
/// **What the user sees when this fails:** with Faster Transcription on, a Whisper take returns
/// no text (the nil streaming vend is not degraded to batch); speaker timings vanish between the
/// engine and the document; or a memory-pressure unload frees the model during a take, or runs
/// without the claim recovery waits on.
@MainActor
@Suite("Whisper adapter over transcribe.cpp (#3735)", .serialized, .tags(.productOutcome))
struct WhisperEngineAdapterTranscribeCppTests {

  private typealias Backend = TranscribeCppWhisperBackend<AdapterFakeDriver>

  private func makeBackend(_ driver: AdapterFakeDriver) -> Backend {
    Backend(
      driver: driver, modelVariant: "whisper-large-v3-turbo-Q8_0",
      admittedModelPath: { "turbo.gguf" }, modelIdentity: nil, scopeDelivery: nil,
      authorizeUnload: nil, warmupDeadlineSeconds: 5)
  }

  private func feed(_ adapter: WhisperEngineAdapter, samples: [Float], session: SessionID) {
    guard let buffer = FakeAudioCapture.makeBuffer(samples: samples) else {
      Issue.record("failed to synthesize a test buffer")
      return
    }
    adapter.acceptAudio(
      AudioBufferHandoff(buffer: buffer, frameCount: samples.count, sequence: 1, sessionID: session)
    )
  }

  @Test(
    "Faster Transcription on, locked language: the nil streaming vend decodes once in batch, with segment timings"
  )
  func streamingRequestDegradesToBatch() async throws {
    let driver = AdapterFakeDriver()
    driver.setRun(
      TranscribeCppRunResult(
        text: " hola mundo", detectedLanguage: nil,
        segments: [TranscribeCppSegment(startMs: 0, endMs: 900, text: " hola mundo")]))
    let backend = makeBackend(driver)
    let adapter = WhisperEngineAdapter(
      backend: backend, engineMutationScope: .alwaysAllowedForTesting)
    try await adapter.warmUp(modelReceipt: nil)
    #expect(adapter.readiness == .ready)

    let sid = SessionID()
    try await adapter.beginSession(
      sid, options: TranscriptionOptions(language: "es"), streaming: true)
    feed(adapter, samples: [Float](repeating: 0.1, count: 16_000), session: sid)
    adapter.observeSpeechSegments([SpeechSegment(startSample: 0, endSample: 16_000)])
    let outcome = await adapter.finalize(batchSamples: nil)
    guard case .transcript(let result) = outcome else {
      Issue.record("expected .transcript, got \(outcome)")
      return
    }
    #expect(result.text == "hola mundo")
    #expect(result.language == "es", "a locked language is the forced hint")
    #expect(result.wordTimings == nil)
    #expect(result.segmentTimings == [ASRSegmentTiming(range: 0..<10, startMs: 0, endMs: 900)])
    #expect(driver.decodeLanguages == [nil, "es"], "the warm-up, then one batch decode")
    let diag = adapter.lastASRDiagnostics
    #expect(diag?.streamingEffective == false)
    #expect(diag?.streamingDegradeReason == "model_not_ready")
    #expect(diag?.streamingFinalPath == "clean_batch")
  }

  @Test(
    "memory pressure while idle unloads under the adapter's claim and marks the engine not ready")
  func pressureUnloadsUnderClaim() async throws {
    final class Claims: @unchecked Sendable {
      var begun = 0
      var ended = 0
    }
    let claims = Claims()
    let scope = EngineMutationScope.live(
      tryBegin: {
        claims.begun += 1
        return true
      },
      end: {
        claims.ended += 1
        return false
      },
      wake: {}, onRefused: { _ in })
    let driver = AdapterFakeDriver()
    let backend = makeBackend(driver)
    let adapter = WhisperEngineAdapter(backend: backend, engineMutationScope: scope)
    try await adapter.warmUp(modelReceipt: nil)
    await adapter.bindMemoryPressureUnload(to: backend)

    await backend.handleMemoryPressure()
    #expect(claims.begun == 1 && claims.ended == 1, "the claim is taken and released once")
    #expect(driver.unloaded == [1])
    #expect(adapter.readiness == .notReady)
    #expect(await backend.isReady == false)
  }

  @Test("a refused claim leaves the model loaded and the engine ready")
  func refusedClaimKeepsReadiness() async throws {
    let scope = EngineMutationScope.live(
      tryBegin: { false }, end: { false }, wake: {}, onRefused: { _ in })
    let driver = AdapterFakeDriver()
    let backend = makeBackend(driver)
    let adapter = WhisperEngineAdapter(backend: backend, engineMutationScope: scope)
    try await adapter.warmUp(modelReceipt: nil)
    await adapter.bindMemoryPressureUnload(to: backend)

    await backend.handleMemoryPressure()
    #expect(driver.unloaded.isEmpty)
    #expect(adapter.readiness == .ready)
    #expect(await backend.isReady)
  }

  @Test("memory pressure during a live session is refused under the claim; the model stays")
  func pressureRefusedDuringSession() async throws {
    let driver = AdapterFakeDriver()
    let backend = makeBackend(driver)
    let adapter = WhisperEngineAdapter(
      backend: backend, engineMutationScope: .alwaysAllowedForTesting)
    try await adapter.warmUp(modelReceipt: nil)
    await adapter.bindMemoryPressureUnload(to: backend)
    try await adapter.beginSession(SessionID(), options: .default, streaming: false)

    await backend.handleMemoryPressure()
    #expect(driver.unloaded.isEmpty)
    #expect(adapter.readiness == .ready)
    #expect(await backend.isReady)
  }
}

/// A non-blocking fake executor driver: every call returns at once.
private final class AdapterFakeDriver: WhisperExecutorDriving, @unchecked Sendable {
  typealias Handle = Int
  private let lock = NSLock()
  private var run = TranscribeCppRunResult(text: "ok", detectedLanguage: "en", segments: [])
  private var _languages: [String?] = []
  private var _unloaded: [Int] = []

  func setRun(_ result: TranscribeCppRunResult) { lock.withLock { run = result } }
  var decodeLanguages: [String?] { lock.withLock { _languages } }
  var unloaded: [Int] { lock.withLock { _unloaded } }

  func load(modelPath: String, lane: TranscribeCppExecutor.Lane) async throws -> Int { 1 }

  func detectLanguage(
    _ handle: Int, samples: [Float], lane: TranscribeCppExecutor.Lane
  ) async throws -> TranscribeCppLanguageObservation {
    TranscribeCppLanguageObservation(code: "en", logProb: -0.01)
  }

  func transcribe(
    _ handle: Int, samples: [Float], language: String?, lane: TranscribeCppExecutor.Lane,
    onInferenceEntered: (@Sendable () -> Void)?, onProgress: (@Sendable (Int64, Int64) -> Void)?
  ) async throws -> TranscribeCppRunResult {
    onInferenceEntered?()
    return lock.withLock {
      _languages.append(language)
      return run
    }
  }

  func waitForDrain(_ handle: Int) async {}

  func unload(_ handle: Int) async { lock.withLock { _unloaded.append(handle) } }
}
