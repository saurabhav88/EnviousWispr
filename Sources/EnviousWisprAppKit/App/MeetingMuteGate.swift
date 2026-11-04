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
  /// One reading as the gate decides it: the copy's T, decoded once at the coordinator's mute
  /// ingress (`Reading.init(_:recording:)`), and the raw copy for the DEBUG trace only. D comes
  /// from the writer.
  struct Reading: Sendable, Equatable {
    let copyStart: MeetingAcquisitionTime
    let copy: CallMuteCopy

    /// The copy's read start is the host clock read when the copy began: observed.
    init(_ copy: CallMuteCopy, recording: UUID) {
      self.copy = copy
      copyStart = MeetingAcquisitionTime(
        recording: recording, hostTicks: copy.copyStart, provenance: .observed)
    }
  }

  enum Input: Sendable, Equatable {
    case reading(Reading)
    case bind(CallSpeakerSurface, generation: UInt64)
    case unbind
    case setEnabled(Bool, at: MeetingAcquisitionTime)
    /// Time passed with no reading (the session tick); expiry is judged at the queue's time.
    case advance
    case end
  }

  /// One reading's decision, for the DEBUG timing trace.
  struct Trace: Sendable, Equatable {
    let copy: CallMuteCopy
    let delivered: MeetingAcquisitionTime
    let released: MeetingAcquisitionTime?
    let outcome: MeetingMuteFollower.Outcome
  }

  /// Every reading the gate decided, by outcome, for the timing receipt.
  struct Totals: Sendable, Equatable {
    var applied = 0
    var staleAtDelivery = 0
    var ignored = 0
    var inactive = 0
    var readings: Int { applied + staleAtDelivery + ignored + inactive }
    /// Queue host ticks a supported call was bound while the switch was on (telemetry
    /// denominator), and the part of them spent checking or unable to read the button.
    var eligibleTicks: UInt64 = 0
    var unknownTicks: UInt64 = 0

    mutating func count(_ outcome: MeetingMuteFollower.Outcome) {
      switch outcome {
      case .applied: applied += 1
      case .staleAtDelivery: staleAtDelivery += 1
      case .ignored: ignored += 1
      case .inactive: inactive += 1
      }
    }
  }

  struct Snapshot: Sendable, Equatable {
    let recording: UUID
    let seq: UInt64
    let generation: UInt64?
    let state: MeetingMuteFollower.State
    let missed: MeetingMuteFollower.Missed
    let trace: Trace?
    let totals: Totals
    /// The `.end` step ran: this is the recording's last decision.
    let ended: Bool
  }

  /// Keeps the newest snapshot of one recording for the live card; snapshots hop to the
  /// MainActor in no guaranteed order. (The timing trace logs every snapshot, accepted or not.)
  struct SnapshotFence: Sendable {
    let recording: UUID
    private(set) var lastSeq: UInt64 = 0
    /// The newest call generation accepted; a snapshot from an earlier call is refused.
    private(set) var lastGeneration: UInt64 = 0

    init(recording: UUID) { self.recording = recording }

    /// Whether `snapshot` is this recording's, from the current call or a later one, and newer
    /// than every one accepted so far.
    mutating func accept(_ snapshot: Snapshot) -> Bool {
      guard snapshot.recording == recording, snapshot.seq > lastSeq,
        snapshot.generation.map({ $0 >= lastGeneration }) ?? true
      else { return false }
      lastSeq = snapshot.seq
      if let generation = snapshot.generation { lastGeneration = generation }
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
    var totals = Totals()
    /// The queue ticks of the last step, so time is counted in the state it was spent in.
    var lastNow: UInt64?
    /// The `.end` step ran: the clock steps of the closing writer count no more time.
    var countingEnded = false
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

  /// The counts so far; read after the writer closed, they include the `.end` step.
  var totals: Totals { inner.withLock { $0.totals } }

  /// The step that applies `input` on the writer's queue.
  func step(_ input: Input) -> MeetingSilenceStep {
    { [self] now, released in run(input, now: now, released: released) }
  }

  /// The step run before every release: expiry only.
  var clock: MeetingSilenceStep {
    { [self] now, released in run(nil, now: now, released: released) }
  }

  private func run(
    _ input: Input?, now time: MeetingAcquisitionTime, released: MeetingAcquisitionTime?
  ) -> [MeetingSilenceInterval]? {
    // Durations below are tick differences of this recording's queue clock.
    let now = time.hostTicks
    let (intervals, snapshot) = inner.withLock { s -> ([MeetingSilenceInterval]?, Snapshot?) in
      // The time since the last step was spent in the state the follower showed then.
      if !s.countingEnded, let last = s.lastNow, now > last {
        switch s.follower.state {
        case .checking, .cannotSee:
          s.totals.eligibleTicks += now - last
          s.totals.unknownTicks += now - last
        case .muted, .unmuted:
          s.totals.eligibleTicks += now - last
        case .unbound, .disabled:
          break
        }
      }
      s.lastNow = max(s.lastNow ?? now, now)
      if input == .end { s.countingEnded = true }
      s.follower.commit(through: released)
      // Expiry first, at the queue's time: a reading that aged out stops counting before the
      // input or the release that follows.
      s.follower.advance(to: time)
      var trace: Trace?
      switch input {
      case .reading(let reading):
        let outcome = s.follower.record(
          reading.copy.reading, copyStart: reading.copyStart, delivered: time,
          generation: reading.copy.generation)
        trace = Trace(copy: reading.copy, delivered: time, released: released, outcome: outcome)
        s.totals.count(outcome)
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
      let current = s.follower.intervals
      let changed = current != s.applied
      if changed { s.applied = current }
      let state = s.follower.state
      let missed = s.follower.missed
      let ended = input == .end
      guard trace != nil || ended || state != s.lastState || missed != s.lastMissed else {
        return (changed ? current : nil, nil)
      }
      s.lastState = state
      s.lastMissed = missed
      s.seq += 1
      return (
        changed ? current : nil,
        Snapshot(
          recording: recording, seq: s.seq, generation: s.generation, state: state,
          missed: missed, trace: trace, totals: s.totals, ended: ended)
      )
    }
    if let snapshot { publish(snapshot) }
    return intervals
  }
}
