import EnviousWisprCore
import Foundation

@testable import EnviousWisprPipeline

// MARK: - FakeEngine (epic #827, PR-2 plan §3.3, §3.8; PR-1 §B.2.3)
//
// The PR-2 conformer of `ASREngineAdapter`. It is both the test infrastructure
// and the hot-swap existence proof (epic §3.6): a new engine = one
// `ASREngineAdapter` conformer + one factory line. It uses no real ASR.
//
// Every MUST / MUST NOT clause in PR-1 §B.2.2 is honored and `FakeEngineTests`
// asserts each. Wedge semantics (PR-2 plan §3.3): the `wedge*` modes ship a
// NON-nil progress stream that simply goes silent — they do NOT use a nil
// stream. A nil stream (the `*ProgressAbsent` knobs) means the engine exposes
// no wedge signal at all. The two are distinct on purpose.

/// Ordered lifecycle events recorded by `FakeEngine` (PR-5 Rung 2B #827). The
/// kernel call-site behavioral tests assert ordering AND counts; counts alone
/// would silently accept a misplaced call.
enum FakeEngineEvent: Equatable, Sendable {
  case warmUp
  case warmUpFromCache
  case cancelPendingUnload
  case beginSession
  case acceptAudio
  case observeSpeechSegments(count: Int)
  case finalize
  case cancel
  case recoverFromWedge
}

/// Synthetic error type for the cache-preload failure-bypass test
/// (`warmUpFromCacheThrowsDoesNotBlockWarmUpOrRecording`).
enum FakeEngineCacheError: Error, Equatable, Sendable {
  case simulated
}

/// The nine `FakeEngine` behaviors (PR-1 §B.2.3).
enum FakeEngineBehavior: Sendable {
  /// Batch engine: `finalize()` returns one transcript.
  case batchSuccess(text: String)
  /// Streaming engine: emits partials, then a final transcript.
  case streamingSuccess(partials: [String], final: String)
  /// Decoder produced nothing.
  case empty(hadSpeechEvidence: Bool)
  /// `warmUp()` completes after `ticksToReady` logical clock ticks.
  case slowLoad(ticksToReady: Int)
  /// `finalize()` completes after `ticksToFinal` logical clock ticks, then
  /// returns one transcript. Models a transcribe that genuinely dwells —
  /// lets a scenario place a `cancel` deterministically inside `transcribing`
  /// (A8) without wedging (PR-3 plan §14a).
  case slowFinalize(ticksToFinal: Int, text: String)
  /// `warmUp()` emits a few load-progress ticks then goes silent — a genuine
  /// cadence stall the kernel's wedge watcher can detect (PR-3 plan §3.7).
  /// Resolved only by `cancel()` (best-effort load cancellation, D6).
  case wedgeOnLoad
  /// `finalize()` emits a few finalize-progress ticks then goes silent — a
  /// genuine finalize cadence stall (PR-3 plan §3.7). Resolved only by
  /// `cancel()`.
  case wedgeOnFinalize
  /// `finalize()` surfaces an engine crash as `.failed(.engineCrashed)` —
  /// never a throw, never a hang.
  case crashOnFinalize
  /// `finalize()` always returns `.cancelled`.
  case cancelled
  /// #1388: `warmUp()` throws the given error immediately — drives the
  /// driver's terminal-classification tests (cancel vs failure) with an
  /// exact error type instead of the wedge behaviors' `ASREngineError`.
  case failLoad(any Error & Sendable)
}

@MainActor
final class FakeEngine: ASREngineAdapter {
  /// `var` so a scenario's `EngineDirective.setBehavior` can reconfigure the
  /// fake before a session begins (e.g. the engine-switch scenarios).
  var behavior: FakeEngineBehavior

  /// Self-declared identity (PR-5 Rung 1). Settable so the engine-identity
  /// propagation sentinel test can construct a `FakeEngine` with `.whisperKit`
  /// and assert the kernel reads it back; defaults to `.parakeet` so existing
  /// scenarios assert byte-identical strings.
  var engineIdentity: ASREngineIdentity = ASREngineIdentity(backendType: .parakeet)

  /// Capabilities follow `behavior` — a `streamingSuccess` fake advertises
  /// `supportsStreaming`, so a kernel that branches on `capabilities` runs the
  /// A2 / A9 / A10 streaming scenarios through a genuinely streaming adapter.
  var capabilities: ASREngineCapabilities {
    switch behavior {
    case .streamingSuccess:
      return ASREngineCapabilities(supportsStreaming: true, supportsLanguageDetection: false)
    default:
      return ASREngineCapabilities(supportsStreaming: false, supportsLanguageDetection: false)
    }
  }

  private(set) var readiness: ASREngineReadiness = .notReady

  /// Mid-recording engine-crash callback (PR-4 §3.2). The kernel sets this
  /// during session setup; `fireEngineInterrupted()` lets a scenario simulate
  /// an ASR-service crash while recording.
  var onEngineInterrupted: (@MainActor () -> Void)?

  // MARK: Observed counters (for FakeEngineTests)

  private(set) var warmUpCallCount = 0
  private(set) var beginSessionCallCount = 0
  private(set) var acceptedBufferCount = 0
  private(set) var acceptAudioAfterTerminalCount = 0
  private(set) var finalizeCallCount = 0
  /// The `batchSamples:` value the most recent `finalize` call received
  /// (PR-4.5 #5) — lets seam tests assert the kernel passes conditioned
  /// audio through instead of `nil`.
  private(set) var lastFinalizeBatchSamples: [Float]? = nil
  private(set) var cancelCallCount = 0
  /// #959: counts `recoverFromWedge()` calls so seam tests can assert ordinary
  /// terminals route through cheap `cancel()` while only the wedge detectors
  /// route through heavy `recoverFromWedge()`.
  private(set) var recoverFromWedgeCallCount = 0
  private(set) var lastUnloadPolicy: ModelUnloadPolicy?
  private(set) var lastSessionID: SessionID?
  /// The `streaming` flag the kernel passed on the last `beginSession()` —
  /// lets a scenario assert the kernel's streaming-policy decision (PR-4 §3.4).
  private(set) var lastStreamingRequested: Bool?
  /// Count of mid-session engine-switch requests (A18). The request models a
  /// factory-preference change (PR-6 owns the factory); it does NOT mutate
  /// this engine's `behavior`, so the active session keeps its transcript.
  private(set) var midSessionSwitchRequestCount = 0

  // MARK: PR-5 Rung 2B (#827) — kernel call-site observation
  //
  // Counters + event log for the kernel's calls to the three optional adapter
  // hooks (`warmUpFromCache`, `cancelPendingUnload`, `observeSpeechSegments`).
  // The event log records ordered lifecycle events so the behavioral tests
  // assert position, not just count.

  private(set) var cancelPendingUnloadCallCount = 0
  private(set) var warmUpFromCacheCallCount = 0
  // Signal-based waiter for `warmUpFromCacheCallCount` — `preWarm` parks inside
  // `warmUpFromCache` (blocked on `warmUpFromCacheBlocker`), so the test can't
  // await the parked `preWarm` task. It awaits `waitForWarmUpFromCacheCount(1)`
  // instead of yield-polling the counter (#875).
  private var warmUpFromCacheWaiters = CountWaiters("warmUpFromCacheCallCount")
  private(set) var observeSpeechSegmentsCallCount = 0
  /// The segments argument from the most recent `observeSpeechSegments(_:)`
  /// call — lets VAD-source-precedence tests assert the kernel passes its own
  /// computed `vadSegments` array verbatim.
  private(set) var lastObservedSpeechSegments: [SpeechSegment]?

  /// Ordered log of lifecycle events the kernel triggers on this adapter. Used
  /// by the Rung 2B lifecycle-order tests; append from every adapter method.
  private(set) var eventLog: [FakeEngineEvent] = []

  /// When `true`, `warmUpFromCache()` throws `FakeEngineCacheError.simulated`
  /// AFTER incrementing its counter and appending its event. The
  /// failure-bypass test sets this to assert the kernel's `try?` swallow
  /// holds.
  var warmUpFromCacheThrows: Bool = false

  /// When set, `warmUpFromCache()` parks on this continuation until the test
  /// resumes it via `releaseWarmUpFromCacheBlocker()`. The post-await
  /// reentrancy guard test uses this to hold the preWarm continuation while
  /// a second session is minted.
  private var warmUpFromCacheBlocker: CheckedContinuation<Void, Never>?
  /// When `true`, the next `warmUpFromCache()` call parks on
  /// `warmUpFromCacheBlocker`. Test-only.
  var blockWarmUpFromCache: Bool = false

  /// Resume any pending `warmUpFromCacheBlocker` continuation (test-only).
  func releaseWarmUpFromCacheBlocker() {
    if let continuation = warmUpFromCacheBlocker {
      warmUpFromCacheBlocker = nil
      continuation.resume()
    }
  }

  /// Last successful finalize() result (PR-5 Rung 2A). `var` (not
  /// `private(set)`) so the metadata-propagation sentinel test can seed it
  /// from another file; the simulator already exposes `var behavior` the
  /// same way. Cleared in `beginSession()` and `cancel()`; assigned in
  /// `finalize(...)` only on `.transcript(...)`.
  var lastResult: ASRResult?

  /// Record a mid-session engine-switch request (A18, PR-3 plan §3.6). A
  /// no-op against the running adapter — proves the request was inert.
  func noteMidSessionSwitchRequest() {
    midSessionSwitchRequestCount += 1
  }

  // MARK: Terminal latch

  /// `true` once `cancel()` or `finalize()` has completed — `acceptAudio(_:)`
  /// after this is a no-op (PR-1 §B.2.2).
  private var isTerminal = false
  private var isCancelled = false

  // MARK: Progress streams

  private let clock: FakeClock
  /// `var` so a scenario's `EngineDirective.setLoadProgressAbsent` can model
  /// the nil-stream case (A19) without reconstructing the engine.
  var loadProgressAbsent: Bool
  var finalizeProgressAbsent: Bool

  private let loadStream: AsyncStream<ASRLoadProgressTick>
  private let loadContinuation: AsyncStream<ASRLoadProgressTick>.Continuation
  private let finalizeStream: AsyncStream<ASRFinalizeProgressTick>
  private let finalizeContinuation: AsyncStream<ASRFinalizeProgressTick>.Continuation
  private var loadMarker: UInt64 = 0
  private var finalizeMarker: UInt64 = 0

  /// `nil` when the engine exposes no load-progress stream — the kernel then
  /// does signal-free `warmingUp` (PR-1 §B.2.2).
  var loadProgress: AsyncStream<ASRLoadProgressTick>? {
    loadProgressAbsent ? nil : loadStream
  }

  /// #1339: the simulator opts in whenever it exposes a load stream so the
  /// driver topology tests can exercise guard arm/disarm without a real
  /// progress file (the guard never FIRES in tests — firing is watcher-level
  /// tested with a ManualClock).
  var warmupStallGuardEligible: Bool { !loadProgressAbsent }

  /// `nil` when the engine exposes no finalize-progress stream.
  var finalizeProgress: AsyncStream<ASRFinalizeProgressTick>? {
    finalizeProgressAbsent ? nil : finalizeStream
  }

  // MARK: Wedge continuations

  private var loadWedgeContinuation: CheckedContinuation<Void, Never>?
  private var finalizeWedgeContinuation: CheckedContinuation<Void, Never>?

  init(
    behavior: FakeEngineBehavior,
    clock: FakeClock,
    loadProgressAbsent: Bool = false,
    finalizeProgressAbsent: Bool = false
  ) {
    self.behavior = behavior
    self.clock = clock
    self.loadProgressAbsent = loadProgressAbsent
    self.finalizeProgressAbsent = finalizeProgressAbsent
    (loadStream, loadContinuation) = AsyncStream.makeStream(of: ASRLoadProgressTick.self)
    (finalizeStream, finalizeContinuation) = AsyncStream.makeStream(
      of: ASRFinalizeProgressTick.self)
  }

  // MARK: Warm-up

  func warmUp() async throws {
    warmUpCallCount += 1
    eventLog.append(.warmUp)
    // Idempotent: safe to call when already ready (PR-1 §B.2.2).
    if readiness == .ready { return }
    readiness = .warming
    switch behavior {
    case .slowLoad(let ticksToReady):
      await clock.sleep(ticks: ticksToReady)
      readiness = .ready
    case .wedgeOnLoad:
      // The load emits a few progress ticks (arming the kernel's wedge
      // watcher) then goes silent — a genuine cadence stall (PR-3 plan §3.7).
      // It suspends until `recoverFromWedge()` resumes us (#959: the kernel's
      // load-wedge detector calls that, not cheap `cancel()`); best-effort load
      // cancellation (D6): `warmUp()` throws once released.
      // If a discard ALREADY ran (cancel-before-warmUp ordering set `isCancelled`),
      // there is no future release to resume the continuation — parking would
      // hang. Throw immediately instead.
      if isCancelled { throw ASREngineError.wedged }
      emitLoadTick()
      emitLoadTick()
      await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        loadWedgeContinuation = continuation
      }
      throw ASREngineError.wedged
    case .failLoad(let error):
      readiness = .notReady
      throw error
    default:
      readiness = .ready
    }
  }

  /// Emit one load-progress tick (driven by a scenario's `emitLoadTick`).
  func emitLoadTick() {
    loadMarker += 1
    loadContinuation.yield(ASRLoadProgressTick(marker: loadMarker))
  }

  // MARK: Session lifecycle

  func beginSession(
    _ id: SessionID, options: TranscriptionOptions, streaming: Bool
  ) async throws {
    beginSessionCallCount += 1
    eventLog.append(.beginSession)
    lastSessionID = id
    lastStreamingRequested = streaming
    isTerminal = false
    isCancelled = false
    // Mirror the real Parakeet adapter's per-session reset
    // (`ParakeetEngineAdapter.swift:163`) — a fresh session should not inherit
    // a prior finalize's batchSamples snapshot in tests.
    lastFinalizeBatchSamples = nil
    // PR-5 Rung 2A: clear last finalize result so the new session starts
    // with no stale metadata, matching the Parakeet conformer.
    lastResult = nil
  }

  func acceptAudio(_ buffer: AudioBufferHandoff) {
    // A call after a terminal session MUST be a no-op (PR-1 §B.2.2).
    if isTerminal {
      acceptAudioAfterTerminalCount += 1
      return
    }
    acceptedBufferCount += 1
    eventLog.append(.acceptAudio)
  }

  func finalize(batchSamples: [Float]?) async -> ASREngineOutcome {
    finalizeCallCount += 1
    eventLog.append(.finalize)
    // `beginSession` resets this to nil so a fresh session sees nil if its
    // finalize is never reached — only the LAST finalize's value survives.
    lastFinalizeBatchSamples = batchSamples
    // After `cancel()`, `finalize()` MUST return `.cancelled` (PR-1 §B.2.2).
    if isCancelled {
      isTerminal = true
      return .cancelled
    }
    let outcome: ASREngineOutcome
    switch behavior {
    case .batchSuccess(let text):
      outcome = .transcript(makeResult(text: text))
    case .streamingSuccess(_, let final):
      outcome = .transcript(makeResult(text: final))
    case .empty(let hadSpeechEvidence):
      outcome = .empty(hadSpeechEvidence: hadSpeechEvidence)
    case .crashOnFinalize:
      // An engine crash surfaces as a VALUE, never a throw, never a hang.
      outcome = .failed(.engineCrashed)
    case .wedgeOnFinalize:
      // The finalize emits a few finalize-progress ticks (arming the kernel's
      // wedge watcher) then goes silent — a genuine cadence stall (PR-3 plan
      // §3.7). It suspends until `cancel()` resumes us; once released, returns
      // `.cancelled` per the post-cancel MUST clause.
      emitFinalizeTick()
      emitFinalizeTick()
      await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        finalizeWedgeContinuation = continuation
      }
      isTerminal = true
      return .cancelled
    case .slowFinalize(let ticksToFinal, let text):
      // `finalize()` dwells `ticksToFinal` logical ticks then returns — a
      // genuine in-flight `transcribing` window, no wedge (no progress
      // ticks are emitted, so no watcher arms).
      await clock.sleep(ticks: ticksToFinal)
      if isCancelled {
        isTerminal = true
        return .cancelled
      }
      outcome = .transcript(makeResult(text: text))
    case .cancelled:
      outcome = .cancelled
    case .slowLoad:
      // A slow load is a load-phase delay; once warm-up completes the engine
      // transcribes normally. Scenarios A3 / A19 model slow-warm-up-then-success
      // and must be able to finalize to a transcript.
      outcome = .transcript(makeResult(text: "transcribed after slow load"))
    case .wedgeOnLoad:
      // The load wedged; A4 cancels before finalize (handled by the
      // post-cancel branch above). A defensive finalize surfaces a load failure.
      outcome = .failed(.loadFailed)
    case .failLoad:
      // #1388: the load threw before any session could begin; a defensive
      // finalize surfaces a load failure (same stance as .wedgeOnLoad).
      outcome = .failed(.loadFailed)
    }
    isTerminal = true
    // PR-5 Rung 2A: honor the §4 contract, assigning only on .transcript(...).
    if case .transcript(let result) = outcome {
      lastResult = result
    }
    return outcome
  }

  /// Emit one finalize-progress tick (driven by a scenario's `emitFinalizeTick`).
  func emitFinalizeTick() {
    finalizeMarker += 1
    finalizeContinuation.yield(ASRFinalizeProgressTick(marker: finalizeMarker))
  }

  func cancel() async {
    cancelCallCount += 1
    eventLog.append(.cancel)
    // Idempotent — 2+ calls have the same effect as one (PR-1 §B.2.2).
    isCancelled = true
    isTerminal = true
    // PR-5 Rung 2A: cancellation invalidates any prior session's result.
    lastResult = nil
    // #959: cheap discard — it does NOT release a wedged `warmUp()`/`finalize()`.
    // The kernel only routes ordinary terminals here; releasing a wedge is the
    // job of `recoverFromWedge()` below.
  }

  /// #959 HEAVY wedge recovery. Does the same teardown as `cancel()` PLUS
  /// releasing any wedged `warmUp()` / `finalize()` continuation (best-effort,
  /// D6) — the behavior that used to live in `cancel()`. Tracked under its OWN
  /// counter (not `cancelCallCount`) so seam tests can assert routing: the
  /// kernel's load-wedge / finalize-wedge detectors call this; ordinary
  /// terminals call cheap `cancel()`.
  func recoverFromWedge() async {
    recoverFromWedgeCallCount += 1
    eventLog.append(.recoverFromWedge)
    isCancelled = true
    isTerminal = true
    lastResult = nil
    if let continuation = loadWedgeContinuation {
      loadWedgeContinuation = nil
      continuation.resume()
    }
    if let continuation = finalizeWedgeContinuation {
      finalizeWedgeContinuation = nil
      continuation.resume()
    }
  }

  func applyUnloadPolicy(_ policy: ModelUnloadPolicy) {
    lastUnloadPolicy = policy
  }

  // MARK: PR-5 Rung 2B (#827) — optional adapter hook overrides
  //
  // Override the three protocol-extension defaults so the behavioral tests
  // can assert the kernel call counts AND lifecycle ordering.

  func cancelPendingUnload() {
    cancelPendingUnloadCallCount += 1
    eventLog.append(.cancelPendingUnload)
  }

  func warmUpFromCache() async throws {
    warmUpFromCacheCallCount += 1
    warmUpFromCacheWaiters.notify(reached: warmUpFromCacheCallCount)
    eventLog.append(.warmUpFromCache)
    if blockWarmUpFromCache {
      await withCheckedContinuation {
        (continuation: CheckedContinuation<Void, Never>) in
        warmUpFromCacheBlocker = continuation
      }
    }
    if warmUpFromCacheThrows {
      throw FakeEngineCacheError.simulated
    }
  }

  /// Await until `warmUpFromCacheCallCount >= target`. Resolves immediately if
  /// already reached, else parks until `warmUpFromCache` is entered.
  ///
  /// PURE signal wait — NO wall-clock timeout net, because this file lives
  /// under `Simulator/` where `SimulatorWallClockBanTests` forbids any
  /// wall-clock sleep API (determinism rests on `FakeClock`). The signal is
  /// deterministic (`preWarm` always calls `warmUpFromCache`); were it ever to
  /// not arrive, the test hangs and surfaces as a loud CI job timeout — a
  /// visible failure, not the silent false-pass the timeout net guards against
  /// elsewhere.
  func waitForWarmUpFromCacheCount(_ target: Int) async {
    if warmUpFromCacheCallCount >= target { return }
    let id = UUID()
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      warmUpFromCacheWaiters.install(id: id, target: target, continuation)
    }
  }

  /// Most-recent `rawCaptureSamples` argument from `observeSpeechSegments`
  /// — exposed for kernel-seam tests asserting the adapter receives the
  /// authoritative `captureResult.samples` (#827).
  private(set) var lastObservedRawCaptureSamples: [Float] = []

  func observeSpeechSegments(_ segments: [SpeechSegment], rawCaptureSamples: [Float]) {
    observeSpeechSegmentsCallCount += 1
    lastObservedSpeechSegments = segments
    lastObservedRawCaptureSamples = rawCaptureSamples
    eventLog.append(.observeSpeechSegments(count: segments.count))
  }

  /// Simulate a mid-recording engine crash — drives the kernel's
  /// `asrInterrupted` terminal (PR-4 §3.2).
  func fireEngineInterrupted() {
    onEngineInterrupted?()
  }

  // MARK: Helpers

  private func makeResult(text: String) -> ASRResult {
    ASRResult(
      text: text, language: nil, duration: 0, processingTime: 0, backendType: .parakeet)
  }
}
