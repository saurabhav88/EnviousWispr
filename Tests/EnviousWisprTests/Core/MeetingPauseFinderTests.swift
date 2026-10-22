import Foundation
import Testing

@testable import EnviousWisprCore

/// #3972 R16: when these fail, a meeting transcript loses or splits words where pieces join.
@Suite("MeetingPauseFinder", .tags(.productOutcome))
struct MeetingPauseFinderTests {

  /// Loud "speech" everywhere except silent gaps at the given seconds.
  private func track(
    seconds: Double, silences: [(Double, Double)], dipAmplitude: Float = 0, rate: Double = 16_000
  ) -> [Float] {
    let n = Int(seconds * rate)
    var s = [Float](repeating: 0, count: n)
    for i in 0..<n { s[i] = sin(Float(i) * 0.07) * 0.5 }
    for (a, b) in silences {
      for i in Int(a * rate)..<min(n, Int(b * rate)) { s[i] = sin(Float(i) * 0.07) * dipAmplitude }
    }
    return s
  }

  @Test("a 3-minute track with a pause near each minute is cut inside those pauses")
  func cutsLandInPauses() {
    let samples = track(seconds: 180, silences: [(58.0, 58.8), (121.0, 121.6)])
    let found = MeetingPauseFinder.cuts(in: samples)
    #expect(found.count == 2)
    let seconds = found.map { Double($0.sample) / 16_000 }
    #expect(seconds[0] >= 58.0 && seconds[0] <= 58.8)
    #expect(seconds[1] >= 121.0 && seconds[1] <= 121.6)
    #expect(found.allSatisfy { !$0.forced })
  }

  @Test(
    "continuous speech still gets a cut near the target, marked forced, and no audio is dropped")
  func continuousSpeechIsForcedNotDropped() {
    let samples = track(seconds: 150, silences: [])
    let found = MeetingPauseFinder.cuts(in: samples)
    #expect(!found.isEmpty)
    #expect(found.allSatisfy { $0.forced })
    let offsets = [0] + found.map(\.sample) + [samples.count]
    #expect(offsets == offsets.sorted())
    #expect(Set(offsets).count == offsets.count)
  }

  @Test("a track shorter than target plus search is one piece")
  func shortTrackIsOnePiece() {
    #expect(MeetingPauseFinder.cuts(in: track(seconds: 70, silences: [(30, 31)])).isEmpty)
  }

  @Test("forced is decided against a quarter of the window's median energy: 30% is forced, 15% is not")
  func forcedThreshold() {
    // Energy scales with amplitude squared: 0.5 * sqrt(0.30) and 0.5 * sqrt(0.15).
    let louder = track(seconds: 90, silences: [(59.5, 60.0)], dipAmplitude: 0.5 * Float(0.30).squareRoot())
    let quieter = track(seconds: 90, silences: [(59.5, 60.0)], dipAmplitude: 0.5 * Float(0.15).squareRoot())
    #expect(MeetingPauseFinder.cuts(in: louder).first?.forced == true)
    #expect(MeetingPauseFinder.cuts(in: quieter).first?.forced == false)
  }

  @Test("two equally quiet pauses: the one nearer the target wins")
  func tiePrefersNearTarget() {
    let samples = track(seconds: 90, silences: [(50.0, 50.6), (63.0, 63.6)])
    let first = MeetingPauseFinder.cuts(in: samples).first.map { Double($0.sample) / 16_000 }
    #expect(first.map { $0 >= 63.0 && $0 <= 63.6 } == true, "cut at \(String(describing: first))")
  }
}
