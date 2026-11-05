import AudioToolbox
import CoreAudio
import EnviousWisprCore
import Foundation

/// A stretch of acquisition time, half open: `[start, end)`, during which the microphone track
/// is written as silence (#4248). A nil `end` is still open. Audio only receives these times;
/// which call app, which button and why belong to the AppKit follower. Order is judged by host
/// ticks within one recording; provenance never changes which samples are silenced.
public struct MeetingSilenceInterval: Sendable, Equatable {
  public let start: MeetingAcquisitionTime
  public let end: MeetingAcquisitionTime?

  public init(start: MeetingAcquisitionTime, end: MeetingAcquisitionTime?) {
    self.start = start
    self.end = end
  }
}

/// One mute decision step, run on the microphone writer's queue (#4248 plan §18). It receives
/// that queue's clock reading (observed) and C (the end of audio released for good; nil before
/// the first release) and returns the new silence intervals, or nil to keep the current ones. It
/// runs synchronously and must not wait on another thread.
public typealias MeetingSilenceStep =
  @Sendable (_ queueNow: MeetingAcquisitionTime, _ released: MeetingAcquisitionTime?) ->
  [MeetingSilenceInterval]?

/// One written slice of a track, as the live observer gets it after the writer placed it
/// (#4355 plan §3.1): where it sits on the written timeline, and when its first sample was
/// acquired. The two are separate domains and neither is derived from the other.
public struct MeetingReleasedChunk: Sendable, Equatable {
  /// The written samples this slice is: masked, trimmed and placed. Its count equals the
  /// slice's sample count.
  public let span: MeetingAudioSpan
  /// When the slice's first sample was acquired, with the provenance its producer gave.
  public let acquired: MeetingAcquisitionTime
  /// Audio was dropped at the handoff before this slice.
  public let afterDrop: Bool
  /// The producer said this slice does not continue the previous one.
  public let sourceBreak: Bool

  public init(
    span: MeetingAudioSpan, acquired: MeetingAcquisitionTime, afterDrop: Bool, sourceBreak: Bool
  ) {
    self.span = span
    self.acquired = acquired
    self.afterDrop = afterDrop
    self.sourceBreak = sourceBreak
  }
}

/// One accepted chunk before placement: what the writer's handoff and the hold carry. It has no
/// written position yet, so it never claims one.
struct MeetingHeldChunk: Sendable, Equatable {
  let acquired: MeetingAcquisitionTime
  let afterDrop: Bool
  let sourceBreak: Bool
}

/// The microphone hold of one `MeetingTrackWriter` (#4248 plan §3.3). Accepted audio waits here
/// for `hold`, so a mute reading that arrives late can still decide it; then the samples whose
/// times fall inside a silence interval are replaced with zeros and the chunk is released, in
/// order, with its original host time, frame count, drop and run-break flags.
///
/// **Ownership.** Confined to the writer's serial queue: every method runs there, so it needs no
/// lock and is not thread-safe. Its sample, chunk and interval storage is reserved once and
/// reused; it keeps no pointer into the writer's handoff buffers or the caller's audio.
///
/// **Release.** A chunk is due once its last sample is `hold` old. Releasing is irreversible:
/// `released` (the plan's C) moves to the chunk's end and never moves back, and an interval
/// update can no longer change that audio. When storage is full, the oldest chunks are released
/// early with the intervals known then, so accepted audio is never discarded.
///
/// **Decisions split at C.** Chunk start times come from each chunk's own capture time, so a
/// later chunk can begin before an earlier one ended (`MeetingRecorder`'s capture closure stamps
/// each start independently). One rule covers replacement, the released prefix and retirement:
/// - Time at or after C is judged by the latest `setIntervals` (`pending`).
/// - Time before C is judged by what was decided when that time was first released (`frozen`):
///   releasing a chunk freezes `pending` over the time it moved C across. An update can never
///   change a decision before C, in either direction.
/// - A frozen decision is kept while any held chunk starts before its end, and for
///   `lateArrival` behind C for audio not yet accepted. That is the arrival contract: audio
///   stamped more than `lateArrival` before C when it arrives is judged as live for that part
///   and counted in `lateFrames`. Pending decisions that end at or before C are never read again.
final class MeetingMicrophoneSilence {
  /// The hold's own half-open tick stretch; `end == .max` is open. Private arithmetic only: the
  /// typed `MeetingSilenceInterval` is decoded into it once, in `setIntervals`.
  struct TickSpan: Equatable {
    let start: UInt64
    let end: UInt64
  }

  /// Receives each released chunk on the writer's queue: the raw samples and, for a paired
  /// hold, the cleaned copy (nil when the producer gave none for this chunk). Both were masked
  /// by the same decisions at the same samples. The buffers are valid only during the call.
  typealias Emit = (UnsafeBufferPointer<Float>, UnsafeBufferPointer<Float>?, MeetingHeldChunk) -> Void

  private struct Held {
    var start: Int
    var count: Int
    var hostTime: UInt64
    var provenance: MeetingAcquisitionTime.Provenance
    var afterDrop: Bool
    var sourceBreak: Bool
    /// A paired hold only: the producer gave a cleaned copy of exactly this chunk.
    var hasCleaned: Bool
    /// The arrival contract's cutoff, fixed when the chunk was accepted: its samples before this
    /// are live, never frozen-masked.
    var liveBefore: UInt64
  }

  let recording: UUID
  let holdTicks: UInt64
  /// The arrival contract's bound: frozen decisions are kept this far behind C for audio that
  /// has not arrived yet. Audio stamped earlier than that when it arrives counts as late.
  let lateArrivalTicks = MeetingMicrophoneSilence.ticks(nanos: 1_000_000_000)
  let sampleCapacity: Int
  let chunkCapacity: Int
  let intervalCapacity: Int

  private var samples: [Float] = []
  /// #4355 PR B: the cleaned copy, sample for sample beside `samples`; nil for an unpaired hold.
  private var cleaned: [Float]?
  private var chunks: [Held] = []
  /// The latest decisions, read only for time at or after C.
  private var pending: [TickSpan] = []
  /// Decisions for time before C, as they stood when that time was released.
  private var frozen: [TickSpan] = []

  /// C: the end host ticks of the last released audio; 0 before the first release.
  private var releasedTicks: UInt64 = 0
  /// The provenance of the chunk whose end set C.
  private var releasedProvenance: MeetingAcquisitionTime.Provenance = .estimated
  /// C as an acquisition time; nil before the first release.
  var released: MeetingAcquisitionTime? {
    releasedTicks == 0
      ? nil
      : MeetingAcquisitionTime(
        recording: recording, hostTicks: releasedTicks, provenance: releasedProvenance)
  }
  /// Frames written as zeros.
  private(set) var silencedFrames = 0
  /// Intervals beyond `intervalCapacity` that were left out (their audio stays live).
  private(set) var intervalOverflows = 0
  /// Chunks released before they were due because storage was full.
  private(set) var forcedReleases = 0
  /// Frames that arrived stamped more than `lateArrival` before C (judged as live).
  private(set) var lateFrames = 0

  /// `paired`: the hold also carries a cleaned copy of every chunk (#4355 PR B), reserved to the
  /// same capacity and given the same release, masking and order.
  init(
    recording: UUID, holdSeconds: Double, sampleCapacity: Int, chunkCapacity: Int,
    intervalCapacity: Int = 64, paired: Bool = false
  ) {
    self.recording = recording
    holdTicks = Self.ticks(nanos: UInt64(max(0, holdSeconds) * 1_000_000_000))
    self.sampleCapacity = max(1, sampleCapacity)
    self.chunkCapacity = max(1, chunkCapacity)
    self.intervalCapacity = max(1, intervalCapacity)
    samples.reserveCapacity(self.sampleCapacity)
    if paired {
      var copy: [Float] = []
      copy.reserveCapacity(self.sampleCapacity)
      cleaned = copy
    }
    chunks.reserveCapacity(self.chunkCapacity)
    pending.reserveCapacity(self.intervalCapacity)
    frozen.reserveCapacity(self.intervalCapacity)
  }

  /// Runs before every release decision, forced releases included, so the latest intervals
  /// (for example an expired mute) decide the audio about to leave. Set once by the writer.
  var beforeRelease: (() -> Void)?

  var isEmpty: Bool { chunks.isEmpty }

  /// When the oldest held chunk becomes due; nil when nothing is held. Calculated, so estimated.
  var nextDue: MeetingAcquisitionTime? {
    chunks.first.map {
      MeetingAcquisitionTime(
        recording: recording, hostTicks: end(of: $0) &+ holdTicks, provenance: .estimated)
    }
  }

  /// Replaces the decisions for time at or after C, merged where they overlap or touch and kept
  /// in order. Time before C keeps its frozen decision. Beyond capacity, the latest are left out
  /// and counted, so their audio stays live.
  /// Intervals of another recording are not this hold's and are left out.
  func setIntervals(_ new: [MeetingSilenceInterval]) {
    pending.removeAll(keepingCapacity: true)
    let spans = new.compactMap { interval -> TickSpan? in
      guard interval.start.recording == recording,
        interval.end.map({ $0.recording == recording }) ?? true
      else { return nil }
      return TickSpan(start: interval.start.hostTicks, end: interval.end?.hostTicks ?? .max)
    }
    Self.merge(spans.filter { $0.end > releasedTicks }, into: &pending, capacity: intervalCapacity) {
      intervalOverflows += 1
    }
  }

  /// Frozen decisions ending at or before this can no longer reach held or arriving audio.
  private var retirementHorizon: UInt64 {
    let behind = releasedTicks > lateArrivalTicks ? releasedTicks - lateArrivalTicks : 0
    let oldestHeld = chunks.lazy.map(\.hostTime).min() ?? behind
    return min(oldestHeld, behind)
  }

  /// Adds `intervals` to the sorted, disjoint `list`, merging overlaps; `overflow` runs for each
  /// one left out at capacity.
  private static func merge(
    _ intervals: [TickSpan], into list: inout [TickSpan],
    capacity: Int, overflow: () -> Void
  ) {
    var combined = list
    combined.append(contentsOf: intervals.filter { $0.end > $0.start })
    combined.sort { $0.start < $1.start }
    list.removeAll(keepingCapacity: true)
    for interval in combined {
      if let last = list.last, interval.start <= last.end {
        list[list.count - 1] = TickSpan(start: last.start, end: max(last.end, interval.end))
        continue
      }
      guard list.count < capacity else {
        overflow()
        continue
      }
      list.append(interval)
    }
  }

  /// Holds a copy of `frames` (and, in a paired hold, of `cleanedFrames`, which must have the
  /// same count; another count, or nil, holds the chunk without a cleaned copy). A chunk larger
  /// than the free room is held in pieces, each with the acquisition time of its first sample;
  /// room is made by releasing the oldest chunks early.
  func accept(
    _ frames: UnsafeBufferPointer<Float>, cleaned cleanedFrames: UnsafeBufferPointer<Float>? = nil,
    acquired: MeetingAcquisitionTime, afterDrop: Bool, sourceBreak: Bool, emit: Emit
  ) {
    let pair = cleanedFrames.flatMap { $0.count == frames.count ? $0 : nil }
    assert(acquired.recording == recording, "audio of another recording reached this hold")
    let hostTime = acquired.hostTicks
    let liveBefore = releasedTicks > lateArrivalTicks ? releasedTicks - lateArrivalTicks : 0
    // The same boundary rule as silencing: a sample is late when its time is before the cutoff.
    lateFrames += Self.silencedRange(
      of: TickSpan(start: 0, end: liveBefore), chunkHostTime: hostTime,
      count: frames.count
    ).count
    var offset = 0
    while offset < frames.count {
      if chunks.count >= chunkCapacity || samples.count >= sampleCapacity {
        releaseFront(1, emit: emit)
        forcedReleases += 1
        continue
      }
      let take = min(frames.count - offset, sampleCapacity - samples.count)
      let first = offset == 0
      chunks.append(
        Held(
          start: samples.count, count: take,
          hostTime: first ? hostTime : hostTime &+ Self.ticks(forSamples: offset),
          provenance: acquired.provenance, afterDrop: first && afterDrop, sourceBreak: first && sourceBreak,
          hasCleaned: pair != nil, liveBefore: liveBefore))
      samples.append(contentsOf: UnsafeBufferPointer(rebasing: frames[offset..<(offset + take)]))
      if cleaned != nil {
        // Without a cleaned copy the slot holds raw, so the two stay the same length; the chunk
        // says it has none and is emitted without one.
        let source = pair ?? frames
        cleaned!.append(contentsOf: UnsafeBufferPointer(rebasing: source[offset..<(offset + take)]))
      }
      offset += take
    }
  }

  /// Releases every chunk whose last sample is at least `hold` old at `time`.
  func releaseDue(now time: MeetingAcquisitionTime, emit: Emit) {
    assert(time.recording == recording, "another recording's clock reached this hold")
    let now = time.hostTicks
    var due = 0
    while due < chunks.count, end(of: chunks[due]) &+ holdTicks <= now { due += 1 }
    releaseFront(due, emit: emit)
  }

  /// Releases everything held, with the intervals known now (Stop, close, `waitUntilWritten`).
  func releaseAll(emit: Emit) {
    releaseFront(chunks.count, emit: emit)
  }

  private func releaseFront(_ count: Int, emit: Emit) {
    guard count > 0 else { return }
    beforeRelease?()
    var consumed = 0
    // Moved out and back (no copy): the twin storage stays the one reserved at init.
    var copy: [Float] = []
    let paired = cleaned != nil
    if paired { swap(&copy, &cleaned!) }
    defer { if paired { swap(&copy, &cleaned!) } }
    samples.withUnsafeMutableBufferPointer { all in
      copy.withUnsafeMutableBufferPointer { twin in
      for held in chunks[0..<count] {
        let range = held.start..<(held.start + held.count)
        let frames = UnsafeMutableBufferPointer(rebasing: all[range])
        let twinFrames = twin.isEmpty ? nil : UnsafeMutableBufferPointer(rebasing: twin[range])
        let chunkEnd = end(of: held)
        let cut = min(max(held.hostTime, releasedTicks), chunkEnd)
        // Before C: the frozen decisions. From C on: the latest, which this release freezes. The
        // cleaned copy takes the same zeros at the same samples.
        silence(
          frames, twinFrames, held.hostTime, frozen, from: max(held.hostTime, held.liveBefore),
          to: cut)
        silence(frames, twinFrames, held.hostTime, pending, from: cut, to: chunkEnd)
        // Freezes from the previous C, not from this chunk's start: capture stamps chunks by
        // arrival, so a few ticks can separate one chunk's end from the next one's start. Freezing
        // that gap too keeps a long mute one frozen decision; split at every gap, a mute filled
        // the frozen storage within one late-arrival second and left late audio live (#4248).
        let freezeFrom = min(cut, releasedTicks)
        if chunkEnd > freezeFrom {
          let decided = pending.compactMap { Self.clip($0, from: freezeFrom, to: chunkEnd) }
          Self.merge(decided, into: &frozen, capacity: intervalCapacity) { intervalOverflows += 1 }
        }
        if chunkEnd > releasedTicks {
          releasedTicks = chunkEnd
          releasedProvenance = held.provenance
        }
        emit(
          UnsafeBufferPointer(frames),
          held.hasCleaned ? twinFrames.map { UnsafeBufferPointer($0) } : nil,
          MeetingHeldChunk(
            acquired: MeetingAcquisitionTime(
              recording: recording, hostTicks: held.hostTime, provenance: held.provenance),
            afterDrop: held.afterDrop, sourceBreak: held.sourceBreak))
        consumed = held.start + held.count
      }
      }
    }
    samples.removeSubrange(0..<consumed)
    if paired { copy.removeSubrange(0..<consumed) }
    chunks.removeSubrange(0..<count)
    for i in chunks.indices { chunks[i].start -= consumed }
    let horizon = retirementHorizon
    frozen.removeAll { $0.end <= horizon }
    pending.removeAll { $0.end <= releasedTicks }
  }

  /// Zeroes the samples of a chunk (and of its cleaned twin, at the same indices) whose times lie
  /// in `[from, to)` and in one of `mask`.
  private func silence(
    _ frames: UnsafeMutableBufferPointer<Float>, _ twin: UnsafeMutableBufferPointer<Float>?,
    _ chunkHostTime: UInt64, _ mask: [TickSpan], from: UInt64, to: UInt64
  ) {
    guard to > from else { return }
    for interval in mask {
      guard let part = Self.clip(interval, from: from, to: to) else { continue }
      let range = Self.silencedRange(of: part, chunkHostTime: chunkHostTime, count: frames.count)
      for i in range { frames[i] = 0 }
      if let twin { for i in range { twin[i] = 0 } }
      silencedFrames += range.count
    }
  }

  private static func clip(_ interval: TickSpan, from: UInt64, to: UInt64) -> TickSpan? {
    let start = max(interval.start, from)
    let end = min(interval.end, to)
    return end > start ? TickSpan(start: start, end: end) : nil
  }

  private func end(of held: Held) -> UInt64 {
    held.hostTime &+ Self.ticks(forSamples: held.count)
  }

  // MARK: - Sample boundaries

  /// 1 s / 16,000 = 62,500 ns exactly.
  static let nanosPerSample = UInt64(1_000_000_000 / Int(MeetingAudioFormat.sampleRate))

  /// The sample indexes of a chunk inside `interval`. Sample `i` is at
  /// `chunkHostTime + i × 62.5 µs`; it is silenced when `start <= its time < end`.
  static func silencedRange(
    of interval: TickSpan, chunkHostTime: UInt64, count: Int
  ) -> Range<Int> {
    let first =
      interval.start <= chunkHostTime ? 0 : index(atOrAfter: interval.start - chunkHostTime)
    let last: Int
    if interval.end == .max {
      last = count
    } else if interval.end <= chunkHostTime {
      last = 0
    } else {
      last = index(atOrAfter: interval.end - chunkHostTime)
    }
    let lower = min(first, count)
    let upper = min(max(last, lower), count)
    return lower..<upper
  }

  /// The first sample index whose time offset is at least `ticks`.
  private static func index(atOrAfter ticks: UInt64) -> Int {
    let nanos = AudioConvertHostTimeToNanos(ticks)
    let whole = nanos / nanosPerSample
    let index = nanos % nanosPerSample == 0 ? whole : whole + 1
    return index > UInt64(Int.max) ? Int.max : Int(index)
  }

  static func ticks(forSamples count: Int) -> UInt64 {
    ticks(nanos: UInt64(count) * nanosPerSample)
  }

  static func ticks(nanos: UInt64) -> UInt64 { AudioConvertNanosToHostTime(nanos) }
}
