import EnviousWisprASR
import EnviousWisprLivePreview
import EnviousWisprPostProcessing
import Foundation
import os

/// One Universal preview session over transcribe.cpp, owning everything it needs (#3735 §3.5).
///
/// **The session accumulates its own audio.** The shared rolling core
/// (`TranscribeCppRollingSession`) has no `feed`: `start` retains a provider the decode loop
/// PULLS each cycle, so something must hold the growing buffer. That something is this
/// object, per session, which is also what makes a stale `feed` unable to reach a newer
/// session's buffer.
///
/// **A preview stop discards.** `end()` only cancels the rolling session, which aborts and
/// joins its in-flight decode; it never runs the heart's authoritative flush or the batch
/// fallback, because nothing the preview decodes ever reaches the document.
package final class TranscribeCppPreviewSession: LivePreviewEngineSession, @unchecked Sendable {

  /// Hard cap on retained preview audio, in samples: 10 minutes at 16 kHz mono.
  ///
  /// **Why a cap and not a rolling window.** The rolling core addresses audio by
  /// absolute time from index 0 of what the provider returns (its decode window is
  /// `[bufferStart .. end]`), so front-trimming this array would shift every timestamp it
  /// relies on. The rolling-window design that fixes it needs an origin offset in the
  /// session itself and is routed to its own issue (#2117).
  ///
  /// What this buys: retained preview audio stops at ~38 MB instead of growing to
  /// ~230 MB across the 60-minute dictation ceiling. Past the cap the preview stops
  /// updating and keeps its last text. **Dictation is completely unaffected**: this is
  /// the limb's own copy and the heart's audio path never sees it.
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
    /// attach a conformer whose `cancel()` blocks on command; the calls here are
    /// one `start` and one `cancel` per recording, so existential dispatch costs
    /// nothing measurable and buys the only way to test a teardown that must WAIT.
    var session: (any WhisperIncrementalSession)?
    /// Created once by the first `end()`; every later caller awaits this same
    /// task rather than returning early.
    var teardown: Task<Void, Never>?
    /// The cap path's cancel, kept JOINABLE.
    ///
    /// `endDecoding` takes the session out of shared state and then awaits a
    /// `cancel()` that can sit inside a still-returning transcribe. Without this
    /// slot a concurrent `end()` sees `session == nil`, finishes instantly, and
    /// the recognizer's turnover releases, so a new decode loop can start on
    /// the same cached model while the capped one is still decoding. Set in the SAME lock acquisition that clears `session`, so
    /// there is no window where neither is visible.
    var decodeStop: Task<Void, Never>?
    /// The attach's `start`, JOINABLE: `end()` and the cap path await it before cancelling, so a
    /// cancel can never land before the start it must undo (#3735 Chunk 9 review).
    var attaching: Task<Void, Never>?
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

  /// The callback the runtime hands to the rolling session. **Enqueue only.**
  /// `yield` on a `bufferingNewest(1)` stream is non-blocking and drops the
  /// superseded value, which is exactly the latest-value semantics a display
  /// wants — and it is why no decode cycle can be delayed by the consumer.
  nonisolated func enqueue(_ text: String) {
    // Drop empties HERE, at the last point before the display.
    //
    // The rolling session already suppresses empty hypotheses, so in production
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
  func attach(_ session: any WhisperIncrementalSession) async {
    // Accepted only while live, in the SAME lock acquisition that records the start, so `end()`
    // either refuses it here or finds `attaching` and joins it. An ended handle must not keep a
    // session: its publication callback retains this handle, and that cycle would keep the
    // preview model loaded after teardown finished.
    let starting: Task<Void, Never>? = state.withLock { s in
      guard !s.ended, !s.capped else { return nil }
      s.session = session
      let task = Task { [weak self] in
        await session.start { [weak self] in
          guard let self else { return (samples: [], count: 0) }
          return self.state.withLock { s in (samples: s.samples, count: s.samples.count) }
        }
      }
      s.attaching = task
      return task
    }
    guard let starting else {
      // Never started: cancel only releases it.
      await session.cancel()
      return
    }
    await starting.value
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
  /// loop over the same cached model, which the whole turnover design exists to
  /// prevent. The task is created and recorded under the same
  /// lock that clears `session`, and `end()` awaits it.
  private func endDecoding() async {
    let stop: Task<Void, Never>? = state.withLock { s in
      guard let live = s.session else { return s.decodeStop }
      s.session = nil
      let starting = s.attaching
      let task = Task {
        await starting?.value  // the cancel must follow the start it undoes
        await live.cancel()
      }
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
    // native run, which this serialization exists to prevent. So the first
    // caller creates the teardown task and everyone awaits it.
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
      let starting = s.attaching
      let task = Task { [continuation, publisher] in
        continuation.finish()
        publisher.cancel()
        await starting?.value  // the cancel must follow the start it undoes
        await live?.cancel()
        await capStop?.value
      }
      s.teardown = task
      return task
    }
    await teardown.value
  }
}
