import Foundation

/// One live engine session's input timeline mapped onto written audio (#4355 plan §3.1).
///
/// An engine that takes input without start times (Apple's `AnalyzerInput(buffer:)`) reports
/// result times on the concatenation of the input it actually CONSUMED. This map records that
/// concatenation: each consumed input is committed in order at the absolute input frame where
/// it begins, with the written slices it carries. Projection turns a result's session-local
/// seconds into a written span only when the whole range is known, contiguous audio of one
/// recording, track and run; anything else is nil (unresolved), never stretched or guessed.
///
/// A value with no locking: its owner serializes every call (the Apple input recorder holds it
/// under one lock with the pending inputs). It holds frame counts and spans only, never audio.
///
/// Offsets are absolute for the session's life: pruning drops old records without rebasing,
/// and a range that begins before the pruned point projects to nil.
package struct MeetingAudioFeedMap: Sendable {
  private struct Record: Sendable {
    let start: Int
    let frames: Int
    /// Positions relative to this record's first frame; empty means unpositioned.
    let slices: [MeetingLiveAudioSlice]
  }

  /// The session's input rate, frames per second.
  package let sampleRate: Double
  private var records: [Record] = []
  /// Input frames committed so far: where the next consumed input begins.
  package private(set) var consumedFrames = 0
  /// Records ending at or before this frame were pruned.
  package private(set) var prunedThrough = 0

  package init(sampleRate: Double) {
    self.sampleRate = sampleRate
  }

  /// Records kept, for storage reports and tests.
  package var recordCount: Int { records.count }
  /// Slices kept across all records, for storage reports and tests.
  package var sliceCount: Int { records.reduce(0) { $0 + $1.slices.count } }

  /// Commits the next consumed input: `frames` at the session rate, and the written slices
  /// that cover them one to one (frame offsets equal sample offsets), or nil when that
  /// correspondence is not established (the input is then unpositioned time).
  package mutating func commit(frames: Int, slices: [MeetingLiveAudioSlice]?) {
    guard frames > 0 else { return }
    let kept = (slices ?? []).filter { $0.offset >= 0 && $0.offset + $0.count <= frames }
    records.append(Record(start: consumedFrames, frames: frames, slices: kept))
    consumedFrames += frames
  }

  /// Forgets records that end at or before `frame`; later offsets are unchanged.
  package mutating func prune(before frame: Int) {
    guard frame > prunedThrough else { return }
    let cut = records.prefix { $0.start + $0.frames <= frame }.count
    guard cut > 0 else { return }
    prunedThrough = records[cut - 1].start + records[cut - 1].frames
    records.removeFirst(cut)
  }

  /// The input frame of a session-local time: `floor` for a range start, `ceiling` for its end.
  package func frame(atSeconds seconds: Double, roundingUp: Bool) -> Int {
    let exact = seconds * sampleRate
    return Int(roundingUp ? exact.rounded(.up) : exact.rounded(.down))
  }

  /// The written span of `[startSeconds, endSeconds)` in this session's input time, or nil
  /// unless every frame of it is committed, positioned, unpruned and contiguous written audio
  /// of one recording, track and run.
  package func project(startSeconds: Double, endSeconds: Double) -> MeetingAudioSpan? {
    // Ordered before quantization: an empty or reversed range never rounds into a frame.
    guard startSeconds.isFinite, endSeconds.isFinite, startSeconds >= 0,
      endSeconds > startSeconds
    else { return nil }
    return project(
      startFrame: frame(atSeconds: startSeconds, roundingUp: false),
      endFrame: frame(atSeconds: endSeconds, roundingUp: true))
  }

  /// The written span of input frames `[startFrame, endFrame)`, under the same rules as the
  /// seconds form. #4355 PR C: the live speaker session reports whole 10 ms frames as exact
  /// frame indices, so it projects here and never round-trips through seconds.
  package func project(startFrame start: Int, endFrame end: Int) -> MeetingAudioSpan? {
    guard start >= 0, end > start, start >= prunedThrough, end <= consumedFrames else { return nil }
    var first: MeetingAudioSpan?
    var expected: Int?  // the next written sample the range must continue with
    var position = start  // the next input frame the range must cover
    for record in records where record.start + record.frames > position && record.start < end {
      guard record.start <= position else { return nil }  // a hole between records
      let localEnd = min(end, record.start + record.frames) - record.start
      var local = position - record.start
      for slice in record.slices where slice.offset + slice.count > local && slice.offset < localEnd
      {
        guard slice.offset <= local else { return nil }  // unpositioned frames inside the range
        let take = min(localEnd, slice.offset + slice.count) - local
        let written = slice.span.startSample + (local - slice.offset)
        if let anchor = first {
          guard slice.span.recording == anchor.recording, slice.span.track == anchor.track,
            slice.span.run == anchor.run, written == expected
          else { return nil }
        } else {
          first = MeetingAudioSpan(
            recording: slice.span.recording, track: slice.span.track, run: slice.span.run,
            startSample: written, sampleCount: 1)
        }
        expected = written + take
        local += take
      }
      guard local == localEnd else { return nil }  // unpositioned tail of this record
      position = record.start + localEnd
    }
    guard position == end, let anchor = first, let next = expected else { return nil }
    return MeetingAudioSpan(
      recording: anchor.recording, track: anchor.track, run: anchor.run,
      startSample: anchor.startSample, sampleCount: next - anchor.startSample)
  }
}
