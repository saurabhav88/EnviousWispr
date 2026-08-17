import EnviousWisprASR
import EnviousWisprCore
import EnviousWisprLivePreview
import EnviousWisprPostProcessing
import Foundation
import os

/// Serializes the OPEN-A-SESSION transaction, which suspends at every step.
///
/// **An actor is not enough for this, and the first attempt proved it.**
/// `WhisperPreviewRecognizer` is an actor, so `openSession` calls are serialized
/// — but an actor is reentrant at every `await`, and that method awaits three
/// times before it records the new session. A second call arriving during any of
/// those suspensions also read `previousSession == nil`, so both proceeded and
/// both started decode loops over the same cached WhisperKit instance: exactly
/// the concurrent-transcribe corruption `WhisperKitStreamingSession.cancel()`
/// documents. Cloud review caught it after the serialization was added.
///
/// The lock is held ACROSS the suspensions instead. This is the repo's own
/// pattern, not a new invention: `LocaleReservations` exists for the identical
/// reason on a different subject, and its doc records that four rounds of
/// one-defect-per-round were the signal that patching was the problem.
///
/// FIFO hand-off ported WHOLE from that primitive — `release()` keeps `held`
/// true and passes ownership straight to the next waiter, so there is no gap for
/// a third caller and no starvation. That doc also records that porting it
/// PARTIALLY is what caused its own first defect, so this is a complete copy
/// rather than a simplification.
package actor PreviewSessionTurnover {
  private var held = false
  private var waiters: [CheckedContinuation<Void, Never>] = []

  package init() {}

  package func acquire() async {
    if !held {
      held = true
      return
    }
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      waiters.append(continuation)
    }
  }

  package func release() {
    if waiters.isEmpty {
      held = false
    } else {
      // Stays `held`; ownership passes straight to the next waiter.
      waiters.removeFirst().resume()
    }
  }
}

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

  /// The session most recently opened, so the NEXT `openSession` can wait for it
  /// to finish tearing down before starting another decode loop over the SAME
  /// cached WhisperKit instance.
  ///
  /// This is not belt-and-braces. `WhisperKitStreamingSession.cancel()` documents
  /// why it awaits the loop's exit: an aborted `transcribe` still returns on its
  /// own schedule, so returning early "would let a quick next
  /// recording start a SECOND concurrent transcribe on the same model and corrupt
  /// decoder state". The coordinator cancels its session task WITHOUT awaiting
  /// `end()`, so on a rapid stop/start the old session can still be inside that
  /// wait when a new one opens. Apple's engine has no equivalent hazard because
  /// each of its sessions owns its own analyzer; ours share one kit.
  private var previousSession: WhisperPreviewSessionHandle?

  /// Held across the whole open transaction. See `PreviewSessionTurnover`.
  private let turnover = PreviewSessionTurnover()

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
    // Hold the lock across the ENTIRE transaction — end the old session, build
    // the new one, attach it, record it. Every one of those steps suspends, and
    // actor isolation alone lets a second caller in at any of them.
    await turnover.acquire()
    do {
      await previousSession?.end()

      let handle = WhisperPreviewSessionHandle(lookups: lookups, onText: onText)
      let session = try await runtime.makeStreamingSession(
        language: language,
        // The retention cap the session applies before it stores or publishes
        // anything. The word-boundary-aware trim still runs downstream; this
        // stops the ASR actor holding a full 60-minute transcript at all.
        hypothesisRetentionLimit: LivePreviewTextBound.maxCharacters,
        onHypothesis: handle.enqueue)
      await handle.attach(session)
      previousSession = handle
      await turnover.release()
      return handle
    } catch {
      // Release on the throwing path too: a lock that leaks on failure wedges
      // every later recording, which is worse than the failure that caused it.
      await turnover.release()
      throw error
    }
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

  /// Hard cap on retained preview audio, in samples: 10 minutes at 16 kHz mono.
  ///
  /// **Why a cap and not a rolling window.** The session decodes with
  /// `clipTimestamps = [bufferStartSec]` and is handed the WHOLE buffer, so it
  /// addresses audio by absolute time from index 0. Front-trimming this array
  /// would silently shift every timestamp the decoder relies on — a change to
  /// heart-path decode semantics, made from a display limb, which is not a trade
  /// worth taking inside a review round. The rolling-window design that fixes it
  /// properly needs an origin offset in the session itself and is routed to its
  /// own issue.
  ///
  /// What this buys: retained preview audio stops at ~38 MB instead of growing to
  /// ~230 MB across the 60-minute dictation ceiling, and the copy-on-write the
  /// decoder triggers each cycle stops growing with it. Past the cap the preview
  /// stops updating and keeps its last text. **Dictation is completely
  /// unaffected** — this is the limb's own copy and the heart's audio path never
  /// sees it.
  ///
  /// Ten minutes covers essentially all real dictation: the product is built for
  /// dictation rather than long-form, and a preview that quietly stops after ten
  /// minutes is a far better failure than one that costs a quarter of a gigabyte.
  static let maxRetainedSamples = 10 * 60 * 16_000

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
    var capped = false
    /// Held as the protocol rather than the concrete session so a test can
    /// attach a conformer whose `cancel()` blocks on command. The seam already
    /// exists in ASR for exactly this reason (`WhisperKitTranscribing` is its
    /// sibling); the calls here are one `start` and one `cancel` per recording,
    /// so existential dispatch costs nothing measurable and buys the only way to
    /// test a teardown that must WAIT.
    var session: (any WhisperKitIncrementalSession)?
    /// Created once by the first `end()`; every later caller awaits this same
    /// task rather than returning early.
    var teardown: Task<Void, Never>?
    /// The cap path's cancel, kept JOINABLE.
    ///
    /// `endDecoding` takes the session out of shared state and then awaits a
    /// `cancel()` that can sit inside a still-returning transcribe. Without this
    /// slot a concurrent `end()` sees `session == nil`, finishes instantly, and
    /// the recognizer's turnover releases — so a new decode loop can start on
    /// the same cached WhisperKit instance while the capped one is still
    /// decoding. Set in the SAME lock acquisition that clears `session`, so
    /// there is no window where neither is visible.
    var decodeStop: Task<Void, Never>?
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
        // BOUND FIRST, before Custom Words and before anything crosses to the
        // coordinator.
        //
        // The hypothesis is cumulative, so a long dictation grows it without
        // limit. `LivePreviewTextBound` is the ONE implementation of this cap and
        // its doc records that the first version of the Apple producer trimmed at
        // the CONSUMER, leaving a 60-minute dictation growing unboundedly under a
        // comment promising it could not. This engine reintroduced exactly that
        // until cloud review caught it.
        //
        // Bounding before `correct` also keeps the corrector off the full
        // transcript on every update: the pill shows a two-line tail, so running
        // word correction over 9,000 words to display 20 is work nobody sees.
        let bounded = LivePreviewTextBound.apply(text)
        guard let lookups, !bounded.isEmpty else {
          onText(bounded)
          continue
        }
        // Bound AGAIN after correction. A custom word whose canonical is longer
        // than the alias it replaces expands the text, so an already-2,000-char
        // tail can exceed the limit on the way out. The Apple producer applies
        // the bound on both sides for this reason; the first version of this fix
        // ported only the inner half, which is how a proven pattern becomes a
        // half-proven one.
        onText(LivePreviewTextBound.apply(corrector.correct(bounded, using: lookups).corrected))
      }
    }
  }

  /// The callback the runtime hands to the streaming session. **Enqueue only.**
  /// `yield` on a `bufferingNewest(1)` stream is non-blocking and drops the
  /// superseded value, which is exactly the latest-value semantics a display
  /// wants — and it is why no decode cycle can be delayed by the consumer.
  nonisolated func enqueue(_ text: String) {
    // Drop empties HERE, at the last point before the display.
    //
    // The streaming session already suppresses empty hypotheses, so in production
    // one should never arrive — but "an upstream guarantee" is not the same as a
    // guarantee, and the HARM is local: a blank pill mid-sentence reads to a user
    // as the app losing what they just said. The guard belongs where the damage
    // would happen.
    //
    // Found by the full suite, not by the isolated run: with a one-slot buffer,
    // an empty followed quickly by real text is usually overwritten before the
    // consumer wakes, so the defect only appears when contention lets the
    // consumer run in between. The isolated test passed; the loaded one did not.
    guard !text.isEmpty else { return }
    continuation.yield(text)
  }

  /// Start the decode loop against this handle's own growing buffer. Separate
  /// from `init` because `start` is actor-isolated and an initializer cannot
  /// await.
  func attach(_ session: any WhisperKitIncrementalSession) async {
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
    let justCapped: Bool = state.withLock { s in
      guard !s.ended, !s.capped else { return false }
      guard s.samples.count + newSamples.count <= Self.maxRetainedSamples else {
        s.capped = true
        return true
      }
      s.samples.append(contentsOf: newSamples)
      return false
    }
    // Stop the decode loop rather than letting it re-decode a frozen buffer
    // forever. The display keeps its last text; the recording continues normally.
    if justCapped { await endDecoding() }
  }

  /// Stop decoding but keep the handle alive, so `end()` stays the single
  /// teardown path and cannot run twice.
  ///
  /// The cancel runs as a STORED task rather than inline, because this method
  /// removes the session from shared state before awaiting it. An inline await
  /// leaves a window where the decode is still running and nothing can be joined
  /// to it: a stop-and-restart landing in that window would open a second decode
  /// loop over the same cached model, which is the corruption the whole turnover
  /// design exists to prevent. The task is created and recorded under the same
  /// lock that clears `session`, and `end()` awaits it.
  private func endDecoding() async {
    let stop: Task<Void, Never>? = state.withLock { s in
      guard let live = s.session else { return s.decodeStop }
      s.session = nil
      let task = Task { await live.cancel() }
      s.decodeStop = task
      return task
    }
    await stop?.value
  }

  /// Finish exactly once and release everything.
  ///
  /// Ends the stream FIRST so the publisher drains and cannot deliver text after
  /// the caller has moved on, then cancels the decode loop. Every session must
  /// reach this: #1988 found four abandonment sites, three of them only by review.
  package func end() async {
    // **Idempotent AND awaitable.** A second caller must WAIT for the same
    // teardown, not return immediately: the recognizer's turnover wait and the
    // coordinator's own `end()` race, and an early return would let a new decode
    // loop start while the old `cancel()` is still awaiting an in-flight
    // transcribe — the corruption this serialization exists to prevent. So the
    // first caller creates the teardown task and everyone awaits it.
    let teardown: Task<Void, Never> = state.withLock { s in
      if let existing = s.teardown { return existing }
      s.ended = true
      s.samples = []
      let live = s.session
      s.session = nil
      // Exactly one of these is ever non-nil — the cap path takes the session or
      // this does — but awaiting both is what makes that an observation rather
      // than an assumption, and costs one nil check.
      let capStop = s.decodeStop
      let task = Task { [continuation, publisher] in
        continuation.finish()
        publisher.cancel()
        await live?.cancel()
        await capStop?.value
      }
      s.teardown = task
      return task
    }
    await teardown.value
  }
}
