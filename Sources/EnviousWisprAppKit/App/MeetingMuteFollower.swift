import Darwin
import EnviousWisprAudio
import EnviousWisprCore
import EnviousWisprServices
import Foundation

/// Decides, from the call app's mute button readings, which stretches of the microphone are left
/// out of a meeting recording (#4248 plan §3.0, the sole timing owner). One per recording.
///
/// Pure: every input carries its own acquisition time and nothing here reads the app, the clock
/// or audio. Inputs of another recording are ignored. The arithmetic below is on host ticks of
/// this one recording, decoded at each input; provenance never changes a decision. Four times
/// are kept apart and never stand in for each other:
/// - T, a reading's copy-start host time: a conservative stamp, earlier than the moment the
///   button was read. Never the copy's middle or end.
/// - D, when that reading reached the gate queue. `D - T` (L) is part of the hold budget.
/// - W, the per-app uncertainty between the real mute change and T.
/// - C, the end of audio the gate has released for good. Only audio after C can still change.
///
/// Rules: a muted stretch starts at the first muted T and ends at the next unmuted T minus W, so
/// words just before an unmute are kept. Unknown, a stale reading, switching off, a new target,
/// an uncertain source and the end close an open stretch at the last muted T. Before the first
/// reading the microphone stays live. A reading that would change audio before C is not applied
/// to it: that range is counted as missed, and is never reported as recovered.
struct MeetingMuteFollower: Sendable {
  /// What the live card shows.
  enum State: Sendable, Equatable {
    /// The switch is off.
    case disabled
    /// No supported call is bound to the recording.
    case unbound
    /// Bound, and no mute reading yet: the microphone is recorded as usual.
    case checking
    case muted
    case unmuted
    /// Following had begun, and the mute button can no longer be read, or its reading is stale.
    case cannotSee
  }

  /// What became of one reading.
  enum Outcome: Sendable, Equatable {
    case applied
    /// Applied as unknown: already older than the staleness limit when it was delivered.
    case staleAtDelivery
    /// From an earlier target, or not newer than the last reading.
    case ignored
    /// Off, or no call bound.
    case inactive
  }

  /// The per-app timing: W, the hold H, and how old a reading may be before it no longer counts.
  struct Timing: Sendable, Equatable {
    var window: Double
    var hold: Double
    var staleness: Double

    /// Zoom's button changes 1.1 to 1.6 s after a press (live probes 2026-10-30): W = 1.6 s lag
    /// + one 500 ms read interval + the 400 ms copy budget. Teams and Meet change in about 60 ms.
    /// H and the windows are provisional until the chunk 2 measurements size them.
    static func `for`(_ surface: CallSpeakerSurface) -> Timing {
      Timing(window: surface == .zoomApp ? 2.5 : 1.0, hold: 3.0, staleness: 1.5)
    }

    /// The least hold that keeps every correction inside it: W + L + margin (plan §3a).
    static func requiredHold(window: Double, delivery: Double, margin: Double) -> Double {
      window + delivery + margin
    }
  }

  /// Audio the gate had already released when a reading that would change it arrived.
  struct Missed: Sendable, Equatable {
    /// Released as live although a later reading says it was muted.
    var keptTicks: UInt64 = 0
    /// Released as silence although a later reading says it was not muted.
    var silencedTicks: UInt64 = 0
    var events = 0
  }

  /// One muted stretch in this recording's host ticks, half open: `[start, end)`.
  private struct Stretch: Equatable {
    let start: UInt64
    let end: UInt64
  }

  let recording: UUID
  private(set) var state: State = .unbound
  /// The muted stretches not yet wholly released, oldest first; the last may be open (nil end).
  /// Starts are reading times (observed); a closed end is derived from readings (estimated).
  var intervals: [MeetingSilenceInterval] {
    closed.map {
      MeetingSilenceInterval(start: time($0.start, .observed), end: time($0.end, .estimated))
    } + (openStart.map { [MeetingSilenceInterval(start: time($0, .observed), end: nil)] } ?? [])
  }
  /// C: the end of audio released for good; nil before any.
  private(set) var committed: MeetingAcquisitionTime?
  private var committedTicks: UInt64 { committed?.hostTicks ?? 0 }
  private(set) var missed = Missed()

  private let timebase: mach_timebase_info_data_t
  private var timing: Timing?
  private var enabled: Bool
  private var generation: UInt64?
  private var lastReadingT: UInt64?
  private var lastMutedT: UInt64?
  private var openStart: UInt64?
  /// Where the open stretch's silence began going out: its start, or C when it started earlier.
  private var openReleasedFrom: UInt64?
  /// Whether a mute state was read since binding or switching on (checking versus cannot-see).
  private var following = false
  private var closed: [Stretch] = []
  /// Readings copied before this host time are not used: the switch was off when they began.
  private var acceptFrom: UInt64 = 0
  private let timingFor: @Sendable (CallSpeakerSurface) -> Timing

  init(
    recording: UUID, enabled: Bool,
    timebase: mach_timebase_info_data_t = CallSpeakerTimeline.liveTimebase,
    timing: @escaping @Sendable (CallSpeakerSurface) -> Timing = { Timing.for($0) }
  ) {
    self.recording = recording
    self.enabled = enabled
    self.timebase = timebase
    timingFor = timing
    state = enabled ? .unbound : .disabled
  }

  private func time(_ ticks: UInt64, _ provenance: MeetingAcquisitionTime.Provenance)
    -> MeetingAcquisitionTime
  {
    MeetingAcquisitionTime(recording: recording, hostTicks: ticks, provenance: provenance)
  }

  /// This recording's ticks of `time`; nil for another recording's time.
  private func ticks(of time: MeetingAcquisitionTime) -> UInt64? {
    time.recording == recording ? time.hostTicks : nil
  }

  /// Host ticks in `seconds`.
  func ticks(_ seconds: Double) -> UInt64 {
    let nanos = max(0, seconds) * 1_000_000_000
    return UInt64(nanos * Double(timebase.denom) / Double(timebase.numer))
  }

  // MARK: - Inputs

  /// A supported call is bound, or a new one replaces it. Readings from any other generation are
  /// ignored from now on; an open stretch closes at its last muted reading.
  mutating func bind(surface: CallSpeakerSurface, generation: UInt64) {
    closeAtLastMuted()
    timing = timingFor(surface)
    self.generation = generation
    lastReadingT = nil
    following = false
    if enabled { state = .checking }
  }

  /// The call is gone, or which call it is became uncertain.
  mutating func unbind() {
    closeAtLastMuted()
    timing = nil
    generation = nil
    lastReadingT = nil
    if enabled { state = .unbound }
  }

  /// The Settings switch, changed at `time`. Turning it off closes an open stretch; audio
  /// already released is never restored. Turning it on starts checking again, and a copy that
  /// began before `time` (while the switch was off) is never used.
  mutating func setEnabled(_ on: Bool, at time: MeetingAcquisitionTime) {
    guard on != enabled, let hostTime = ticks(of: time) else { return }
    enabled = on
    if !on {
      closeAtLastMuted()
      state = .disabled
    } else {
      lastReadingT = nil
      acceptFrom = max(acceptFrom, hostTime)
      following = false
      state = timing == nil ? .unbound : .checking
    }
  }

  /// One reading, copied at `copyStart` (T) and delivered at `delivered` (D).
  @discardableResult
  mutating func record(
    _ reading: CallSelfMute, copyStart: MeetingAcquisitionTime,
    delivered: MeetingAcquisitionTime, generation: UInt64
  ) -> Outcome {
    guard enabled, let timing, let current = self.generation else { return .inactive }
    guard let t = ticks(of: copyStart), let d = ticks(of: delivered) else { return .ignored }
    guard generation == current, t >= acceptFrom, lastReadingT.map({ t > $0 }) ?? true else {
      return .ignored
    }
    lastReadingT = t
    // A reading already too old when it arrives counts as unknown.
    let fresh = d < t || d - t <= ticks(timing.staleness)
    switch fresh ? reading : .unknown {
    case .muted:
      if openStart == nil {
        openStart = t
        openReleasedFrom = max(t, committedTicks)
        // Audio from T up to C went out live already.
        if t < committedTicks { noteMissed(kept: committedTicks - t) }
      }
      lastMutedT = t
      following = true
      state = .muted
    case .unmuted:
      if let start = openStart {
        let window = ticks(timing.window)
        let end = t > window ? t - window : 0
        finish(start: start, end: end)
      }
      following = true
      state = .unmuted
    case .unknown:
      closeAtLastMuted()
      state = following ? .cannotSee : .checking
    }
    return fresh ? .applied : .staleAtDelivery
  }

  /// Time moved on to `now` with no new reading: a reading older than the staleness limit no
  /// longer counts.
  mutating func advance(to time: MeetingAcquisitionTime) {
    guard enabled, let now = ticks(of: time), let timing, let last = lastReadingT, now > last,
      now - last > ticks(timing.staleness)
    else { return }
    guard state == .muted || state == .unmuted else { return }
    closeAtLastMuted()
    state = .cannotSee
  }

  /// The gate released audio up to `time` for good (nil: nothing released yet). C never moves
  /// back. Stretches wholly before C are retired.
  mutating func commit(through time: MeetingAcquisitionTime?) {
    guard let time, let hostTime = ticks(of: time), hostTime > committedTicks else { return }
    committed = time
    closed.removeAll { $0.end <= hostTime }
  }

  /// The recording ended: an open stretch closes at its last muted reading.
  mutating func end() {
    closeAtLastMuted()
    generation = nil
    timing = nil
  }

  // MARK: - Stretches

  private mutating func closeAtLastMuted() {
    guard let start = openStart else { return }
    finish(start: start, end: lastMutedT ?? start)
  }

  /// Ends the open stretch at `end`. An empty or reversed stretch silences nothing.
  private mutating func finish(start: UInt64, end: UInt64) {
    let releasedFrom = openReleasedFrom ?? start
    openStart = nil
    openReleasedFrom = nil
    lastMutedT = nil
    // While open, released audio after `end` up to C went out as silence.
    let wrongFrom = max(releasedFrom, end)
    if committedTicks > wrongFrom { noteMissed(silenced: committedTicks - wrongFrom) }
    guard end > start else { return }
    insert(Stretch(start: start, end: end))
  }

  /// Readings only move forward and a stretch ends at or before its last muted reading, so a
  /// new stretch always starts after the previous one ends: stretches stay apart, in order, and
  /// an unknown or unmuted gap between them is never bridged.
  private mutating func insert(_ interval: Stretch) {
    guard interval.end > committedTicks else { return }
    closed.append(interval)
  }

  private mutating func noteMissed(kept: UInt64 = 0, silenced: UInt64 = 0) {
    missed.keptTicks += kept
    missed.silencedTicks += silenced
    missed.events += 1
  }
}
