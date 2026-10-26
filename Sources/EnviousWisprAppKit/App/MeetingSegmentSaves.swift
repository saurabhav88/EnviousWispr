import EnviousWisprCore
import os

/// #4118: the segment list of one meeting while it records. Every closed segment rewrote the
/// whole `meeting.json`, which lists every segment, so a burst of short segments cost O(n²)
/// (34 GB of writes in 9 minutes in a real call). Here the full list stays in memory and is
/// handed over once, at Stop or quit; while recording, the record carries only a checkpoint
/// (the newest segment per track, enough for the duration History shows), saved at most once
/// per `spacingMs` of recorded audio. The audio files stay the recovery authority: the pass
/// rebuilds the list from the folder.
///
/// Segments are taken in on the recorder's callback thread under a lock, so a quit, which
/// blocks the main actor, still sees every segment closed before `finish()`.
final class MeetingSegmentSaves: Sendable {
  /// Half a 60 s segment: normal recording saves at every segment close.
  static let spacingMs = 30_000
  /// A track closing more than `rateLimit` segments within `rateWindowMs` of recorded time is
  /// logged (normal is one a minute). Diagnostic only; nothing stops.
  static let rateWindowMs = 60_000
  static let rateLimit = 10

  /// What one main-actor update does.
  struct Update: Sendable, Equatable {
    /// The newest segment per track.
    let checkpoint: [MeetingTrackKind: [MeetingSegmentInfo]]
    let shouldSave: Bool
    /// Tracks over the rate limit since the last update, with the count seen.
    let notes: [MeetingTrackKind: Int]
  }

  private struct Rate: Sendable {
    var highWater = 0
    var recentEnds: [Int] = []
    var lastNoteAt: Int?
  }

  private struct State: Sendable {
    var inventory: [MeetingTrackKind: [MeetingSegmentInfo]] = [:]
    var latest: [MeetingTrackKind: MeetingSegmentInfo] = [:]
    var rates: [MeetingTrackKind: Rate] = [:]
    var notes: [MeetingTrackKind: Int] = [:]
    /// The latest end time on any track: tracks interleave, so spacing never uses the last
    /// arrival.
    var highWater = 0
    var lastSavedHighWater: Int?
    var updateScheduled = false
    var finished = false
  }

  private let state = OSAllocatedUnfairLock(initialState: State())

  /// On the recorder's callback thread. True when the caller must schedule a main-actor
  /// `update()`; one is scheduled per burst, never one per segment. False after `finish()`.
  func append(track: MeetingTrackKind, info: MeetingSegmentInfo) -> Bool {
    state.withLock { value in
      guard !value.finished else { return false }
      value.inventory[track, default: []].append(info)
      if value.latest[track].map({ info.endMs >= $0.endMs }) ?? true {
        value.latest[track] = info
      }
      value.highWater = max(value.highWater, info.endMs)

      var rate = value.rates[track] ?? Rate()
      rate.highWater = max(rate.highWater, info.endMs)
      rate.recentEnds.removeAll { $0 <= rate.highWater - Self.rateWindowMs }
      rate.recentEnds.append(info.endMs)
      // One more than the limit is enough to prove the limit was passed.
      if rate.recentEnds.count > Self.rateLimit + 1 {
        rate.recentEnds.removeFirst(rate.recentEnds.count - Self.rateLimit - 1)
      }
      if rate.recentEnds.count > Self.rateLimit,
        rate.lastNoteAt.map({ rate.highWater - $0 >= Self.rateWindowMs }) ?? true
      {
        value.notes[track] = rate.recentEnds.count
        rate.lastNoteAt = rate.highWater
      }
      value.rates[track] = rate

      guard !value.updateScheduled else { return false }
      value.updateScheduled = true
      return true
    }
  }

  /// On the main actor, for the update `append` asked for.
  func update() -> Update {
    state.withLock { value in
      value.updateScheduled = false
      let due =
        !value.finished && !value.latest.isEmpty
        && (value.lastSavedHighWater.map { value.highWater - $0 >= Self.spacingMs } ?? true)
      if due { value.lastSavedHighWater = value.highWater }
      let notes = value.notes
      value.notes.removeAll()
      return Update(
        checkpoint: value.latest.mapValues { [$0] }, shouldSave: due, notes: notes)
    }
  }

  /// The newest segment per track: what any save of the recording meeting writes.
  func checkpoint() -> [MeetingTrackKind: [MeetingSegmentInfo]] {
    state.withLock { $0.latest.mapValues { [$0] } }
  }

  /// Closes admission and hands over every segment, in arrival order per track.
  func finish() -> [MeetingTrackKind: [MeetingSegmentInfo]] {
    state.withLock { value in
      value.finished = true
      let inventory = value.inventory
      value.inventory = [:]
      return inventory
    }
  }
}
