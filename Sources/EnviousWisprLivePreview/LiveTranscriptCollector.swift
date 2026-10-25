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

  /// `consume` iterates the engine's results and calls its argument with each one's text and
  /// finality; it returns when the results end and throws when they fail.
  init(
    lookups: WordCorrector.Lookups?,
    onEvent: @escaping @Sendable (LiveWordsEvent) -> Void,
    consume: @escaping @Sendable (_ deliver: @escaping @Sendable (String, Bool) -> Void)
      async throws -> Void
  ) {
    self.lookups = lookups
    self.onEvent = onEvent
    task = Task { [self] in
      let corrector = WordCorrector()
      do {
        try await consume { text, isFinal in
          let piece = Self.corrected(text, corrector: corrector, lookups: lookups)
          self.emit(.update(finalized: isFinal ? piece : "", inProgress: isFinal ? "" : piece))
        }
        finish(error: nil)
      } catch {
        finish(error: error)
      }
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
