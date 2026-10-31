import CoreAudio
import Darwin
import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprAppKit
@testable import EnviousWisprServices

/// #4248: when these fail, EnviousMeet silences words the user said right before unmuting, keeps
/// room talk after a mute it already read, trusts a stale or wrong-call reading, or claims audio
/// it already let through was fixed afterwards.
///
/// Times are SYNTHETIC host ticks with a 1:1 timebase, so one tick is one nanosecond and the
/// expected stretches below are literal seconds.
@Suite("Meeting mute follower", .tags(.productOutcome))
struct MeetingMuteFollowerTests {
  static let nanos = mach_timebase_info_data_t(numer: 1, denom: 1)

  /// Seconds as ticks.
  private func s(_ seconds: Double) -> UInt64 { UInt64((seconds * 1_000_000_000).rounded()) }

  private func interval(_ start: Double, _ end: Double) -> MeetingMuteInterval {
    MeetingMuteInterval(start: s(start), end: s(end))
  }

  private func open(_ start: Double) -> MeetingMuteInterval {
    MeetingMuteInterval(start: s(start), end: MeetingMuteInterval.openEnd)
  }

  private func follower(_ surface: CallSpeakerSurface = .teamsApp, generation: UInt64 = 1)
    -> MeetingMuteFollower
  {
    var follower = MeetingMuteFollower(enabled: true, timebase: Self.nanos)
    follower.bind(surface: surface, generation: generation)
    return follower
  }

  /// A reading copied at `t` seconds and delivered `delay` seconds later.
  private func read(
    _ follower: inout MeetingMuteFollower, _ reading: CallSelfMute, at t: Double,
    delay: Double = 0.1, generation: UInt64 = 1
  ) -> MeetingMuteFollower.Outcome {
    follower.record(reading, copyStart: s(t), delivered: s(t + delay), generation: generation)
  }

  // MARK: - Startup

  @Test("before any reading the microphone stays live and the card says checking")
  func startup() {
    var f = MeetingMuteFollower(enabled: true, timebase: Self.nanos)
    #expect(f.state == .unbound)
    f.bind(surface: .meet, generation: 1)
    #expect(f.state == .checking)
    #expect(f.intervals == [])
    // An unknown first reading keeps checking; following has not begun.
    _ = read(&f, .unknown, at: 1)
    #expect(f.state == .checking)
    #expect(f.intervals == [])
    _ = read(&f, .unmuted, at: 1.5)
    #expect(f.state == .unmuted)
    #expect(f.intervals == [])
  }

  // MARK: - Transitions

  @Test("muting starts at the first muted reading; an unmute ends it W earlier (Teams 1 s)")
  func teamsTransition() {
    var f = follower(.teamsApp)
    _ = read(&f, .unmuted, at: 9.5)
    _ = read(&f, .muted, at: 10)
    _ = read(&f, .muted, at: 10.5)
    _ = read(&f, .muted, at: 11)
    #expect(f.state == .muted)
    #expect(f.intervals == [open(10)])
    _ = read(&f, .unmuted, at: 12)
    #expect(f.state == .unmuted)
    #expect(f.intervals == [interval(10, 11)])
  }

  @Test("Zoom's 2.5 s window: a mute shorter than W silences nothing")
  func zoomWindow() {
    var f = follower(.zoomApp)
    _ = read(&f, .muted, at: 10)
    _ = read(&f, .unmuted, at: 12)
    #expect(f.intervals == [], "12 - 2.5 is before 10: the stretch is empty")
    _ = read(&f, .muted, at: 20)
    _ = read(&f, .unmuted, at: 24)
    #expect(f.intervals == [interval(20, 21.5)])
  }

  @Test("an unmute between two readings: the stretch still ends W before the unmuted reading")
  func unmuteBetweenPolls() {
    var f = follower(.meet)
    _ = read(&f, .muted, at: 10)
    _ = read(&f, .muted, at: 10.5)
    _ = read(&f, .muted, at: 11)
    // The user unmuted at about 11.2; the next copy started at 11.5.
    _ = read(&f, .unmuted, at: 11.5)
    #expect(f.intervals == [interval(10, 10.5)])
  }

  @Test("repeated muted readings keep one open stretch")
  func repeatedReadings() {
    var f = follower()
    for t in stride(from: 10.0, through: 20.0, by: 0.5) { _ = read(&f, .muted, at: t) }
    #expect(f.intervals == [open(10)])
  }

  // MARK: - Uncertainty closes at the last muted reading

  @Test("unknown closes an open stretch at the last muted reading and the card says cannot see")
  func unknownCloses() {
    var f = follower()
    _ = read(&f, .muted, at: 10)
    _ = read(&f, .muted, at: 10.5)
    _ = read(&f, .unknown, at: 11)
    #expect(f.state == .cannotSee)
    #expect(f.intervals == [interval(10, 10.5)])
    // Muted again later: a separate stretch; the unknown gap is never bridged.
    _ = read(&f, .muted, at: 12)
    _ = read(&f, .muted, at: 12.5)
    _ = read(&f, .unknown, at: 13)
    #expect(f.intervals == [interval(10, 10.5), interval(12, 12.5)])
  }

  @Test("a reading older than 1.5 s expires: the stretch closes at the last muted reading")
  func staleness() {
    var f = follower()
    _ = read(&f, .muted, at: 10)
    _ = read(&f, .muted, at: 10.5)
    f.advance(to: s(11.9))
    #expect(f.state == .muted)
    #expect(f.intervals == [open(10)])
    f.advance(to: s(12.1))
    #expect(f.state == .cannotSee)
    #expect(f.intervals == [interval(10, 10.5)])
    // An unmuted state ages to cannot-see too.
    var g = follower()
    _ = read(&g, .unmuted, at: 10)
    g.advance(to: s(11.6))
    #expect(g.state == .cannotSee)
  }

  @Test("a reading delivered more than 1.5 s after its copy began counts as unknown")
  func delayedDelivery() {
    var f = follower()
    #expect(read(&f, .muted, at: 10, delay: 1.6) == .staleAtDelivery)
    #expect(f.intervals == [])
    #expect(f.state == .checking)
    _ = read(&f, .muted, at: 10.5, delay: 1.4)
    #expect(f.intervals == [open(10.5)])
    _ = read(&f, .muted, at: 11, delay: 2)
    #expect(f.intervals == [], "closed at its only muted reading: empty")
    #expect(f.state == .cannotSee)
  }

  @Test("switching off closes the stretch; readings then do nothing; on again starts checking")
  func switchOffAndOn() {
    var f = follower()
    _ = read(&f, .muted, at: 10)
    _ = read(&f, .muted, at: 10.5)
    f.setEnabled(false, at: s(10.8))
    #expect(f.state == .disabled)
    #expect(f.intervals == [interval(10, 10.5)])
    #expect(read(&f, .muted, at: 11) == .inactive)
    #expect(f.intervals == [interval(10, 10.5)])
    f.setEnabled(true, at: s(11.5))
    #expect(f.state == .checking)
    _ = read(&f, .muted, at: 12)
    #expect(f.intervals == [interval(10, 10.5), open(12)])
  }

  @Test("a copy begun while the switch was off is ignored after it is turned back on")
  func switchCycleFence() {
    var f = follower()
    _ = read(&f, .unmuted, at: 10.5)
    // The copy starts at 11.0; the switch goes off at 11.1 and on at 11.2; the copy lands at 11.3.
    f.setEnabled(false, at: s(11.1))
    f.setEnabled(true, at: s(11.2))
    #expect(read(&f, .muted, at: 11.0, delay: 0.3) == .ignored)
    #expect(f.intervals == [])
    #expect(f.state == .checking)
    // The next copy, begun after switching on, is followed.
    #expect(read(&f, .muted, at: 11.5) == .applied)
    #expect(f.intervals == [open(11.5)])
    #expect(f.state == .muted)
  }

  @Test("a new target closes the stretch and fences the old target's readings")
  func rebinding() {
    var f = follower(generation: 1)
    _ = read(&f, .muted, at: 10)
    _ = read(&f, .muted, at: 10.5)
    f.bind(surface: .zoomApp, generation: 2)
    #expect(f.state == .checking)
    #expect(f.intervals == [interval(10, 10.5)])
    #expect(read(&f, .muted, at: 11, generation: 1) == .ignored)
    #expect(f.intervals == [interval(10, 10.5)])
    #expect(read(&f, .muted, at: 11.5, generation: 2) == .applied)
    #expect(f.intervals == [interval(10, 10.5), open(11.5)])
  }

  @Test("an uncertain source unbinds: the stretch closes and the card leaves the mute line")
  func sourceUncertainty() {
    var f = follower()
    _ = read(&f, .muted, at: 10)
    _ = read(&f, .muted, at: 10.5)
    f.unbind()
    #expect(f.state == .unbound)
    #expect(f.intervals == [interval(10, 10.5)])
    #expect(read(&f, .muted, at: 11) == .inactive)
  }

  @Test("Stop before an unmute is seen closes at the last muted reading")
  func stopBeforeUnmute() {
    var f = follower()
    _ = read(&f, .muted, at: 10)
    _ = read(&f, .muted, at: 10.5)
    _ = read(&f, .muted, at: 11)
    f.end()
    #expect(f.intervals == [interval(10, 11)])
    #expect(read(&f, .unmuted, at: 12) == .inactive)
  }

  @Test("a reading not newer than the last one is ignored")
  func outOfOrder() {
    var f = follower()
    _ = read(&f, .muted, at: 10)
    #expect(read(&f, .unmuted, at: 10) == .ignored)
    #expect(read(&f, .unmuted, at: 9) == .ignored)
    #expect(f.intervals == [open(10)])
  }

  // MARK: - The released watermark C

  @Test("C only moves forward and retires stretches wholly before it")
  func watermark() {
    var f = follower()
    _ = read(&f, .muted, at: 10)
    f.commit(through: s(12))
    #expect(f.committed == s(12))
    _ = read(&f, .unmuted, at: 14)
    #expect(f.intervals == [interval(10, 13)])
    f.commit(through: s(11))
    #expect(f.committed == s(12), "C never moves back")
    f.commit(through: s(13))
    #expect(f.intervals == [])
    #expect(f.missed == MeetingMuteFollower.Missed())
  }

  @Test("a mute read after its start was released counts the kept audio as missed")
  func lateMute() {
    var f = follower()
    f.commit(through: s(12))
    _ = read(&f, .muted, at: 11.9, delay: 0.1)
    #expect(f.intervals == [open(11.9)])
    #expect(f.missed.keptTicks == s(0.1))
    #expect(f.missed.silencedTicks == 0)
    #expect(f.missed.events == 1)
    _ = read(&f, .unmuted, at: 15)
    #expect(f.intervals == [interval(11.9, 14)])
    #expect(f.missed.events == 1)
  }

  /// W + L above H: the unmute's correction reaches audio the gate already released as silence.
  /// It is counted, never applied to that audio and never reported as recovered.
  @Test("W + L > H: an unmute whose correction reaches released audio counts it as missed")
  func windowPlusDeliveryAboveHold() {
    let zoom = MeetingMuteFollower.Timing.for(.zoomApp)
    #expect(zoom.window == 2.5)
    #expect(zoom.hold == 3.0)
    #expect(MeetingMuteFollower.Timing.requiredHold(window: 2.5, delivery: 0.2, margin: 0.3) == 3.0)
    var f = follower(.zoomApp)
    _ = read(&f, .muted, at: 10)
    // The unmuted reading copied at 20 arrives 1 s later; the gate released up to 21 - 3.
    f.commit(through: s(18))
    _ = read(&f, .unmuted, at: 20, delay: 1.0)
    #expect(f.intervals == [], "[10, 17.5) ends before C = 18: wholly released")
    #expect(f.missed.silencedTicks == s(0.5))
    #expect(f.missed.keptTicks == 0)
    #expect(f.missed.events == 1)
  }

  /// W itself above H (a 4 s window with the 3 s hold): even a reading delivered at once moves
  /// the unmute W back past audio the gate already released as silence.
  @Test("W > H: the unmute correction reaches released silence and is counted as missed")
  func windowItselfAboveHold() {
    var f = MeetingMuteFollower(
      enabled: true, timebase: Self.nanos,
      timing: { _ in MeetingMuteFollower.Timing(window: 4.0, hold: 3.0, staleness: 1.5) })
    f.bind(surface: .teamsApp, generation: 1)
    _ = read(&f, .muted, at: 10)
    _ = read(&f, .muted, at: 15)
    // The unmuted reading copied at 20 arrives at 20.1; the gate has released up to 20.1 - 3.
    f.commit(through: s(17.1))
    _ = read(&f, .unmuted, at: 20, delay: 0.1)
    #expect(f.intervals == [], "[10, 16) ends before C = 17.1: wholly released")
    #expect(f.missed.silencedTicks == s(1.1), "[16, 17.1) went out as silence")
    #expect(f.missed.keptTicks == 0)
    #expect(f.missed.events == 1)
    // Before C reaches the corrected end, the stretch is published with its literal bounds.
    var g = MeetingMuteFollower(
      enabled: true, timebase: Self.nanos,
      timing: { _ in MeetingMuteFollower.Timing(window: 4.0, hold: 3.0, staleness: 1.5) })
    g.bind(surface: .teamsApp, generation: 1)
    _ = read(&g, .muted, at: 10)
    g.commit(through: s(15))
    _ = read(&g, .unmuted, at: 20, delay: 0.1)
    #expect(g.intervals == [interval(10, 16)])
    #expect(g.missed == MeetingMuteFollower.Missed())
  }

  @Test("an update after release: closing at the last muted reading counts silence already out")
  func updateAfterRelease() {
    var f = follower()
    _ = read(&f, .muted, at: 10)
    _ = read(&f, .muted, at: 10.5)
    f.commit(through: s(11.4))
    _ = read(&f, .unknown, at: 11)
    #expect(f.intervals == [])
    #expect(f.missed.silencedTicks == s(0.9))
  }

  @Test("the published stretches are a copy")
  func intervalsAreCopies() {
    var f = follower()
    _ = read(&f, .muted, at: 10)
    var copy = f.intervals
    copy.removeAll()
    #expect(f.intervals == [open(10)])
  }

  @Test("live timebase converts seconds to host ticks the way the recorder does")
  func liveTicks() {
    let f = MeetingMuteFollower(enabled: true)
    let expected = AudioConvertNanosToHostTime(1_500_000_000)
    let got = f.ticks(1.5)
    #expect(got >= expected - 1 && got <= expected + 1)
  }
}
