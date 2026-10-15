import EnviousWisprCore
import EnviousWisprTranscribeCpp
import Foundation

// MARK: - TranscribeCppRollingSession (#3735 plan §3.11, retention rule §3.5)
//
// Faster Transcription on Whisper, over transcribe.cpp. The #1276 architecture (the UFAL
// whisper_streaming recipe, `.claude/knowledge/whisperkit-research.md` FACT:
// ufal-streaming-architecture-shipped) as the retired WhisperKit streaming session shipped it, with one
// change forced by the engine: transcribe.cpp gives SEGMENT timestamps, never word times.
//
//   - Per cycle: pull the adapter's lossless `streamingPCM`; gate on >= 1 s of new audio;
//     decode the retained buffer `[bufferStart .. end]`. Committed speech stays IN the window
//     (re-decoded), so every decode warms up on known audio and never opens cold on a pause.
//     The language is the locked one: no LID.
//   - Agreement (LocalAgreement-2 over words): the hypothesis is split into Unicode-aware word
//     units that keep their original spacing. The units after the committed cut are compared
//     with the previous cycle's, independently of where either decode put its segment
//     boundaries; the longest common prefix is agreed. Only COMPLETE segments of this decode
//     that the agreed prefix covers commit, so every committed span has a real end time and no
//     word time is ever invented.
//   - Retention (§3.5), checked on the captured audio before every window is cut (so empty
//     and failed decodes cannot grow the window) and after every applied decode: past
//     `bufferTrimSec` the origin moves to the end of a committed
//     segment that leaves at least `minRetainedBufferSec` of real audio in the window; the
//     text before it scrolls out. With no such boundary and the buffer past
//     `maxUnconfirmedWindowSec + 5`, the origin advances to the captured-audio retention line,
//     ALL held-back and agreement state is cleared (a crossing segment has no word times to
//     split by), and nothing disputed commits.
//     That span's words are then missing from the stream, so finalize sends the take to the
//     adapter's clean batch decode instead of releasing a transcript with a hole in it.
//   - Finalize: release = committed text + the held-back hypothesis. Caught up (the audio the
//     release does not cover is under 0.1 s or silent) → release, zero inference. Otherwise
//     ONE decode of the retained buffer, appended to the scrolled-out text. Empty, failed or
//     overflowed → `accepted: false`, which the adapter turns into the clean batch decode of
//     the whole recording.
//
// Two modes on one core. Heart mode (no `Publication`) keeps the whole transcript for the
// recording cap and finalizes as above. Preview mode (the Universal Live Preview, §3.5) adds a
// `Publication`: after every heard decode it hands the display a tail built from the END, and
// it keeps its own committed and scrolled-out text to that tail's limit, because nothing ever
// releases a preview transcript. The preview's audio cap lives with its session owner; the
// preview only ever cancels, never finalizes. Preview bounds never apply in heart mode.

/// One segment of a decode, in absolute seconds of the session's `streamingPCM`.
struct RollingSegment: Sendable, Equatable {
  let start: Float
  let end: Float
  let text: String
}

/// One word of a hypothesis. `text` carries the word with the spacing and punctuation that
/// precede it in the decoder's output, so concatenating units reproduces that output exactly
/// (CJK stays unspaced). `key` is the comparable word alone.
struct RollingUnit: Sendable, Equatable {
  let text: String
  let key: String
  let segment: Int
}

package actor TranscribeCppRollingSession: WhisperIncrementalSession {
  /// One decode of `samples`: the native full text and segments, timed in `samples`' own
  /// coordinates. The owner (heart backend or preview runtime) owns the model, the lane,
  /// padding, occupancy and the native-boundary observer; a cancelled call returns only after
  /// the aborted native run ended.
  typealias Decode = @Sendable ([Float]) async throws -> TranscribeCppRunResult

  /// Preview mode: what the display is handed after every heard decode.
  struct Publication: Sendable {
    /// The most text the session keeps or hands over, in characters (the preview's
    /// `LivePreviewTextBound.maxCharacters`, which this module cannot import).
    let retentionLimit: Int
    /// Called on this actor inside the loop. It must only enqueue: anything slower delays the
    /// next decode.
    let onHypothesis: @Sendable (String) -> Void
  }

  private let decode: Decode
  private let cadence: Duration
  private let publication: Publication?
  /// The last text handed to `onHypothesis`, so an unchanged hypothesis is not handed again.
  private var lastPublished = ""

  static let sampleRate: Float = 16_000
  /// One second of new audio before a cycle decodes (the retired WhisperKit session's gate).
  private let minNewSamplesToDecode = 16_000

  /// §3.5 retention values, carried over from the retired WhisperKit session.
  package static let defaultMaxUnconfirmedWindowSec: Float = 25
  static let bufferTrimSec: Float = 15
  static let minRetainedBufferSec: Float = 8

  /// Finalize's caught-up rule (the shipped unheard-tail rule): audio the release does not
  /// cover counts as heard when it is shorter than this or quieter than `tailEnergyFloor`.
  static let minVoicedTailSec: Float = 0.1
  static let tailEnergyFloor: Float = 0.001

  /// A segment that starts at or after the committed end, less this jitter tolerance (the UFAL
  /// `HypothesisBuffer.insert` value), holds only audio no committed word came from.
  static let cutToleranceSec: Float = 0.1

  // MARK: Stream state (single owner: the serial loop, then finalize)

  /// Every committed unit's text, in order; the transcript prefix. Only grows.
  private var committedText = ""
  /// Committed units whose audio is still inside the buffer, with their segment's end.
  private var committedInBuffer: [(unit: RollingUnit, end: Float)] = []
  /// Committed text whose audio has scrolled out of the buffer.
  private var scrolledOutText = ""
  /// End (seconds) of the last committed segment.
  private var lastCommittedEnd: Float = 0
  /// Buffer origin (seconds); moves only at a trim.
  private var bufferStart: Float = 0
  /// The previous cycle's units after the committed cut (agreement state).
  private var previousHypothesis: [RollingUnit] = []
  /// This cycle's held-back units and the end of the segment each belongs to.
  private var heldBack: [(unit: RollingUnit, end: Float)] = []
  /// Set when a forced advance discarded audio whose words never committed.
  private var discardedUnstableAudio = false

  private var lastDecodeSampleCount = 0
  private var decodeCount = 0
  private var totalDecodeTimeMs = 0

  private var loopDecodeInFlight = false
  private var stoppedMidDecode = false
  private var stopSnapshotTaken = false
  private var running = false
  private var finished = false
  /// Set by `cancel`: no result after it is released, and finalize stops at its next step.
  private var cancelled = false
  /// Bumped by every `start`. A terminal or loop from an earlier run captures its generation
  /// and, after every suspension, touches nothing once a newer run has begun: a restart while
  /// an old finalize still drains must never hand it the new run's audio or counters.
  private var generation = 0
  private var loopTask: Task<Void, Never>?
  /// The stopped loop's drain, shared by every terminal (a second Cancel joins the first's
  /// drain instead of returning before the native run ends).
  private var drainTask: Task<Void, Never>?
  /// Finalize's authoritative decode while it runs; Cancel cancels and joins it.
  private var flushTask: Task<TranscribeCppRunResult, Error>?
  /// Loop cycles whose decode returned and was accounted (applied, empty or failed).
  private var cyclesCompleted = 0
  private var cycleWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
  /// Terminals (finalize, cancel) that reached the drain join.
  private var drainJoins = 0
  private var drainJoinWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
  private var audioSamplesProvider: (@Sendable () async -> (samples: [Float], count: Int))?

  init(decode: @escaping Decode, cadence: Duration = .seconds(1), publication: Publication? = nil) {
    self.decode = decode
    self.cadence = cadence
    self.publication = publication
  }

  // MARK: Test observability (actor state, not decoder timing)

  var committedTextForTests: String { committedText }
  var bufferStartForTests: Float { bufferStart }
  var heldBackTextForTests: String { heldBack.map(\.unit.text).joined() }
  var decodeCountForTests: Int { decodeCount }
  var discardedUnstableAudioForTests: Bool { discardedUnstableAudio }

  /// Returns once `count` loop cycles have finished applying (or accounting for) their decode.
  /// The decoder's own call signal fires at decode ENTRY, before the result is applied.
  func cyclesCompleted(reach count: Int) async {
    guard cyclesCompleted < count else { return }
    await withCheckedContinuation { cycleWaiters.append((count, $0)) }
  }

  /// Returns once `count` terminals are waiting on (or have passed) the shared drain.
  func drainJoins(reach count: Int) async {
    guard drainJoins < count else { return }
    await withCheckedContinuation { drainJoinWaiters.append((count, $0)) }
  }

  // MARK: WhisperIncrementalSession

  package func start(
    audioSamplesProvider: @Sendable @escaping () async -> (samples: [Float], count: Int)
  ) {
    generation += 1
    running = true
    finished = false
    cancelled = false
    committedText = ""
    committedInBuffer = []
    scrolledOutText = ""
    lastCommittedEnd = 0
    bufferStart = 0
    previousHypothesis = []
    heldBack = []
    discardedUnstableAudio = false
    lastDecodeSampleCount = 0
    decodeCount = 0
    totalDecodeTimeMs = 0
    loopDecodeInFlight = false
    stoppedMidDecode = false
    stopSnapshotTaken = false
    cyclesCompleted = 0
    lastPublished = ""
    self.audioSamplesProvider = audioSamplesProvider
    // A previous take's native work may still be draining: the new loop decodes only after it
    // physically ended, so two runs never share the model.
    let drain = drainTask
    let flush = flushTask
    drainTask = nil
    flushTask = nil
    loopTask = Task { [weak self] in
      await drain?.value
      _ = await flush?.result
      await self?.runLoop()
    }
  }

  /// #1309: the adapter calls this BEFORE draining its feed tasks, so the snapshot reflects the
  /// stop moment. Kept `async` to match the requirement exactly (see the protocol's doc).
  package func noteStopRequested() async {
    guard !stopSnapshotTaken else { return }
    stopSnapshotTaken = true
    stoppedMidDecode = loopDecodeInFlight
  }

  /// Authoritative flush. The adapter has drained its feed tasks, so the provider returns the
  /// complete `streamingPCM`. The loop is stopped and its in-flight decode aborted, then
  /// AWAITED: the aborted run must physically end before the flush decode, which uses the same
  /// model. The executor clears the abort before admitting the next request, so the loop's
  /// stop never reaches the flush. `finalSamples` and `speechSegments` are ignored (the
  /// single-coordinate design, §3.2: every coordinate here is `streamingPCM`'s).
  // periphery:ignore:parameters finalSamples,speechSegments - single-coordinate design (§3.2)
  package func finalize(
    finalSamples: [Float], speechSegments: [SpeechSegment]
  ) async -> IncrementalResult {
    let run = generation
    if !stopSnapshotTaken { stoppedMidDecode = loopDecodeInFlight }
    await stopLoop()
    guard isCurrent(run) else { return cancelledResult() }
    guard let provider = audioSamplesProvider else {
      return result(text: committedText, samplesCovered: 0, tailDecodeMs: 0)
    }
    audioSamplesProvider = nil
    let (samples, count) = await provider()
    guard isCurrent(run) else { return cancelledResult() }

    // The flush window obeys the same bound as every loop window.
    retain(realAudioEnd: Float(count) / Self.sampleRate)
    // A forced advance dropped words that never committed: releasing would ship a hole.
    if discardedUnstableAudio {
      return fallback(strategy: "streaming_window_overflow_fallback", tailMs: 0)
    }

    let releaseText = heldBack.reduce(committedText) { Self.join($0, $1.unit.text) }
    // Coverage of the text about to be released, from its own segments (never from how much
    // audio a decode was handed, #1308), clamped to real audio.
    let releasedEnd = min(
      max(lastCommittedEnd, heldBack.last?.end ?? 0), Float(count) / Self.sampleRate)
    let unheardStart = max(0, min(count, Int(releasedEnd * Self.sampleRate)))
    let unheard = unheardStart < count ? Array(samples[unheardStart..<count]) : []
    let unheardSec = Float(unheard.count) / Self.sampleRate
    if unheardSec < Self.minVoicedTailSec || Self.rms(unheard) <= Self.tailEnergyFloor {
      return result(text: releaseText, samplesCovered: count, tailDecodeMs: 0)
    }

    // Fresh speech at stop: ONE decode of the retained, context-bearing buffer. Only Cancel
    // (or the caller's cancellation) aborts it; either way it is joined before anything else
    // uses the model.
    let flushStart = ContinuousClock.now
    let originSample = max(0, min(count, Int(bufferStart * Self.sampleRate)))
    let window = Array(samples[originSample..<count])
    let decode = self.decode
    let flush = Task { try await decode(window) }
    flushTask = flush
    defer { if flushTask == flush { flushTask = nil } }
    do {
      let decoded = try await withTaskCancellationHandler {
        try await flush.value
      } onCancel: {
        flush.cancel()
      }
      // A decode that finished despite a cancel is still not released.
      guard isCurrent(run) else { return cancelledResult() }
      let tailMs = Self.milliseconds(since: flushStart)
      let realEnd = Float(window.count) / Self.sampleRate
      let bufferText = zip(decoded.segments, Self.spacedTexts(of: decoded))
        .filter { Float($0.0.startMs) / 1000 < realEnd }
        .reduce("") { Self.join($0, $1.1) }
      guard !bufferText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        return fallback(strategy: "streaming_buffer_empty_fallback", tailMs: tailMs)
      }
      // The scrolled-out prefix plus the buffer decode IS the transcript (committed text in
      // the buffer is re-decoded inside `bufferText`; never add both).
      return result(
        text: Self.join(scrolledOutText, bufferText), samplesCovered: count, tailDecodeMs: tailMs)
    } catch {
      _ = await flush.result  // a cancelled caller still waits for the native return
      guard isCurrent(run) else { return cancelledResult() }
      return fallback(
        strategy: "streaming_flush_failed", tailMs: Self.milliseconds(since: flushStart))
    }
  }

  /// This terminal may still publish: its run is the current one, nobody cancelled the session
  /// and the caller did not cancel the finalize.
  private func isCurrent(_ run: Int) -> Bool {
    run == generation && !cancelled && !Task.isCancelled
  }

  /// Cancels the loop AND a running flush, and returns only after both native runs physically
  /// ended. A finalize still in progress returns `streaming_cancelled`, never text.
  package func cancel() async {
    cancelled = true
    audioSamplesProvider = nil
    let flush = flushTask
    flush?.cancel()
    await stopLoop()
    _ = await flush?.result
  }

  /// Ends the loop: no cycle mutates state after this, an in-flight decode is cancelled (the
  /// executor aborts its native run) and awaited until that run has physically returned.
  /// Concurrent terminals share one drain.
  private func stopLoop() async {
    running = false
    finished = true
    if let loop = loopTask {
      loopTask = nil
      loop.cancel()
      let previous = drainTask
      drainTask = Task {
        await previous?.value
        await loop.value
      }
    }
    drainJoins += 1
    Self.resume(&drainJoinWaiters, reached: drainJoins)
    await drainTask?.value
  }

  // MARK: - Loop

  private func runLoop() async {
    let run = generation
    // `live` after every suspension: this loop's run is current and nothing ended it.
    var live: Bool { run == generation && running && !finished && !Task.isCancelled }
    while live {
      try? await Task.sleep(for: cadence)
      guard live, let provider = audioSamplesProvider else { break }
      let (samples, count) = await provider()
      guard live else { break }
      guard count - lastDecodeSampleCount >= minNewSamplesToDecode else { continue }

      // §3.5 holds whatever the decodes return: empty and failed decodes never apply, so the
      // bound is enforced on the captured audio before the window is cut.
      retain(realAudioEnd: Float(count) / Self.sampleRate)
      let originSample = max(0, min(count, Int(bufferStart * Self.sampleRate)))
      let origin = Float(originSample) / Self.sampleRate
      let window = Array(samples[originSample..<count])
      let started = ContinuousClock.now
      loopDecodeInFlight = true
      let native: TranscribeCppRunResult
      do {
        native = try await decode(window)
      } catch {
        guard live else { break }
        loopDecodeInFlight = false
        // The preview's refusals (heart busy, preempted) are expected every time the heart
        // works; it keeps its last text and tries again next cycle, so only the heart logs.
        if publication == nil {
          await AppLogger.shared.log(
            "Whisper streaming decode failed: \(error.localizedDescription)",
            level: .info, category: "WhisperStreaming")
        }
        guard live else { break }
        completeCycle()
        continue
      }
      // A terminal (or a newer run) that landed during the decode wins: drop this cycle.
      guard live else { break }
      loopDecodeInFlight = false
      let segments = zip(native.segments, Self.spacedTexts(of: native)).map {
        RollingSegment(
          start: origin + Float($0.0.startMs) / 1000, end: origin + Float($0.0.endMs) / 1000,
          text: $0.1)
      }
      if apply(segments, realAudioEnd: Float(count) / Self.sampleRate) {
        lastDecodeSampleCount = count
        // After the `live` check: a terminal that won the race never publishes.
        publishHypothesis()
      }
      decodeCount += 1
      totalDecodeTimeMs += Self.milliseconds(since: started)
      completeCycle()
    }
    // The aborted decode has returned; a newer run owns the flag otherwise.
    if run == generation { loopDecodeInFlight = false }
  }

  private func completeCycle() {
    cyclesCompleted += 1
    Self.resume(&cycleWaiters, reached: cyclesCompleted)
  }

  private static func resume(
    _ waiters: inout [(Int, CheckedContinuation<Void, Never>)], reached count: Int
  ) {
    let ready = waiters.filter { $0.0 <= count }.map(\.1)
    waiters.removeAll { $0.0 <= count }
    for waiter in ready { waiter.resume() }
  }

  // MARK: - Agreement and retention

  /// Applies one decode. Returns whether it produced a usable hypothesis ("heard"); an empty
  /// decode leaves the sample mark behind, so the next cycle retries that audio and finalize
  /// never treats it as heard.
  @discardableResult
  func apply(_ decoded: [RollingSegment], realAudioEnd: Float) -> Bool {
    // Real audio only: a segment starting in the padding is a hallucination; an end that ran
    // into the padding is clamped, so it can never claim audio that does not exist.
    let segments = decoded.filter { $0.start < realAudioEnd }.map {
      RollingSegment(start: $0.start, end: min($0.end, realAudioEnd), text: $0.text)
    }
    var units: [RollingUnit] = []
    for (index, segment) in segments.enumerated() {
      units += Self.units(of: segment.text, segment: index)
    }
    guard !units.isEmpty else { return false }

    // 1. CUT the committed prefix. The decode re-hears the committed words first, sometimes
    //    differently ("thermal" one cycle, "formal" the next). Align the committed words to
    //    the head of this decode allowing such revisions, and cut after the best alignment;
    //    units in a segment that starts after the committed end are new and are never cut.
    let committedEnd = committedInBuffer.last?.end ?? bufferStart
    let firstNew =
      units.firstIndex { segments[$0.segment].start >= committedEnd - Self.cutToleranceSec }
      ?? units.count
    let cut = Self.cutIndex(
      committed: committedInBuffer.map(\.unit.key), units: units.map(\.key), limit: firstNew)
    let fresh = Array(units[cut...])

    // 2. AGREE: the longest common unit prefix with the previous cycle, whatever the segment
    //    boundaries; then commit only the complete segments that prefix covers.
    var agreed = 0
    while agreed < fresh.count, agreed < previousHypothesis.count,
      fresh[agreed].key == previousHypothesis[agreed].key
    {
      agreed += 1
    }
    var commitCount = 0
    var index = 0
    while index < fresh.count {
      let segment = fresh[index].segment
      var next = index
      while next < fresh.count, fresh[next].segment == segment { next += 1 }
      guard next <= agreed else { break }
      commitCount = next
      index = next
    }
    if commitCount > 0 {
      for unit in fresh[0..<commitCount] {
        appendTranscript(&committedText, unit.text)
        committedInBuffer.append((unit, segments[unit.segment].end))
      }
      lastCommittedEnd = max(lastCommittedEnd, segments[fresh[commitCount - 1].segment].end)
    }
    let remaining = Array(fresh[commitCount...])
    heldBack = remaining.map { ($0, segments[$0.segment].end) }
    previousHypothesis = remaining

    // 3. RETAIN (§3.5).
    retain(realAudioEnd: realAudioEnd)
    return true
  }

  private func retain(realAudioEnd: Float) {
    guard realAudioEnd - bufferStart > Self.bufferTrimSec else { return }
    let retentionLine = realAudioEnd - Self.minRetainedBufferSec
    if let boundary = committedInBuffer.last(where: { $0.end <= retentionLine })?.end,
      boundary > bufferStart
    {
      for entry in committedInBuffer where entry.end <= boundary {
        appendTranscript(&scrolledOutText, entry.unit.text)
      }
      committedInBuffer.removeAll { $0.end <= boundary }
      bufferStart = boundary
      return
    }
    guard realAudioEnd - bufferStart > Self.defaultMaxUnconfirmedWindowSec + 5 else { return }
    // No safe committed boundary and the buffer is past one Whisper window plus headroom:
    // advance to the retention line anyway. Committed words before it scroll out; the
    // unstable words there never commit, and their agreement state goes with them.
    for entry in committedInBuffer where entry.end <= retentionLine {
      appendTranscript(&scrolledOutText, entry.unit.text)
    }
    committedInBuffer.removeAll { $0.end <= retentionLine }
    // No committed segment ended in the discarded span, so whatever was said there is not in
    // the committed text. Finalize hands the take to the batch decode rather than guess.
    // A held-back segment crossing the line has no word times, so none of its words can be
    // kept as agreement: the next hypothesis rebuilds agreement from retained audio only.
    discardedUnstableAudio = true
    heldBack = []
    previousHypothesis = []
    bufferStart = retentionLine
  }

  /// Appends to a transcript. Heart mode keeps it whole; preview mode keeps only its last
  /// `retentionLimit` characters, and builds them within that budget: the incoming piece is cut
  /// to the limit and only the room left is taken from the kept text, so no step ever joins
  /// more than the limit (plus one separating space).
  private func appendTranscript(_ text: inout String, _ piece: String) {
    guard let limit = publication?.retentionLimit else {
      text = Self.join(text, piece)
      return
    }
    let incoming = piece.count > limit ? String(piece.suffix(limit)) : piece
    let room = limit - incoming.count
    let kept = room > 0 ? String(text.suffix(room)) : ""
    text = String(Self.join(kept, incoming).suffix(limit))
  }

  /// Preview mode: hands the display the committed tail plus the held-back words, built from
  /// the end and bounded, only when it is non-empty and changed. An empty or wordless cycle
  /// never reaches here, so the last usable text stays up instead of blanking the pill.
  private func publishHypothesis() {
    guard let publication else { return }
    let limit = publication.retentionLimit
    // Built from the end within the budget: newest held-back word first, each cut to the limit,
    // stopping once the budget is full, so an oversized hypothesis is never assembled whole.
    var held = ""
    for entry in heldBack.reversed() {
      let unit = entry.unit.text
      held = Self.join(unit.count > limit ? String(unit.suffix(limit)) : unit, held)
      if held.count >= limit {
        held = String(held.suffix(limit))
        break
      }
    }
    let tail =
      held.count >= limit
      ? String(held.suffix(limit))
      : String(Self.join(String(committedText.suffix(limit - held.count)), held).suffix(limit))
    let shown = String(tail.drop { $0.isWhitespace })
    guard !shown.isEmpty, shown != lastPublished else { return }
    lastPublished = shown
    publication.onHypothesis(shown)
  }

  // MARK: - Alignment and spacing

  /// Where the committed words end in a decode's units: the prefix length `j <= limit` whose
  /// alignment to every committed word costs the fewest edits, the longest on a tie (a revised
  /// final committed word is consumed, not re-committed). Zero when nothing is committed.
  static func cutIndex(committed: [String], units: [String], limit: Int) -> Int {
    let m = min(units.count, limit)
    guard !committed.isEmpty, m > 0 else { return 0 }
    var previous = Array(0...m)
    for (i, word) in committed.enumerated() {
      var current = [i + 1] + [Int](repeating: 0, count: m)
      for j in 1...m {
        current[j] = min(
          previous[j - 1] + (word == units[j - 1] ? 0 : 1), previous[j] + 1, current[j - 1] + 1)
      }
      previous = current
    }
    var best = 0
    for j in 0...m where previous[j] <= previous[best] { best = j }
    return best
  }

  /// Each segment's text as it appears in the native full text, with the spacing before it.
  /// transcribe.cpp trims segment texts; the full text keeps the decoder's own spacing (none in
  /// unspaced scripts). A segment not found in order falls back to its trimmed text, which
  /// `join` then spaces as the script requires.
  static func spacedTexts(of run: TranscribeCppRunResult) -> [String] {
    let full = run.text
    var cursor = full.startIndex
    return run.segments.map { segment in
      let piece = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !piece.isEmpty, let found = full.range(of: piece, range: cursor..<full.endIndex)
      else { return segment.text }
      defer { cursor = found.upperBound }
      return String(full[cursor..<found.upperBound])
    }
  }

  /// Joins two pieces of transcript, adding one space only where neither piece supplies one
  /// and both sides are words of a spaced script; never inside Chinese, Japanese, Thai and the
  /// other unspaced scripts, and never before closing punctuation.
  static func join(_ a: String, _ b: String) -> String {
    guard let last = a.last, let first = b.first else { return a + b }
    if last.isWhitespace || first.isWhitespace { return a + b }
    guard first.isLetter || first.isNumber, !isUnspaced(first), !isUnspaced(last) else {
      return a + b
    }
    return a + " " + b
  }

  private static func isUnspaced(_ character: Character) -> Bool {
    guard let scalar = character.unicodeScalars.first?.value else { return false }
    let ranges: [ClosedRange<UInt32>] = [
      0x0E00...0x0EFF,  // Thai, Lao
      0x1000...0x109F,  // Myanmar
      0x1780...0x17FF,  // Khmer
      0x3000...0x30FF,  // CJK punctuation, Hiragana, Katakana
      0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF,  // Han
      0xFF00...0xFFEF,  // full-width forms
    ]
    return ranges.contains { $0.contains(scalar) }
  }

  // MARK: - Units

  /// Splits text into word units that keep the spacing and punctuation before each word;
  /// trailing punctuation joins the last unit. Word boundaries come from the system's
  /// Unicode word segmentation, which also splits unspaced scripts (CJK, Thai) into words.
  /// Keys compare words case-insensitively without the surrounding punctuation.
  static func units(of text: String, segment: Int) -> [RollingUnit] {
    var ranges: [Range<String.Index>] = []
    text.enumerateSubstrings(in: text.startIndex..<text.endIndex, options: .byWords) {
      _, range, _, _ in
      ranges.append(range)
    }
    guard !ranges.isEmpty else { return [] }
    var units: [RollingUnit] = []
    var cursor = text.startIndex
    for (index, range) in ranges.enumerated() {
      let end = index == ranges.count - 1 ? text.endIndex : range.upperBound
      units.append(
        RollingUnit(
          text: String(text[cursor..<end]), key: text[range].lowercased(), segment: segment))
      cursor = end
    }
    return units
  }

  // MARK: - Results

  private func result(text: String, samplesCovered: Int, tailDecodeMs: Int) -> IncrementalResult {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    return IncrementalResult(
      text: trimmed.isEmpty ? nil : trimmed, samplesCovered: samplesCovered,
      decodeCount: decodeCount, totalDecodeTimeMs: totalDecodeTimeMs,
      accepted: !trimmed.isEmpty, strategy: "streaming", tailDecodeMs: tailDecodeMs,
      stopWhileDecodeInFlight: stoppedMidDecode)
  }

  /// `accepted: false`: the adapter re-transcribes the whole recording in batch. The committed
  /// prefix rides along for diagnostics only.
  private func cancelledResult() -> IncrementalResult {
    IncrementalResult(
      text: nil, samplesCovered: 0, decodeCount: decodeCount,
      totalDecodeTimeMs: totalDecodeTimeMs, accepted: false, strategy: "streaming_cancelled",
      tailDecodeMs: 0, stopWhileDecodeInFlight: stoppedMidDecode)
  }

  private func fallback(strategy: String, tailMs: Int) -> IncrementalResult {
    let trimmed = committedText.trimmingCharacters(in: .whitespacesAndNewlines)
    return IncrementalResult(
      text: trimmed.isEmpty ? nil : committedText, samplesCovered: 0,
      decodeCount: decodeCount, totalDecodeTimeMs: totalDecodeTimeMs, accepted: false,
      strategy: strategy, tailDecodeMs: tailMs, stopWhileDecodeInFlight: stoppedMidDecode)
  }

  static func rms(_ samples: [Float]) -> Float {
    guard !samples.isEmpty else { return 0 }
    return (samples.reduce(Float(0)) { $0 + $1 * $1 } / Float(samples.count)).squareRoot()
  }

  private static func milliseconds(since start: ContinuousClock.Instant) -> Int {
    Int((ContinuousClock.now - start) / .milliseconds(1))
  }
}
