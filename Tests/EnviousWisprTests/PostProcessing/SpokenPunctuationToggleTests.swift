import Foundation
import Testing

@testable import EnviousWisprPostProcessing

/// #1794: the spoken-punctuation toggle gates the nine bare command rewrites and NOTHING
/// else in the inverse-text normalizer.
///
/// These tests deliberately do NOT characterise how badly the nine rules misfire on
/// content words ("the grace period expires", "in a coma"). `matcher-set-adversarial-tests`
/// would normally demand that for a routing matcher, but that rule protects a matcher we
/// rely on. We do not rely on this one: it is known-bad (#1367), now ships OFF, and the
/// long-term answer is the model handling it natively (#1364). What must be proven is
/// narrower — the switch works, and nothing else moved.
struct SpokenPunctuationToggleTests {

  private static let itn = InverseTextNormalizer()

  /// The ten spoken phrases the nine `punct` tuples produce. Mirrors
  /// `SpokenPunctuationCopy.phrases`; the copy-freeze test in the AppKit suite pins the
  /// user-facing side.
  static let triggers: [(spoken: String, mark: String)] = [
    ("comma", ","), ("period", "."), ("full stop", "."),
    ("question mark", "?"), ("exclamation mark", "!"), ("exclamation point", "!"),
    ("colon", ":"), ("semicolon", ";"),
  ]

  // MARK: - The switch works

  @Test("OFF leaves every trigger phrase as ordinary words", arguments: triggers)
  func offLeavesTriggersLiteral(trigger: (spoken: String, mark: String)) {
    let input = "alpha \(trigger.spoken) beta"
    let out = Self.itn.normalize(input, spokenPunctuation: false)
    #expect(
      out.contains(trigger.spoken),
      "\(trigger.spoken.debugDescription) should survive as text with the toggle OFF, got \(out.debugDescription)"
    )
    #expect(out.contains(trigger.mark) == false, "no mark expected, got \(out.debugDescription)")
  }

  @Test("ON converts every trigger phrase", arguments: triggers)
  func onConvertsTriggers(trigger: (spoken: String, mark: String)) {
    let input = "alpha \(trigger.spoken) beta"
    let out = Self.itn.normalize(input, spokenPunctuation: true)
    #expect(
      out.contains("alpha\(trigger.mark)"),
      "expected alpha\(trigger.mark), got \(out.debugDescription)")
    #expect(
      out.contains(trigger.spoken) == false,
      "trigger word should be consumed, got \(out.debugDescription)")
  }

  @Test("Line-break triggers convert only when ON")
  func lineBreakTriggers() {
    #expect(Self.itn.normalize("alpha new line beta", spokenPunctuation: true).contains("\n"))
    #expect(
      Self.itn.normalize("alpha new paragraph beta", spokenPunctuation: true).contains("\n\n"))
    #expect(
      Self.itn.normalize("alpha new line beta", spokenPunctuation: false).contains("\n") == false)
    #expect(
      Self.itn.normalize("alpha new paragraph beta", spokenPunctuation: false).contains("\n")
        == false)
  }

  /// Matching is case-insensitive today (`reSub` defaults `caseInsensitive: true`). Frozen
  /// so nobody "tidies" it into case-sensitivity without noticing it is a behaviour change.
  @Test("Case variants follow the switch, not the case")
  func caseInsensitivity() {
    #expect(Self.itn.normalize("alpha Period beta", spokenPunctuation: true).contains("alpha."))
    #expect(Self.itn.normalize("alpha Period beta", spokenPunctuation: false).contains("Period"))
  }

  // MARK: - Nothing else moved

  /// Capitalization lives inside `applyPunct` beside the gated loop but must NOT be gated:
  /// it keys off `.!?` whoever produced them, including the recognizer's own marks.
  ///
  /// The leading `h` stays lowercase in BOTH arms because `normalize` pads its working
  /// string with a leading space, so the `^` branch never matches the real first character.
  @Test("Sentence capitalization runs with the toggle OFF")
  func capitalizationSurvivesOff() {
    #expect(Self.itn.normalize("hello. world", spokenPunctuation: false) == "hello. World")
    #expect(Self.itn.normalize("hello period world", spokenPunctuation: true) == "hello. World")
  }

  @Test(
    "Non-punctuation conversions are identical in both switch positions",
    arguments: [
      "we counted twenty three",
      "the invoice is eighty five dollars",
      "we raised eighty million dollars last year",
      "i was born in nineteen eighty seven",
      "call me at 203 nine five four eight eight seven nine",
      "email casey at proton dot me",
      "visit stackoverflow dot io slash blog",
      "the twentieth century",
      "five point five percent",
    ])
  func otherCategoriesUnaffected(input: String) {
    let off = Self.itn.normalize(input, spokenPunctuation: false)
    let on = Self.itn.normalize(input, spokenPunctuation: true)
    #expect(
      off == on,
      "toggle leaked into a non-punctuation category: \(off.debugDescription) vs \(on.debugDescription)"
    )
  }

  /// The strongest isolation proof: run the ENTIRE 2,064-row parity corpus both ways and
  /// pin exactly which rows the toggle changes. Any row outside the pinned set means the
  /// gate leaked; an empty set means the test went vacuous.
  ///
  /// The pinned set is derived from a real run, never predicted. It contains the
  /// punctuation-category rows that actually carry a trigger, plus three `url` rows whose
  /// degenerate spelled-out input ("h t t p colon slash slash ...") happens to hit the
  /// `colon` rule. Those three are NOT real URL handling — the URL rule matches
  /// `host dot tld` and is untouched by this change.
  @Test("Toggle changes exactly the pinned corpus rows and no others")
  func corpusIsolation() throws {
    let rows = try InverseTextNormalizerParityTests.loadRows()
    #expect(rows.count > 1500, "parity fixture looks truncated: \(rows.count) rows")

    let divergent = rows.filter {
      Self.itn.normalize($0.input, spokenPunctuation: false)
        != Self.itn.normalize($0.input, spokenPunctuation: true)
    }
    #expect(divergent.isEmpty == false, "vacuous: the toggle changed nothing across the corpus")

    let unexpected = divergent.filter { $0.category != "punctuation" && $0.category != "url" }
    let leaked = unexpected.prefix(10)
      .map { "[\($0.category)] \($0.input.debugDescription)" }
      .joined(separator: ", ")
    #expect(unexpected.isEmpty, "toggle leaked outside punctuation/url: \(leaked)")

    let urlDivergent = divergent.filter { $0.category == "url" }
    let urlSample = urlDivergent.prefix(5).map { $0.input.debugDescription }.joined(separator: ", ")
    #expect(
      urlDivergent.count == 3,
      "expected exactly the 3 degenerate spelled-out url rows, got \(urlDivergent.count): \(urlSample)"
    )
    for row in urlDivergent {
      #expect(
        row.input.contains("colon"),
        "a url row diverged for a reason other than the colon rule: \(row.input.debugDescription)")
    }
  }

  @Test("Idempotence holds in both switch positions")
  func idempotenceBothWays() throws {
    let rows = try InverseTextNormalizerParityTests.loadRows()
    for flag in [false, true] {
      var unstable: [(String, String, String)] = []
      for row in rows
      where InverseTextNormalizerParityTests.knownNonIdempotentInputs.contains(row.input) == false {
        let once = Self.itn.normalize(row.input, spokenPunctuation: flag)
        let twice = Self.itn.normalize(once, spokenPunctuation: flag)
        if twice != once { unstable.append((row.input, once, twice)) }
      }
      #expect(
        unstable.isEmpty, "non-idempotent with spokenPunctuation=\(flag): \(unstable.prefix(5))")
    }
  }

  /// The parameter defaults to `false` so a caller that forgets it gets the non-rewriting
  /// behaviour, which is what keeps the gitignored local ASR benchmark source-compatible.
  @Test("The default argument is OFF")
  func defaultArgumentIsOff() {
    #expect(
      Self.itn.normalize("alpha comma beta")
        == Self.itn.normalize("alpha comma beta", spokenPunctuation: false))
    #expect(Self.itn.normalize("alpha comma beta").contains("comma"))
  }
}
