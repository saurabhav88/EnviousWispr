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
}

@MainActor
final class FakeEngine: ASREngineAdapter {
  /// `var` so a scenario's `EngineDirective.setBehavior` can reconfigure the
  /// fake before a session begins (e.g. the engine-switch scenarios).
  var behavior: FakeEngineBehavior

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
  private(set) var cancelCallCount = 0
  private(set) var lastUnloadPolicy: ModelUnloadPolicy?
  private(set) var lastSessionID: SessionID?
  /// Count of mid-session engine-switch requests (A18). The request models a
  /// factory-preference change (PR-6 owns the factory); it does NOT mutate
  /// this engine's `behavior`, so the active session keeps its transcript.
  private(set) var midSessionSwitchRequestCount = 0

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
      // It suspends until `cancel()` resumes us; best-effort load
      // cancellation (D6): `warmUp()` throws once released.
      // If `cancel()` ALREADY ran (cancel-before-warmUp ordering), there is no
      // future `cancel()` to resume the continuation — parking would hang.
      // Throw immediately instead.
      if isCancelled { throw ASREngineError.wedged }
      emitLoadTick()
      emitLoadTick()
      await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        loadWedgeContinuation = continuation
      }
      throw ASREngineError.wedged
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

  func beginSession(_ id: SessionID, options: TranscriptionOptions) async throws {
    beginSessionCallCount += 1
    lastSessionID = id
    isTerminal = false
    isCancelled = false
  }

  func acceptAudio(_ buffer: AudioBufferHandoff) {
    // A call after a terminal session MUST be a no-op (PR-1 §B.2.2).
    if isTerminal {
      acceptAudioAfterTerminalCount += 1
      return
    }
    acceptedBufferCount += 1
  }

  func finalize() async -> ASREngineOutcome {
    finalizeCallCount += 1
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
    }
    isTerminal = true
    return outcome
  }

  /// Emit one finalize-progress tick (driven by a scenario's `emitFinalizeTick`).
  func emitFinalizeTick() {
    finalizeMarker += 1
    finalizeContinuation.yield(ASRFinalizeProgressTick(marker: finalizeMarker))
  }

  func cancel() async {
    cancelCallCount += 1
    // Idempotent — 2+ calls have the same effect as one (PR-1 §B.2.2).
    isCancelled = true
    isTerminal = true
    // Release a wedged `warmUp()` / `finalize()` (best-effort, D6).
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
