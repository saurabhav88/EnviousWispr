import CoreAudio
import Darwin
import EnviousWisprAppKitTestSupport
import EnviousWisprAudio
import EnviousWisprCore
import Foundation
import Testing
import os

@testable import EnviousWisprAppKit
@testable import EnviousWisprServices

/// #4248 plan §18: when these fail, a mute reading that was already too old when it reached the
/// microphone hold still silences the user, an expired reading keeps silencing them, a reading
/// from an earlier call counts, or the live card shows an older state over a newer one.
///
/// The steps are called directly with the writer's (queue time, C) arguments. Times are
/// SYNTHETIC host ticks with a 1:1 timebase, so the numbers below are literal seconds.
@Suite("Meeting mute gate", .tags(.productOutcome))
struct MeetingMuteGateTests {
  static let nanos = mach_timebase_info_data_t(numer: 1, denom: 1)

  private func s(_ seconds: Double) -> UInt64 { UInt64((seconds * 1_000_000_000).rounded()) }


  final class Published: Sendable {
    let all = OSAllocatedUnfairLock<[MeetingMuteGate.Snapshot]>(initialState: [])
    var last: MeetingMuteGate.Snapshot? { all.withLock { $0.last } }
    var count: Int { all.withLock { $0.count } }
  }

  private func gate(_ published: Published, surface: CallSpeakerSurface = .teamsApp)
    -> MeetingMuteGate
  {
    let gate = MeetingMuteGate(
      recording: UUID(), follower: MeetingMuteFollower(enabled: true, timebase: Self.nanos),
      publish: { snapshot in published.all.withLock { $0.append(snapshot) } })
    _ = gate.step(.bind(surface, generation: 1))(s(0), 0)
    return gate
  }

  /// Runs a reading copied at `t`, received at `t + 0.1`, delivered to the queue at `d`.
  @discardableResult
  private func read(
    _ gate: MeetingMuteGate, _ reading: CallSelfMute, t: Double, d: Double,
    released: Double = 0, generation: UInt64 = 1
  ) -> [MeetingSilenceInterval]? {
    gate.step(
      .reading(
        reading, copyStart: s(t), copyEnd: s(t + 0.05), received: s(t + 0.1),
        generation: generation))(s(d), s(released))
  }

  @Test("a reading already stale when it reaches the queue installs no silence")
  func staleAtQueue() throws {
    let published = Published()
    let g = gate(published)
    // T = 10, M = 10.1, D = 12: older than 1.5 s at delivery although fresh when received.
    #expect(read(g, .muted, t: 10, d: 12) == nil)
    let trace = try #require(published.last?.trace)
    #expect(trace.outcome == .staleAtDelivery)
    #expect(trace.received == s(10.1))
    #expect(trace.delivered == s(12), "D is the queue's time, never M")
    #expect(published.last?.state == .checking)
  }

  @Test("muted then unmuted gives the stretch from the muted T to the unmuted T minus W")
  func muteThenUnmute() {
    let published = Published()
    let g = gate(published)
    #expect(read(g, .muted, t: 10, d: 10.2) == [MeetingSilenceInterval(start: s(10), end: .max)])
    #expect(published.last?.state == .muted)
    // Readings keep coming every 0.5 s while muted, so the stretch never expires.
    for t in stride(from: 10.5, through: 13.5, by: 0.5) { read(g, .muted, t: t, d: t + 0.2) }
    // Teams: W = 1.0 s.
    #expect(read(g, .unmuted, t: 14, d: 14.2) == [MeetingSilenceInterval(start: s(10), end: s(13))])
    #expect(published.last?.state == .unmuted)
  }

  @Test("the release clock closes an expired mute at the queue's time, with no new reading")
  func clockExpiry() {
    let published = Published()
    let g = gate(published)
    read(g, .muted, t: 10, d: 10.1)
    read(g, .muted, t: 10.5, d: 10.6)
    #expect(g.clock(s(11.9), 0) == nil, "1.4 s after the last reading: still counts")
    let before = published.count
    #expect(g.clock(s(12.1), 0) == [MeetingSilenceInterval(start: s(10), end: s(10.5))], "closed at last muted T")
    #expect(published.count == before + 1)
    #expect(published.last?.state == .cannotSee)
    #expect(published.last?.trace == nil)
  }

  @Test("expiry is judged before a reading in the same step")
  func expiryBeforeReading() {
    let published = Published()
    let g = gate(published)
    read(g, .muted, t: 10, d: 10.1)
    // No clock ran in between; the next reading arrives 3 s later and is muted again.
    #expect(read(g, .muted, t: 13, d: 13.1) == [MeetingSilenceInterval(start: s(13), end: .max)])
  }

  @Test("a reading from an earlier call is ignored")
  func generationFence() throws {
    let published = Published()
    let g = gate(published)
    _ = g.step(.bind(.zoomApp, generation: 2))(s(5), 0)
    #expect(read(g, .muted, t: 10, d: 10.1, generation: 1) == nil)
    #expect(try #require(published.last?.trace).outcome == .ignored)
    #expect(published.last?.generation == 2)
  }

  @Test("audio already released when a mute is learned is counted as missed")
  func missedFromReleased() {
    let published = Published()
    let g = gate(published)
    read(g, .muted, t: 10, d: 10.6, released: 10.5)
    #expect(published.last?.missed.keptTicks == s(0.5))
    #expect(published.last?.missed.events == 1)
  }

  @Test("a step that changes nothing returns nil and publishes nothing")
  func quietStep() {
    let published = Published()
    let g = gate(published)
    let before = published.count
    #expect(g.clock(s(1), 0) == nil)
    #expect(g.step(.advance)(s(2), 0) == nil)
    #expect(published.count == before)
  }

  @Test("end and switching off close an open stretch at the last muted reading")
  func endAndOff() {
    let published = Published()
    let a = gate(published)
    read(a, .muted, t: 10, d: 10.1)
    read(a, .muted, t: 10.5, d: 10.6)
    #expect(a.step(.end)(s(10.8), 0) == [MeetingSilenceInterval(start: s(10), end: s(10.5))])
    let b = gate(published)
    read(b, .muted, t: 10, d: 10.1)
    read(b, .muted, t: 10.5, d: 10.6)
    #expect(
      b.step(.setEnabled(false, at: s(10.7)))(s(10.8), 0) == [MeetingSilenceInterval(start: s(10), end: s(10.5))])
    #expect(published.last?.state == .disabled)
  }

  @Test("the fence keeps only this recording's newer snapshots")
  func fence() {
    let id = UUID()
    var fence = MeetingMuteGate.SnapshotFence(recording: id)
    func snap(_ recording: UUID, _ seq: UInt64) -> MeetingMuteGate.Snapshot {
      .init(
        recording: recording, seq: seq, generation: 1, state: .muted, missed: .init(), trace: nil)
    }
    let first = fence.accept(snap(id, 2))
    let late = fence.accept(snap(id, 1))
    let repeated = fence.accept(snap(id, 2))
    let other = fence.accept(snap(UUID(), 3))
    let next = fence.accept(snap(id, 3))
    #expect(first)
    #expect(!late, "older, arrived late")
    #expect(!repeated, "repeat")
    #expect(!other, "another recording")
    #expect(next)
  }

  @Test("on a real writer, a stale reading never silences audio and the clock expires a mute")
  func onRealWriter() async throws {
    let dir = TestTemporaryDirectory.url.appendingPathComponent(
      "MeetingMuteGateTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let anchor = mach_absolute_time()
    let time = OSAllocatedUnfairLock(initialState: anchor)
    let pending = OSAllocatedUnfairLock<[(UInt64, @Sendable () -> Void)]>(initialState: [])
    let writer = MeetingTrackWriter(
      configuration: .init(
        meetingID: UUID(), track: .microphone, folder: dir, anchorHostTime: anchor,
        segmentSeconds: 60, bufferCapacity: 16_000 * 20, silenceHoldSeconds: 3),
      onSegmentFinalized: { _ in }, onFailure: { _ in }, onReleased: nil,
      now: { time.withLock { $0 } },
      scheduler: .manual { due, run in pending.withLock { $0.append((due, run)) } })
    let published = Published()
    // The writer's real clock, so ticks are host ticks here.
    let g = MeetingMuteGate(
      recording: UUID(), follower: MeetingMuteFollower(enabled: true),
      publish: { snapshot in published.all.withLock { $0.append(snapshot) } })
    let at: @Sendable (Double) -> UInt64 = { seconds in
      anchor &+ AudioConvertNanosToHostTime(UInt64(seconds * 1_000_000_000))
    }
    writer.setSilenceClock(g.clock)
    writer.applySilenceStep(g.step(.bind(.teamsApp, generation: 1)))
    writer.append([Float](repeating: 0.25, count: 32_000), hostTime: anchor)
    // A muted reading copied at 0 s reaches the queue at 2 s: stale, never applied.
    writer.suspendQueueForTesting()
    writer.applySilenceStep(
      g.step(.reading(.muted, copyStart: anchor, copyEnd: anchor, received: anchor, generation: 1)))
    time.withLock { $0 = at(2) }
    writer.resumeQueueForTesting()
    await writer.queueBarrierForTesting()
    // A fresh muted reading at 2 s, then nothing: by 5.5 s it has expired.
    writer.applySilenceStep(
      g.step(.reading(.muted, copyStart: at(2), copyEnd: at(2), received: at(2), generation: 1)))
    writer.applySilenceStep(
      g.step(
        .reading(.muted, copyStart: at(2.5), copyEnd: at(2.5), received: at(2.5), generation: 1)))
    await writer.queueBarrierForTesting()
    writer.append([Float](repeating: 0.25, count: 32_000), hostTime: at(2))
    time.withLock { $0 = at(7.5) }
    await writer.queueBarrierForTesting()
    let due = pending.withLock { list in
      defer { list.removeAll() }
      return list.map(\.1)
    }
    due.forEach { $0() }
    await writer.queueBarrierForTesting()
    #expect(await writer.finish() == .finalized)
    // Only [2, 2.5) is silenced: 8,000 frames. The stale reading silenced nothing.
    #expect(writer.currentHealth.silencedFrames == 8_000)
    #expect(published.all.withLock { $0 }.contains { $0.trace?.outcome == .staleAtDelivery })
    #expect(published.last?.state == .cannotSee)
  }
}
