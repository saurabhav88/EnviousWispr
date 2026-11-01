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

  @Test("an outer edge under the gap joins its group; exactly the gap or more stays out (c4.1)")
  func edges() {
    let g = Self.gap
    let count = 3 * g
    func one(start: Int, endGap: Int) -> [Range<Int>] {
      MeetingWhisperPreparation.groups(spans: [start..<(count - endGap)], count: count)
    }
    #expect(one(start: g - 1, endGap: g + 5) == [0..<(count - g - 5)], "start G-1 extends; end G+5 stays")
    #expect(one(start: g, endGap: g + 5) == [g..<(count - g - 5)], "start exactly G does not extend")
    #expect(one(start: g + 1, endGap: g + 5) == [(g + 1)..<(count - g - 5)], "start G+1 does not extend")
    #expect(one(start: g + 5, endGap: g - 1) == [(g + 5)..<count], "end G-1 extends")
    #expect(one(start: g + 5, endGap: g) == [(g + 5)..<(count - g)], "end exactly G does not extend")
    #expect(one(start: g + 5, endGap: g + 1) == [(g + 5)..<(count - g - 1)], "end G+1 does not extend")
    #expect(one(start: g - 1, endGap: g - 1) == [0..<count], "both under: the whole run, as today")
    #expect(one(start: g, endGap: g) == [g..<(count - g)], "both exactly G: neither extends")
  }

  @Test("edge extension keeps every interior split and touches only the outer groups")
  func edgesKeepInteriorSplits() {
    let g = Self.gap
    let spans = [1_000..<10_000, (10_000 + g)..<(20_000 + g), (20_000 + 2 * g)..<(30_000 + 2 * g)]
    let count = 30_000 + 2 * g + 500
    #expect(
      MeetingWhisperPreparation.groups(spans: spans, count: count)
        == [0..<10_000, (10_000 + g)..<(20_000 + g), (20_000 + 2 * g)..<count])
    #expect(MeetingWhisperPreparation.groups(spans: [], count: count) == [], "no groups, no extension")
    #expect(
      MeetingWhisperPreparation.groups(spans: [(-40)..<0, (count + 1)..<(count + 9)], count: count) == [],
      "clamped-empty spans stay confirmed silence")
  }

  @Test("groups follow the spans in order, merge overlaps, and clamp to the run")
  func orderAndClamp() {
    let groups = MeetingWhisperPreparation.groups(
      spans: [300_000..<320_000, -50..<10_000, 5_000..<20_000, 150_000..<160_000],
      count: 310_000)
    #expect(groups == [0..<20_000, 150_000..<160_000, 300_000..<310_000])
  }
}
