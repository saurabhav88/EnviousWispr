import EnviousWisprCore
import EnviousWisprPostProcessing
import Foundation

/// The engine-neutral half of an Apple transcript session (#3973): turns per-segment results
/// into `LiveWordsEvent`s and owns the session's once-only teardown. The Apple adapter supplies
/// the native pieces (the results loop, the analyzer's end calls, the locale release); keeping
/// them behind closures is what lets the lifecycle be tested without Apple's framework.
///
/// Contract kept here (`LiveWordsEvent`'s producer obligations):
/// - One `.update` per result, in order: a final result's text as `finalized` with nothing in
///   progress, a volatile result's text as `inProgress`. Apple's results are per segment, so a
///   final carries exactly the words its volatile results showed, and nothing is repeated.
/// - Exactly one `.ended`, after the last result: `.requested` when the results finished normally
///   after the owner asked the session to end; `.failed` when they finished unasked or threw (an
///   error is a failure even during a requested end).
/// - A discarded opening (`silence()`) emits nothing at all, including a delivery that was
///   already under way: `silence()` returns only after it.
final class LiveTranscriptCollector: @unchecked Sendable {

  /// How a meeting session's result times reach written audio (#4355): `project` maps a range
  /// of the session's own input time onto a written span (nil when it cannot be shown), and
  /// `prune` forgets input that ends before a time no later final can need. Both read the map
  /// of the one session this collector belongs to.
  struct Timing: Sendable {
    let project: @Sendable (_ startSeconds: Double, _ endSeconds: Double) -> MeetingAudioSpan?
    let prune: @Sendable (_ beforeSeconds: Double) -> Void
  }

  /// The native operations a teardown needs, in the order it runs them.
  struct Teardown: Sendable {
    /// Closes the input and ends the analyzer (`endAnalyzer`'s rule), on whatever isolation
    /// owns the analyzer.
    let endAnalyzer: @Sendable () async -> Void
    /// Gives back the session's locale use, after the analyzer has ended.
    let release: @Sendable () async -> Void
  }

  private let lock = NSLock()
  /// Held across every delivery to `onEvent` and by `silence()`, so a delivery admitted before
  /// a discard has finished when `silence()` returns. `onEvent` must not call back into this
  /// collector.
  private let deliveryLock = NSLock()
  private var endRequested = false
  private var silenced = false
  private var ended = false
  private var teardownTask: Task<Void, Never>?
  private let onEvent: @Sendable (LiveWordsEvent) -> Void
  private let lookups: WordCorrector.Lookups?
  /// The results loop. Joined by `end()`, never cancelled by it, so queued finals arrive.
  private(set) var task: Task<Void, Never>?

  /// `consume` iterates the engine's results and calls its argument with each one; it returns
  /// when the results end and throws when they fail. `timing` (meeting sessions) maps a final's
  /// timed runs onto written audio; without it every final is one piece of unknown timing.
  init(
    lookups: WordCorrector.Lookups?,
    timing: Timing?,
    onEvent: @escaping @Sendable (LiveWordsEvent) -> Void,
    consume: @escaping @Sendable (_ deliver: @escaping @Sendable (LiveTranscriptResult) -> Void)
      async throws -> Void
  ) {
    self.lookups = lookups
    self.onEvent = onEvent
    task = Task { [self] in
      let corrector = WordCorrector()
      let correct: @Sendable (String) -> String = {
        Self.corrected($0, corrector: corrector, lookups: lookups)
      }
      do {
        try await consume { result in
          guard result.isFinal else {
            // Volatile words stay provisional: no finalized ownership.
            self.emit(.update(finalized: [], inProgress: correct(result.text)))
            return
          }
          // The final's visible text is the whole result corrected once (unchanged); its
          // pieces keep the ownership the approved correction policy allows.
          let finalized = LiveWordsPieceCorrection.corrected(
            Self.pieces(of: result, timing: timing), correct)
          self.emit(.update(finalized: finalized, inProgress: ""))
          // After this final's runs were projected: input before its start is no longer needed
          // by it. A later final that reaches back behind this point projects to nil.
          if let timing, let start = result.startSeconds { timing.prune(start) }
        }
        finish(error: nil)
      } catch {
        finish(error: error)
      }
    }
  }

  /// A final result's text as pieces: one per native run, with its projected span (nil without
  /// timing, without a range, or when projection cannot show one). The pieces always carry
  /// every character of `result.text`; if the runs do not reproduce it exactly, the result is
  /// one piece of unknown timing rather than a partial or reordered text.
  static func pieces(of result: LiveTranscriptResult, timing: Timing?) -> [MeetingTimedPiece] {
    guard let timing, !result.runs.isEmpty,
      Array(result.runs.map(\.text).joined().utf8) == Array(result.text.utf8)
    else { return MeetingTimedPiece.untimed(result.text) }
    return result.runs.compactMap { run in
      guard !run.text.isEmpty else { return nil }
      let span = run.startSeconds.flatMap { start in
        run.endSeconds.flatMap { end in timing.project(start, end) }
      }
      return MeetingTimedPiece(text: run.text, span: span)
    }
  }

  /// A discarded opening: nothing it produces reaches the owner.
  func silence() {
    deliveryLock.withLock { lock.withLock { silenced = true } }
    task?.cancel()
  }

  /// Discards an opening that never reached its owner, in the only safe order: quiet the
  /// collector first, so closing the input (which ends the results) cannot surface as an event,
  /// then close the input, stop the results loop and cancel the analyzer.
  static func discardOpening(
    silence: () -> Void, finishInput: () -> Void, cancelResults: () -> Void,
    cancelAnalyzer: () async -> Void
  ) async {
    silence()
    finishInput()
    cancelResults()
    await cancelAnalyzer()
  }

  /// Ends the session exactly once: the analyzer's input closes, the analyzer finalizes (or is
  /// cancelled), the results loop is joined so its queued finals and the end event arrive, and
  /// only then is the locale use given back. Every caller awaits the same teardown.
  func end(_ teardown: Teardown) async {
    let work: Task<Void, Never> = lock.withLock {
      if let teardownTask { return teardownTask }
      endRequested = true
      let task = self.task
      let work = Task {
        await teardown.endAnalyzer()
        await task?.value
        await teardown.release()
      }
      teardownTask = work
      return work
    }
    await work.value
  }

  /// Closes the input and ends the analyzer: finalized only when it received audio, and
  /// cancelled when finalizing throws, so it is never left un-ended. Shared with the dictation
  /// preview's teardown (`ApplePreviewRecognizer.endSession`).
  static func endAnalyzer(
    finishInput: () -> Void, fedAnyAudio: Bool,
    finalize: () async throws -> Void, cancel: () async -> Void
  ) async {
    finishInput()
    if fedAnyAudio {
      do {
        try await finalize()
      } catch {
        await cancel()
      }
    } else {
      await cancel()
    }
  }

  private func emit(_ event: LiveWordsEvent) {
    deliveryLock.withLock {
      guard lock.withLock({ !silenced && !ended }) else { return }
      onEvent(event)
    }
  }

  private func finish(error: (any Error)?) {
    deliveryLock.withLock {
      let event: LiveWordsEvent? = lock.withLock {
        guard !silenced, !ended else { return nil }
        ended = true
        if let error { return .ended(.failed(String(describing: type(of: error)))) }
        return endRequested ? .ended(.requested) : .ended(.failed("stream ended"))
      }
      if let event { onEvent(event) }
    }
  }

  private static func corrected(
    _ text: String, corrector: WordCorrector, lookups: WordCorrector.Lookups?
  ) -> String {
    guard let lookups, !text.isEmpty else { return text }
    return corrector.correct(text, using: lookups).corrected
  }
}

/// One native transcript result, as the collector needs it (#4355): its text, finality, its
/// attributed runs in order with their session-local times when the module reports them, and
/// the result's own start time. Dictation modules report no run times.
struct LiveTranscriptResult: Sendable, Equatable {
  struct Run: Sendable, Equatable {
    let text: String
    let startSeconds: Double?
    let endSeconds: Double?
  }

  let text: String
  let isFinal: Bool
  let runs: [Run]
  let startSeconds: Double?

  /// A result with no run timing (dictation modules, and tests).
  static func untimed(_ text: String, isFinal: Bool) -> LiveTranscriptResult {
    LiveTranscriptResult(text: text, isFinal: isFinal, runs: [], startSeconds: nil)
  }
}
