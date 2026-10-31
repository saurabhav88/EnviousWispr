import Foundation
import Testing

@testable import EnviousWisprASR

/// #4254 plan §17: when these fail, meeting Whisper decodes speech the detector brought closer
/// together than it was spoken (and drops a repetition), decodes a long silence, or loses
/// speech at the edge of the run.
///
/// All inputs are literal sample indices at 16 kHz; the grouping gap is 8 s (128,000 samples).
@Suite("Meeting Whisper speech groups", .tags(.productOutcome))
struct MeetingWhisperPreparationTests {
  static let gap = MeetingWhisperPreparation.groupGapSamples

  @Test("no speech, or speech only outside the run, gives no group (confirmed silence)")
  func silence() {
    #expect(MeetingWhisperPreparation.groups(spans: [], count: 1_000) == [])
    #expect(MeetingWhisperPreparation.groups(spans: [5..<5, 2_000..<3_000], count: 1_000) == [])
  }

  @Test("a silence just under the gap joins one contiguous group; exactly the gap starts a new one")
  func boundary() {
    #expect(Self.gap == 128_000)
    let under = MeetingWhisperPreparation.groups(
      spans: [0..<16_000, (16_000 + Self.gap - 1)..<(32_000 + Self.gap)], count: 400_000)
    #expect(under == [0..<(32_000 + Self.gap)], "7.99 s: one group, the silence kept as recorded")
    let at = MeetingWhisperPreparation.groups(
      spans: [0..<16_000, (16_000 + Self.gap)..<(32_000 + Self.gap)], count: 400_000)
    #expect(at == [0..<16_000, (16_000 + Self.gap)..<(32_000 + Self.gap)], "8 s: two groups")
  }

  @Test("groups follow the spans in order, merge overlaps, and clamp to the run")
  func orderAndClamp() {
    let groups = MeetingWhisperPreparation.groups(
      spans: [300_000..<320_000, -50..<10_000, 5_000..<20_000, 150_000..<160_000],
      count: 310_000)
    #expect(groups == [0..<20_000, 150_000..<160_000, 300_000..<310_000])
  }
}
