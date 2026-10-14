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
/// without the claim recovery waits on; or a cancelled take reads the engine as idle while
/// the native decode still runs, so the next take or an unload enters under it.
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

  /// One take: begin, feed `samples`, mark them speech, finalize.
  private func take(
    _ adapter: WhisperEngineAdapter, language: String?, streaming: Bool,
    samples: [Float] = [Float](repeating: 0.1, count: 16_000)
  ) async throws -> ASREngineOutcome {
    let sid = SessionID()
    try await adapter.beginSession(
      sid, options: TranscriptionOptions(language: language), streaming: streaming)
    feed(adapter, samples: samples, session: sid)
    adapter.observeSpeechSegments([SpeechSegment(startSample: 0, endSample: samples.count)])
    return await adapter.finalize(batchSamples: nil)
  }

  @Test("Faster Transcription on, locked language: the rolling session's flush is the transcript")
  func lockedStreamingUsesTheRollingSession() async throws {
    let driver = AdapterFakeDriver()
    driver.setRun(
      TranscribeCppRunResult(
        text: " hola mundo", detectedLanguage: nil,
        segments: [TranscribeCppSegment(startMs: 0, endMs: 900, text: " hola mundo")]))
    let adapter = WhisperEngineAdapter(
      backend: makeBackend(driver), engineMutationScope: .alwaysAllowedForTesting)
    try await adapter.warmUp(modelReceipt: nil)

    let outcome = try await take(adapter, language: "es", streaming: true)
    guard case .transcript(let result) = outcome else {
      Issue.record("expected .transcript, got \(outcome)")
      return
    }
    #expect(result.text == "hola mundo")
    #expect(result.language == "es")
    #expect(driver.decodeLanguages == [nil, "es"], "the warm-up, then the session's one flush")
    let diag = adapter.lastASRDiagnostics
    #expect(diag?.streamingEffective == true)
    #expect(diag?.streamingDegradeReason == "none")
    #expect(diag?.streamingFinalPath == "streaming_flush")
    #expect(adapter.lastLanguageDetection?.tier == .locked, "locked-language evidence kept")
  }

  @Test("Faster Transcription on with Auto-detect stays one batch decode, with segment timings")
  func autoLanguageStaysBatch() async throws {
    let driver = AdapterFakeDriver()
    driver.setRun(
      TranscribeCppRunResult(
        text: " hello there", detectedLanguage: "en",
        segments: [TranscribeCppSegment(startMs: 0, endMs: 900, text: " hello there")]))
    let adapter = WhisperEngineAdapter(
      backend: makeBackend(driver), engineMutationScope: .alwaysAllowedForTesting)
    try await adapter.warmUp(modelReceipt: nil)

    let outcome = try await take(adapter, language: nil, streaming: true)
    guard case .transcript(let result) = outcome else {
      Issue.record("expected .transcript, got \(outcome)")
      return
    }
    #expect(result.text == "hello there")
    #expect(result.segmentTimings == [ASRSegmentTiming(range: 0..<11, startMs: 0, endMs: 900)])
    let diag = adapter.lastASRDiagnostics
    #expect(diag?.streamingEffective == false)
    #expect(diag?.streamingDegradeReason == "auto_language")
    #expect(diag?.streamingFinalPath == "clean_batch")
  }

  @Test("an empty streaming flush falls back to the clean batch decode of the whole recording")
  func emptyFlushFallsBackToBatch() async throws {
    let driver = AdapterFakeDriver()
    driver.setRun(
      TranscribeCppRunResult(
        text: " hola mundo", detectedLanguage: nil,
        segments: [TranscribeCppSegment(startMs: 0, endMs: 900, text: " hola mundo")]))
    let adapter = WhisperEngineAdapter(
      backend: makeBackend(driver), engineMutationScope: .alwaysAllowedForTesting)
    try await adapter.warmUp(modelReceipt: nil)
    // The flush decodes to nothing; the batch fallback that follows gets the real text.
    driver.enqueue([TranscribeCppRunResult(text: "", detectedLanguage: nil, segments: [])])

    let outcome = try await take(adapter, language: "es", streaming: true)
    guard case .transcript(let result) = outcome else {
      Issue.record("expected .transcript, got \(outcome)")
      return
    }
    #expect(result.text == "hola mundo")
    #expect(driver.decodeLanguages == [nil, "es", "es"], "warm-up, empty flush, batch fallback")
    let diag = adapter.lastASRDiagnostics
    #expect(diag?.streamingDegradeReason == "flush_empty")
    #expect(diag?.streamingFinalPath == "fallback_batch")
  }

  @Test("the streaming flush counts as engine occupancy through the native return")
  func streamingFlushIsOccupancy() async throws {
    let driver = AdapterFakeDriver()
    let occupancy = VendorDecodeOccupancy()
    let adapter = WhisperEngineAdapter(
      backend: makeBackend(driver), engineMutationScope: .alwaysAllowedForTesting,
      vendorDecodeOccupancy: occupancy)
    try await adapter.warmUp(modelReceipt: nil)
    driver.holdNative()
    let pending = Task { try await take(adapter, language: "es", streaming: true) }
    await driver.waitUntilNativeEntered()
    #expect(occupancy.inFlight == 1)
    await driver.releaseNative()
    _ = try await pending.value
    #expect(occupancy.isIdle)
  }

  @Test("a cancelled take keeps the engine counted busy until the native decode returns")
  func cancelledTakeHoldsOccupancyUntilNativeReturn() async throws {
    let driver = AdapterFakeDriver()
    let backend = makeBackend(driver)
    let occupancy = VendorDecodeOccupancy()
    let adapter = WhisperEngineAdapter(
      backend: backend, engineMutationScope: .alwaysAllowedForTesting,
      vendorDecodeOccupancy: occupancy)
    try await adapter.warmUp(modelReceipt: nil)

    let sid = SessionID()
    try await adapter.beginSession(
      sid, options: TranscriptionOptions(language: "es"), streaming: false)
    feed(adapter, samples: [Float](repeating: 0.1, count: 16_000), session: sid)
    adapter.observeSpeechSegments([SpeechSegment(startSample: 0, endSample: 16_000)])
    driver.holdNative()
    let take = Task { await adapter.finalize(batchSamples: nil) }
    await driver.waitUntilNativeEntered()
    #expect(occupancy.inFlight == 1)
    take.cancel()
    // The executor released the caller; the backend now waits for the aborted native run.
    await driver.waitUntilDrainWaiting()
    #expect(occupancy.inFlight == 1, "busy while the native decode runs after the cancel")
    await driver.releaseNative()
    _ = await take.value
    #expect(occupancy.isIdle)
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

/// A fake executor driver. Calls return at once unless `holdNative()` is set: then a decode's
/// "native" work waits for `releaseNative()`, and a cancelled caller is released at once with
/// `.cancelled` while that work keeps running, as the real executor does.
private final class AdapterFakeDriver: WhisperExecutorDriving, @unchecked Sendable {
  typealias Handle = Int
  private let lock = NSLock()
  private var run = TranscribeCppRunResult(text: "ok", detectedLanguage: "en", segments: [])
  private var _languages: [String?] = []
  private var _unloaded: [Int] = []
  private var nativeGate: AsyncGate?
  private var nativeRunning = false
  private var drainWaiters: [CheckedContinuation<Void, Never>] = []
  private let entered = AsyncGate()
  private let drainWaiting = AsyncGate()

  func holdNative() { lock.withLock { nativeGate = AsyncGate() } }
  func releaseNative() async { await lock.withLock { nativeGate }?.open() }
  func waitUntilNativeEntered() async { await entered.wait() }
  func waitUntilDrainWaiting() async { await drainWaiting.wait() }

  func setRun(_ result: TranscribeCppRunResult) { lock.withLock { run = result } }
  /// Results returned in order by the next decodes, before falling back to `run`.
  private var queued: [TranscribeCppRunResult] = []
  func enqueue(_ results: [TranscribeCppRunResult]) { lock.withLock { queued += results } }
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
    let (gate, result) = lock.withLock { () -> (AsyncGate?, TranscribeCppRunResult) in
      _languages.append(language)
      if nativeGate != nil { nativeRunning = true }
      return (nativeGate, queued.isEmpty ? run : queued.removeFirst())
    }
    guard let gate else { return result }
    let caller = CallerRelease()
    Task {
      await gate.wait()
      let waiters = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
        nativeRunning = false
        defer { drainWaiters = [] }
        return drainWaiters
      }
      for waiter in waiters { waiter.resume() }
      caller.finish(cancelled: false)
    }
    await entered.open()
    // The caller leaves at once on cancel; the "native" task keeps running until released.
    let cancelled = await withTaskCancellationHandler {
      await caller.wait()
    } onCancel: {
      caller.finish(cancelled: true)
    }
    if cancelled { throw TranscribeCppExecutor.ExecutorError.cancelled }
    return result
  }

  func waitForDrain(_ handle: Int) async {
    await withCheckedContinuation { continuation in
      let idle = lock.withLock { () -> Bool in
        guard nativeRunning else { return true }
        drainWaiters.append(continuation)
        return false
      }
      if idle { continuation.resume() } else { Task { await drainWaiting.open() } }
    }
  }

  func unload(_ handle: Int) async { lock.withLock { _unloaded.append(handle) } }
}

/// One-shot: the first `finish` decides whether the caller saw a cancel or the native return.
private final class CallerRelease: @unchecked Sendable {
  private let lock = NSLock()
  private var outcome: Bool?
  private var waiter: CheckedContinuation<Bool, Never>?

  func finish(cancelled: Bool) {
    let resume = lock.withLock { () -> CheckedContinuation<Bool, Never>? in
      guard outcome == nil else { return nil }
      outcome = cancelled
      defer { waiter = nil }
      return waiter
    }
    resume?.resume(returning: cancelled)
  }

  func wait() async -> Bool {
    await withCheckedContinuation { continuation in
      let ready = lock.withLock { () -> Bool? in
        if let outcome { return outcome }
        waiter = continuation
        return nil
      }
      if let ready { continuation.resume(returning: ready) }
    }
  }
}
