import EnviousWisprASR
import EnviousWisprCore
import EnviousWisprLivePreview
import EnviousWisprPostProcessing
import Foundation
import os

/// The Live Preview engine backed by the downloadable universal model
/// (#2108, epic #2077 chunk 4).
///
/// Apple's engine needs macOS 26 and only recognises languages Apple has already
/// installed — measured at 7 of 54 locales on a US-English Mac, and not by
/// region. This one has no OS floor and carries its own languages, which is the
/// entire reason it exists.
///
/// Shaped like `ApplePreviewRecognizer` on purpose: the actor owns preparation
/// that outlives a recording, and a separate handle carries each session's own
/// resources. That split is not style — #1988 produced seven defects of one shape
/// from session state living on the engine actor, where reentrancy let a
/// suspended operation resume onto fields a newer session had replaced.
///
/// **This module cannot import WhisperKit, and that is deliberate.** Every
/// WhisperKit type stays behind `WhisperPreviewRuntime` in the ASR module, so
/// the allowlist that keeps this limb away from capture and the recording path
/// never has to be widened for a decoding option.
package actor WhisperPreviewRecognizer: LivePreviewEngine {

  /// Stable identity for this engine in a `LivePreviewEngineKey`.
  package static let engineID = "whisper_preview"

  private let runtime: WhisperPreviewRuntime
  private let language: String?

  /// `language` is the already-resolved decode language, or nil for auto —
  /// resolved by the resolver, which owns what `.auto` means for THIS engine.
  package init(runtime: WhisperPreviewRuntime, language: String?) {
    self.runtime = runtime
    self.language = language
  }

  /// Claim the model. Throws rather than downloading: a display-only limb must
  /// not be able to start a 217 MB fetch, and the runtime refuses an unadmitted
  /// artifact before it touches the filesystem.
  package func prepare() async throws {
    _ = try await runtime.ensureLoaded()
  }

  /// Open a session and start delivering text.
  ///
  /// `lookups` is this recording's Custom Words snapshot, passed IN rather than
  /// read from engine state — the stored-property version was racy, and a session
  /// opened straight after preparation could capture nil and mangle a user's own
  /// names for a whole recording.
  package func openSession(
    lookups: WordCorrector.Lookups?,
    onText: @escaping @Sendable (String) -> Void
  ) async throws -> any LivePreviewEngineSession {
    let handle = WhisperPreviewSessionHandle(lookups: lookups, onText: onText)
    let session = try await runtime.makeStreamingSession(
      language: language,
      onHypothesis: handle.enqueue)
    await handle.attach(session)
    return handle
  }
}

/// One preview session, owning everything it needs.
///
/// **The session accumulates its own audio.** `WhisperKitStreamingSession` has no
/// `feed`: `start` retains a provider the decode loop PULLS each cycle, so
/// something must hold the growing buffer. That something is this handle, per
/// session — which is also what makes a stale `feed` unable to reach a newer
/// session's buffer.
package final class WhisperPreviewSessionHandle: LivePreviewEngineSession, @unchecked Sendable {

  /// All mutable session state behind ONE scoped lock.
  ///
  /// A lock rather than an actor because the provider is called from inside the
  /// decode loop, and an actor hop there would add a suspension point to the one
  /// place this limb must not add latency. Both critical sections are an array
  /// append and an array copy.
  ///
  /// `OSAllocatedUnfairLock` rather than `NSLock`: Swift 6 marks `NSLock.lock()`
  /// unavailable from async contexts, and `end()` is async. The scoped
  /// `withLock` form is the async-safe one and also makes it impossible to
  /// return early while still holding the lock.
  private struct State {
    var samples: [Float] = []
    var ended = false
    var session: WhisperKitStreamingSession?
  }
  private let state = OSAllocatedUnfairLock(initialState: State())

  private let continuation: AsyncStream<String>.Continuation
  private let publisher: Task<Void, Never>

  init(lookups: WordCorrector.Lookups?, onText: @escaping @Sendable (String) -> Void) {
    // `bufferingNewest(1)`: a preview only ever wants the LATEST text. An
    // unbounded buffer would queue stale hypotheses behind a slow consumer and
    // display them after they had stopped being true.
    let (stream, continuation) = AsyncStream<String>.makeStream(
      of: String.self, bufferingPolicy: .bufferingNewest(1))
    self.continuation = continuation

    // Custom Words and delivery run HERE, on a task of our own — never inside
    // the callback, which is invoked on the decode actor where any await delays
    // the next decode. `WordCorrector.correct` is a documented pure function,
    // safe off any actor.
    self.publisher = Task {
      let corrector = WordCorrector()
      for await text in stream {
        if Task.isCancelled { return }
        guard let lookups, !text.isEmpty else {
          onText(text)
          continue
        }
        onText(corrector.correct(text, using: lookups).corrected)
      }
    }
  }

  /// The callback the runtime hands to the streaming session. **Enqueue only.**
  /// `yield` on a `bufferingNewest(1)` stream is non-blocking and drops the
  /// superseded value, which is exactly the latest-value semantics a display
  /// wants — and it is why no decode cycle can be delayed by the consumer.
  nonisolated func enqueue(_ text: String) {
    continuation.yield(text)
  }

  /// Start the decode loop against this handle's own growing buffer. Separate
  /// from `init` because `start` is actor-isolated and an initializer cannot
  /// await.
  func attach(_ session: WhisperKitStreamingSession) async {
    let alreadyEnded = state.withLock { s -> Bool in
      s.session = session
      return s.ended
    }
    // A session ended before it attached must not start a loop that nothing will
    // stop. Cheap here; an orphaned decode loop is not.
    guard !alreadyEnded else { return }

    await session.start { [weak self] in
      guard let self else { return (samples: [], count: 0) }
      return self.state.withLock { s in (samples: s.samples, count: s.samples.count) }
    }
  }

  package func feed(_ newSamples: [Float]) async {
    state.withLock { s in
      guard !s.ended else { return }
      s.samples.append(contentsOf: newSamples)
    }
  }

  /// Finish exactly once and release everything.
  ///
  /// Ends the stream FIRST so the publisher drains and cannot deliver text after
  /// the caller has moved on, then cancels the decode loop. Every session must
  /// reach this: #1988 found four abandonment sites, three of them only by review.
  package func end() async {
    let (alreadyEnded, live) = state.withLock { s -> (Bool, WhisperKitStreamingSession?) in
      let was = s.ended
      s.ended = true
      s.samples = []
      let session = s.session
      s.session = nil
      return (was, session)
    }
    guard !alreadyEnded else { return }

    continuation.finish()
    publisher.cancel()
    await live?.cancel()
  }
}
