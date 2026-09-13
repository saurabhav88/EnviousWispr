import Foundation
import Testing

@testable import EnviousWisprPostProcessing

/// Register-preserved spans are put back in ONE pass, and that pass decides exactly what the
/// per-span loop it replaced decided (#2759).
///
/// Why this exists: `normalize` shields idioms like "quarter past four" behind a
/// `\u{0}<index>\u{0}` sentinel, and used to restore them with one `replacingOccurrences` per
/// span, a full scan of the take per idiom. A take that repeats an idiom paid O(text x spans)
/// inside the same 0.5 s budget #2758 already defends. The single pass is the fix; these rows
/// pin that it restores every span verbatim and leaves alone the one shape where a loop and a
/// pass could differ.
///
/// Drift guard: a slow restoration still produces the right text, so nothing here is safety
/// for the user. The product claim (the idioms survive) is `everySpanSurvivesALongTake`.
@Suite("ITN protected spans are restored in one pass (#2759)", .tags(.driftGuard))
struct InverseTextNormalizerSpanRestoreTests {

  /// The loop this replaced, kept here as the ORACLE the pass must agree with.
  private static func loopRestore(_ text: String, _ protected: [String]) -> String {
    var t = text
    for (i, p) in protected.enumerated() {
      t = t.replacingOccurrences(
        of: "\u{0}\(i)\u{0}", with: p.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    return t
  }

  private static func sentinel(_ i: Int) -> String { "\u{0}\(i)\u{0}" }

  @Test(
    "the pass agrees with the loop on every shape the sentinel can take",
    arguments: [
      // (text with sentinels, protected spans)
      (" a \u{0}0\u{0} b ", ["quarter past four"]),
      (" \u{0}0\u{0} \u{0}1\u{0} ", ["quarter past four", " eleventh hour "]),
      // out of order, and a span used twice
      (" \u{0}1\u{0} then \u{0}0\u{0} then \u{0}1\u{0} ", ["half past ten", "seventh heaven"]),
      // an index that names no span stays as it was, in both
      (" \u{0}9\u{0} and \u{0}0\u{0} ", ["the fourth wall"]),
      // a bare NUL, a NUL with letters, and a sentinel with no digits are not sentinels
      (" \u{0} \u{0}x\u{0} \u{0}\u{0} \u{0}0\u{0} ", ["first among equals"]),
      // ten or more spans: the index has two digits and must not be read as two sentinels
      (
        (0..<12).map { " \u{0}\($0)\u{0}" }.joined() + " ",
        (0..<12).map { "quarter to \($0)" }
      ),
      // no spans at all: nothing to restore, text untouched
      (" nothing here \u{0}0\u{0} ", []),
      ("", ["quarter past four"]),
    ] as [(text: String, spans: [String])])
  func passAgreesWithLoop(text: String, spans: [String]) {
    #expect(
      InverseTextNormalizer.restoreProtectedSpans(text, spans) == Self.loopRestore(text, spans),
      "the single pass must decide exactly what the loop decided")
  }

  /// The product claim: a long take that repeats an idiom gets every copy back verbatim, and
  /// no sentinel leaks into the text the user sees.
  @Test("every span survives a long take, and no sentinel leaks")
  func everySpanSurvivesALongTake() {
    let idiom = "quarter past four"
    let take = (0..<300).map { "at \(idiom) on day \($0 + 1)" }.joined(separator: ", ") + "."
    let out = InverseTextNormalizer().normalize(take)
    #expect(!out.contains("\u{0}"), "a sentinel reached the output")
    #expect(
      out.components(separatedBy: idiom).count - 1 == 300,
      "every one of 300 protected idioms must come back spelled")
  }

  /// The pass is one regex visit over the text, so a span count that grows ten-fold must not
  /// grow the work ten-fold. Asserted as a RELATION between two runs in the same process,
  /// never as an absolute number (validation-discipline: a local performance number is a
  /// measurement of the machine).
  @Test("restoring ten times the spans costs far less than ten times the time")
  func costDoesNotTrackSpanCount() {
    func build(_ n: Int) -> (String, [String]) {
      let spans = (0..<n).map { "quarter past \($0)" }
      let text =
        " " + (0..<n).map { "filler words here \u{0}\($0)\u{0}" }.joined(separator: " ") + " "
      return (text, spans)
    }
    func time(_ n: Int) -> Double {
      let (text, spans) = build(n)
      var best = Double.infinity
      for _ in 0..<5 {
        let start = DispatchTime.now().uptimeNanoseconds
        _ = InverseTextNormalizer.restoreProtectedSpans(text, spans)
        best = min(best, Double(DispatchTime.now().uptimeNanoseconds - start))
      }
      return best
    }
    _ = time(200)  // warm the regex cache
    let small = time(200)
    let large = time(2000)
    // Linear would be ~10x; the loop was ~100x. Generous bound so contention cannot fail it.
    #expect(
      large < small * 40,
      "2000 spans took \(large / 1e6) ms against \(small / 1e6) ms for 200: not one pass")
  }
}
