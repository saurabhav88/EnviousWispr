import EnviousWisprCore
import Foundation

@testable import EnviousWisprASR
@testable import EnviousWisprPipeline

// MARK: - StubWhisperKitBackend (epic #827, PR-5 Rung 3 §11.2)
//
// Configurable test double for the `WhisperKitBackendDriving` actor-bound
// protocol declared in `WhisperKitEngineAdapter.swift`. Lets
// `WhisperKitEngineAdapterTests` drive the adapter without loading a real
// WhisperKit model. The actor-bound seam means this stub must itself be an
// `actor` (the protocol declares `: Actor`).
//
// Members mirror the protocol surface 1:1. Configurable behavior knobs +
// observed counters follow the `StubParakeetASRManager` shape.

actor StubWhisperKitBackend: WhisperKitBackendDriving {

  // MARK: Configurable behavior

  /// Drives the synchronous `readiness` cache in the adapter through the
  /// protocol's `isReady` getter. The adapter refreshes `cachedReadiness`
  /// from this value on every transition.
  var isReady = false
  var modelVariantName: String = "stub-whisperkit-large-v3"
  /// #1275: stub for the warm-up-inference duration read. Defaults nil
  /// (matches a fresh backend before any load's warm-up completes).
  var lastWarmupInferenceMs: Int?
  var prepareThrows: (any Error)?
  var prepareIfCachedThrows: (any Error)?
  var prepareIfCachedResult: Bool = true
  var transcribeThrows: (any Error)?
  var transcribeResult: ASRResult = ASRResult(
    text: "stub-transcribed",
    language: "en",
    duration: 1,
    processingTime: 0.1,
    backendType: .whisperKit
  )
  var observeLIDResult: LIDObservationBatch = .observations([])
  /// When set, `makeStreamingSession` returns this session; otherwise nil
  /// (mirrors the "model not loaded" path). #1276 PR-2.
  var streamingSessionFactory: (@Sendable () -> (any WhisperKitIncrementalSession)?)?

  /// When set, `transcribe(...)` yields N times before returning — models a
  /// decode suspended in WhisperKit while a new session begins.
  var slowTranscribe = false

  // MARK: Observed counters

  var prepareCount = 0
  var prepareIfCachedCount = 0
  var transcribeCount = 0
  var lastTranscribeSamples: [Float] = []
  var lastTranscribeOptions: TranscriptionOptions = .default
  var observeLIDCount = 0
  var makeStreamingSessionCount = 0
  var unloadCount = 0

  // Signal-based waiter for `transcribeCount`. Tests await
  // `waitForTranscribeCount(1)` to know `finalize` reached the (suspended)
  // transcribe path, instead of yield-polling — actor isolation makes the
  // check + install atomic; the timeout net guarantees resolution (#875).
  private var transcribeWaiters = CountWaiters("transcribeCount")

  // MARK: Setters (callable from MainActor tests)

  func setIsReady(_ v: Bool) { isReady = v }
  func setTranscribeResult(_ v: ASRResult) { transcribeResult = v }
  func setTranscribeThrows(_ v: (any Error)?) { transcribeThrows = v }
  func setObserveLIDResult(_ v: LIDObservationBatch) { observeLIDResult = v }
  func setStreamingSessionFactory(
    _ v: (@Sendable () -> (any WhisperKitIncrementalSession)?)?
  ) {
    streamingSessionFactory = v
  }
  func setSlowTranscribe(_ v: Bool) { slowTranscribe = v }
  func setPrepareIfCachedResult(_ v: Bool) { prepareIfCachedResult = v }
  func setPrepareIfCachedThrows(_ v: (any Error)?) { prepareIfCachedThrows = v }
  func setPrepareThrows(_ v: (any Error)?) { prepareThrows = v }

  // MARK: WhisperKitBackendDriving

  func prepare() async throws {
    prepareCount += 1
    if let err = prepareThrows { throw err }
    isReady = true
  }

  func prepareIfCached() async throws -> Bool {
    prepareIfCachedCount += 1
    if let err = prepareIfCachedThrows { throw err }
    if prepareIfCachedResult { isReady = true }
    return prepareIfCachedResult
  }

  func transcribe(audioSamples: [Float], options: TranscriptionOptions) async throws
    -> ASRResult
  {
    transcribeCount += 1
    transcribeWaiters.notify(reached: transcribeCount)
    lastTranscribeSamples = audioSamples
    lastTranscribeOptions = options
    if slowTranscribe {
      for _ in 0..<200 { await Task.yield() }
    }
    if let err = transcribeThrows { throw err }
    return transcribeResult
  }

  /// Await until `transcribeCount >= target`. Resolves immediately if already
  /// reached; always resolves within `timeout`.
  func waitForTranscribeCount(_ target: Int, timeout: Duration = .seconds(5)) async {
    if transcribeCount >= target { return }
    let id = UUID()
    let timeoutTask = Task { [weak self] in
      try? await Task.sleep(for: timeout)
      await self?.resumeTranscribeWaiter(id)
    }
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      transcribeWaiters.install(id: id, target: target, continuation)
    }
    timeoutTask.cancel()
  }

  private func resumeTranscribeWaiter(_ id: UUID) { transcribeWaiters.resume(id: id) }

  func observeLID(samples: [Float], maxWindows: Int) async -> LIDObservationBatch {
    observeLIDCount += 1
    return observeLIDResult
  }


  func makeStreamingSession(options: TranscriptionOptions) async
    -> (any WhisperKitIncrementalSession)?
  {
    makeStreamingSessionCount += 1
    return streamingSessionFactory?()
  }

  /// #959: when set, `unload()` blocks (models a wedged in-process CoreML
  /// teardown) so a test can prove `recoverFromWedge()` is deadline-bounded.
  var hangUnload = false
  func setHangUnload(_ v: Bool) { hangUnload = v }

  func unload() async {
    unloadCount += 1
    if hangUnload {
      // Wedged: `withDeadline` abandons + cancels this task at its deadline.
      try? await Task.sleep(for: .seconds(60))
      return
    }
    isReady = false
  }
}

// MARK: - StubIncrementalSession

/// Configurable test double for `WhisperKitIncrementalSession`. The adapter
/// holds a session as an existential; tests inject this stub via the
/// backend's `incrementalSessionFactory` to control accepted-vs-rejected
/// worker results.
actor StubIncrementalSession: WhisperKitIncrementalSession {
  var finalizeResult: IncrementalResult
  var startCount = 0
  var finalizeCount = 0
  var cancelCount = 0
  /// When set, `finalize(...)` yields N times before returning — models a
  /// worker decode suspended while a new session begins.
  var slowFinalize = false

  // Signal-based waiter for `cancelCount` — the orphan-worker cancel runs in a
  // detached task off `beginSession`, so tests await `waitForCancelCount(1)`
  // instead of yield-polling (#875).
  private var cancelWaiters = CountWaiters("cancelCount")

  init(result: IncrementalResult) {
    self.finalizeResult = result
  }

  func setFinalizeResult(_ v: IncrementalResult) { finalizeResult = v }
  func setSlowFinalize(_ v: Bool) { slowFinalize = v }

  func start(
    audioSamplesProvider: @Sendable @escaping () async -> (samples: [Float], count: Int)
  ) async {
    startCount += 1
  }

  func finalize(
    finalSamples: [Float],
    speechSegments: [SpeechSegment]
  ) async -> IncrementalResult {
    finalizeCount += 1
    if slowFinalize {
      for _ in 0..<200 { await Task.yield() }
    }
    return finalizeResult
  }

  func cancel() async {
    cancelCount += 1
    cancelWaiters.notify(reached: cancelCount)
  }

  /// Await until `cancelCount >= target`. Resolves immediately if already
  /// reached; always resolves within `timeout`.
  func waitForCancelCount(_ target: Int, timeout: Duration = .seconds(5)) async {
    if cancelCount >= target { return }
    let id = UUID()
    let timeoutTask = Task { [weak self] in
      try? await Task.sleep(for: timeout)
      await self?.resumeCancelWaiter(id)
    }
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      cancelWaiters.install(id: id, target: target, continuation)
    }
    timeoutTask.cancel()
  }

  private func resumeCancelWaiter(_ id: UUID) { cancelWaiters.resume(id: id) }
}

// MARK: - IncrementalResult convenience constructors

extension IncrementalResult {
  static func accepted(text: String, decodeCount: Int = 1) -> IncrementalResult {
    IncrementalResult(
      text: text,
      samplesCovered: 16000,
      decodeCount: decodeCount,
      totalDecodeTimeMs: 100,
      accepted: true,
      mode: "stub-mode",
      strategy: "stub-strategy",
      tailDecodeMs: 0
    )
  }

  static func rejected(stopWhileDecodeInFlight: Bool = false) -> IncrementalResult {
    IncrementalResult(
      text: nil,
      samplesCovered: 0,
      decodeCount: 0,
      totalDecodeTimeMs: 0,
      accepted: false,
      mode: "stub-mode",
      strategy: "stub-strategy",
      tailDecodeMs: 0,
      stopWhileDecodeInFlight: stopWhileDecodeInFlight
    )
  }
}

enum StubBackendError: Error, Sendable {
  case prepareFailed
  case decodeFailed
}
