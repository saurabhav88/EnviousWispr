import EnviousWisprASR
import EnviousWisprLivePreview
import EnviousWisprPostProcessing
import Foundation
import os

/// One Universal preview session over transcribe.cpp, owning everything it needs (#3735 §3.5).
///
/// **The session holds its own audio, as a rolling window.** The shared rolling core
/// (`TranscribeCppRollingSession`) has no `feed`: `start` retains a provider the decode loop
/// PULLS each cycle, so something must hold the buffer. That something is this object, per
/// session, which is also what makes a stale `feed` unable to reach a newer session's buffer.
/// The core tells it which audio it will never read again (`releaseAudio(before:)`), and this
/// object drops exactly that, so it keeps the core's decode window rather than the recording
/// (#2117).
///
/// **A preview stop discards.** `end()` only cancels the rolling session, which aborts and
/// joins its in-flight decode; it never runs the heart's authoritative flush or the batch
/// fallback, because nothing the preview decodes ever reaches the document.
///
/// **Two outputs** (#3973). Dictation's display session (`init(lookups:onText:)`) publishes the
/// latest bounded text. A transcript session (`init(lookups:onEvent:)`, EnviousMeet's live
/// words) delivers every finalized delta in order through a `LiveWordsQueue`, and ends with
/// exactly one `.ended`: `.requested` from `end()`, `.failed("ceiling")` when the retained audio
/// reaches the ceiling, `.failed("backlog")` from the queue's budget; the first one wins.
package final class TranscribeCppPreviewSession: LivePreviewEngineSession, @unchecked Sendable {

  /// Ceiling on RETAINED preview audio, in samples: 2 minutes at 16 kHz mono (~7.7 MB).
  ///
  /// Not a recording-length cap (#2117). The core releases audio each time its origin moves.
  /// It checks before every decode that has a second of new audio, including retries after an
  /// empty, failed or refused decode: past 15 s it moves to a committed segment end that leaves
  /// 8 s, and with no such boundary it moves by force past 30 s. So a promptly serviced
  /// session retains about 30 s however long the recording runs. That is an expectation, not
  /// a bound: audio keeps arriving during start-up, a drain wait or a long decode, and a
  /// committed boundary reached late can leave a longer window.
  ///
  /// This ceiling is the bound. If it is reached the preview stops updating for the rest of
  /// that session and keeps its last text, the same failure the old 10-minute cap had, rather
  /// than holding audio without limit. **Dictation is completely unaffected**: this is the
  /// limb's own copy and the heart's audio path never sees it.
  static let maxRetainedSamples = 2 * 60 * 16_000

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
    /// The retained window: absolute samples `origin ..< origin + samples.count`.
    var samples: [Float] = []
    /// Absolute index of `samples[0]`: everything before it was released by the core.
    var origin = 0
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

  private enum Output {
    case display(AsyncStream<String>.Continuation, publisher: Task<Void, Never>)
    case transcript(LiveWordsQueue)
  }
  private let output: Output
  /// Test seam: fires when teardown begins, before it joins a pending start (nil in the app).
  private let onTeardownStarted: (@Sendable () -> Void)?

  init(
    lookups: WordCorrector.Lookups?, onText: @escaping @Sendable (String) -> Void,
    onTeardownStarted: (@Sendable () -> Void)? = nil
  ) {
    self.onTeardownStarted = onTeardownStarted
    // `bufferingNewest(1)`: a preview only ever wants the LATEST text. An
    // unbounded buffer would queue stale hypotheses behind a slow consumer and
    // display them after they had stopped being true.
    let (stream, continuation) = AsyncStream<String>.makeStream(
      of: String.self, bufferingPolicy: .bufferingNewest(1))

    // Custom Words and delivery run HERE, on a task of our own — never inside
    // the callback, which is invoked on the decode actor where any await delays
    // the next decode. `WordCorrector.correct` is a documented pure function,
    // safe off any actor.
    let publisher = Task {
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
    self.output = .display(continuation, publisher: publisher)
  }

  /// A transcript session (#3973): every event reaches `onEvent` in order, from the queue's
  /// own consumer task, never from the decode actor.
  init(
    lookups: WordCorrector.Lookups?, onEvent: @escaping @Sendable (LiveWordsEvent) -> Void,
    onTeardownStarted: (@Sendable () -> Void)? = nil
  ) {
    self.onTeardownStarted = onTeardownStarted
    self.output = .transcript(LiveWordsQueue(lookups: lookups, onEvent: onEvent))
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
    guard !text.isEmpty, case .display(let continuation, _) = output else { return }
    continuation.yield(text)
  }

  /// The runtime's transcript callback for a transcript session. **Enqueue only**, like
  /// `enqueue`: the queue takes a lock and never waits on its consumer.
  nonisolated func publish(_ event: TranscriptEvent) {
    guard case .transcript(let queue) = output else { return }
    queue.publish(event)
  }

  /// A transcript session that was never handed to its owner (the open failed): delivers
  /// nothing, not even a terminal, and releases everything.
  func discard() async {
    if case .transcript(let queue) = output { await queue.silence() }
    await end()
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
          // `count` is absolute (everything fed so far); the array holds only its tail.
          return self.state.withLock { s in (samples: s.samples, count: s.origin + s.samples.count) }
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

  /// The core's release notice: it will never read audio before absolute sample `mark` again.
  /// Drops exactly that prefix; a mark at or before `origin` (a repeat, or one landing after
  /// `end()` emptied the buffer) drops nothing. Runs on the core's actor inside its loop, so
  /// it only trims under the lock.
  nonisolated func releaseAudio(before mark: Int) {
    state.withLock { s in
      let drop = min(max(0, mark - s.origin), s.samples.count)
      guard drop > 0 else { return }
      s.samples.removeFirst(drop)
      s.origin += drop
    }
  }

  /// Retained audio, in samples (tests and the long-run harness).
  package var retainedSampleCountForTests: Int { state.withLock { $0.samples.count } }

  package func feed(_ newSamples: [Float]) async {
    let justCapped: Bool = state.withLock { s in
      guard !s.ended, !s.capped else { return false }
      guard s.samples.count + newSamples.count <= Self.maxRetainedSamples else {
        s.capped = true
        // In the same transition: a transcript owner is told its live words stop here, after
        // the accepted finals, and no publication can slip in before the ceiling terminal.
        // The queue's lock nests inside this one and never calls the owner.
        if case .transcript(let queue) = output { queue.fail("ceiling") }
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
  /// the caller has moved on, then cancels the decode loop. A transcript session closes its
  /// queue's input first instead, and after the decode loop has stopped delivers the accepted
  /// events and its one terminal before this returns. Every session must
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
      // A transcript session refuses publications from this transition on, so a decode landing
      // before the teardown task runs can neither add words nor turn this stop into a backlog
      // failure. Accepted finals stay queued and drain below. (Nested queue lock; no callback.)
      if case .transcript(let queue) = output { queue.closeInput() }
      s.samples = []
      let live = s.session
      s.session = nil
      // Exactly one of these is ever non-nil — the cap path takes the session or
      // this does — but awaiting both is what makes that an observation rather
      // than an assumption, and costs one nil check.
      let capStop = s.decodeStop
      let starting = s.attaching
      let task = Task { [output, onTeardownStarted] in
        switch output {
        case .display(let continuation, let publisher):
          continuation.finish()
          publisher.cancel()
        case .transcript:
          break  // input already closed above, with `ended`
        }
        onTeardownStarted?()
        await starting?.value  // the cancel must follow the start it undoes
        await live?.cancel()
        await capStop?.value
        // Decoding has physically stopped: deliver what was accepted, then the one terminal.
        if case .transcript(let queue) = output { await queue.finish() }
      }
      s.teardown = task
      return task
    }
    await teardown.value
  }
}
