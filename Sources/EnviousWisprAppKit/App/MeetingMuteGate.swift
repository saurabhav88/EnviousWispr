import EnviousWisprAudio
import EnviousWisprCore
import EnviousWisprServices
import Foundation
import os

/// One recording's mute follower, run on the microphone writer's queue (#4248 plan §18).
///
/// The MainActor never changes the follower. It turns each input into a `MeetingSilenceStep`
/// (`step(_:)`) and hands that to the recorder; the writer runs it with its own clock reading
/// (D) and C, so a reading is judged at the moment it reaches the hold and its intervals apply
/// before any later audio leaves. `clock` runs before every release, so a reading that expired
/// is closed at the queue's time even when no new reading comes. After each step that changes
/// something, `publish` receives a `Snapshot` on the writer's queue; the receiver hops to the
/// MainActor and keeps only newer ones (`SnapshotFence`).
///
/// The lock is never contended (the writer runs one step at a time); it makes the class
/// safely `Sendable` without relying on that. Nothing here waits on another thread, and the
/// gate keeps no reference to the writer, so the writer holding `clock` forms no cycle.
final class MeetingMuteGate: Sendable {
  enum Input: Sendable, Equatable {
    /// One reading copied at `copyStart` (T) and ending at `copyEnd` (E), received by the
    /// MainActor at `received` (M). M is for the trace only; D comes from the writer.
    case reading(
      CallSelfMute, copyStart: UInt64, copyEnd: UInt64, received: UInt64, generation: UInt64)
    case bind(CallSpeakerSurface, generation: UInt64)
    case unbind
    case setEnabled(Bool, at: UInt64)
    /// Time passed with no reading (the session tick); expiry is judged at the queue's time.
    case advance
    case end
  }

  /// One reading's decision, in host ticks, for the DEBUG timing trace.
  struct Trace: Sendable, Equatable {
    let copyStart: UInt64
    let copyEnd: UInt64
    let received: UInt64
    let delivered: UInt64
    let released: UInt64
    let outcome: MeetingMuteFollower.Outcome
  }

  struct Snapshot: Sendable, Equatable {
    let recording: UUID
    let seq: UInt64
    let generation: UInt64?
    let state: MeetingMuteFollower.State
    let missed: MeetingMuteFollower.Missed
    let trace: Trace?
  }

  /// Keeps the newest snapshot of one recording; snapshots hop to the MainActor in no
  /// guaranteed order.
  struct SnapshotFence: Sendable {
    let recording: UUID
    private(set) var lastSeq: UInt64 = 0

    init(recording: UUID) { self.recording = recording }

    /// Whether `snapshot` is this recording's and newer than every one accepted so far.
    mutating func accept(_ snapshot: Snapshot) -> Bool {
      guard snapshot.recording == recording, snapshot.seq > lastSeq else { return false }
      lastSeq = snapshot.seq
      return true
    }
  }

  private struct Inner: Sendable {
    var follower: MeetingMuteFollower
    var generation: UInt64?
    var seq: UInt64 = 0
    /// The intervals last handed to the writer; nil before the first.
    var applied: [MeetingSilenceInterval]?
    var lastState: MeetingMuteFollower.State
    var lastMissed = MeetingMuteFollower.Missed()
  }

  let recording: UUID
  private let inner: OSAllocatedUnfairLock<Inner>
  private let publish: @Sendable (Snapshot) -> Void

  init(
    recording: UUID, follower: MeetingMuteFollower,
    publish: @escaping @Sendable (Snapshot) -> Void
  ) {
    self.recording = recording
    self.publish = publish
    inner = OSAllocatedUnfairLock(
      initialState: Inner(follower: follower, lastState: follower.state))
  }

  /// The step that applies `input` on the writer's queue.
  func step(_ input: Input) -> MeetingSilenceStep {
    { [self] now, released in run(input, now: now, released: released) }
  }

  /// The step run before every release: expiry only.
  var clock: MeetingSilenceStep {
    { [self] now, released in run(nil, now: now, released: released) }
  }

  private func run(_ input: Input?, now: UInt64, released: UInt64)
    -> [MeetingSilenceInterval]?
  {
    let (intervals, snapshot) = inner.withLock { s -> ([MeetingSilenceInterval]?, Snapshot?) in
      s.follower.commit(through: released)
      // Expiry first, at the queue's time: a reading that aged out stops counting before the
      // input or the release that follows.
      s.follower.advance(to: now)
      var trace: Trace?
      switch input {
      case .reading(let reading, let t, let e, let m, let generation):
        let outcome = s.follower.record(
          reading, copyStart: t, delivered: now, generation: generation)
        trace = Trace(
          copyStart: t, copyEnd: e, received: m, delivered: now, released: released,
          outcome: outcome)
      case .bind(let surface, let generation):
        s.follower.bind(surface: surface, generation: generation)
        s.generation = generation
      case .unbind:
        s.follower.unbind()
        s.generation = nil
      case .setEnabled(let on, let at):
        s.follower.setEnabled(on, at: at)
      case .advance, nil:
        break
      case .end:
        s.follower.end()
        s.generation = nil
      }
      let current = s.follower.intervals.map {
        MeetingSilenceInterval(start: $0.start, end: $0.end)
      }
      let changed = current != s.applied
      if changed { s.applied = current }
      let state = s.follower.state
      let missed = s.follower.missed
      guard trace != nil || state != s.lastState || missed != s.lastMissed else {
        return (changed ? current : nil, nil)
      }
      s.lastState = state
      s.lastMissed = missed
      s.seq += 1
      return (
        changed ? current : nil,
        Snapshot(
          recording: recording, seq: s.seq, generation: s.generation, state: state,
          missed: missed, trace: trace)
      )
    }
    if let snapshot { publish(snapshot) }
    return intervals
  }
}
