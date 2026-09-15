import Foundation
import Testing

@testable import EnviousWisprPostProcessing

/// #1794: the spoken-punctuation toggle gates the bare command rewrites and NOTHING else in
/// the inverse-text normalizer. #2955 added the joiners "slash" and "backslash" to the same table.
///
/// These tests deliberately do NOT characterise how badly the rules misfire on
/// content words ("the grace period expires", "in a coma"). `matcher-set-adversarial-tests`
/// would normally demand that for a routing matcher, but that rule protects a matcher we
/// rely on. We do not rely on this one: it is known-bad (#1367), now ships OFF, and the
/// long-term answer is the model handling it natively (#1364). What must be proven is
/// narrower — the switch works, and nothing else moved.
struct SpokenPunctuationToggleTests {

  private static let itn = InverseTextNormalizer()

  /// The spoken phrases the `punct` tuples produce, line breaks aside. Mirrors
  /// `SpokenPunctuationCopy.phrases` plus the two-word "back slash" alias the panel does not list;
  /// the copy-freeze test in the AppKit suite pins the user-facing side.
  static let triggers: [(spoken: String, mark: String)] = [
    ("comma", ","), ("period", "."), ("full stop", "."),
    ("question mark", "?"), ("exclamation mark", "!"), ("exclamation point", "!"),
    ("colon", ":"), ("semicolon", ";"),
    ("slash", "/"), ("forward slash", "/"), ("backslash", "\\"), ("back slash", "\\"),
  ]

  /// Marks that glue to BOTH neighbours; every other mark keeps the space after it.
  static let joiners: Set<String> = ["/", "\\"]

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
    let want = "alpha\(trigger.mark)" + (Self.joiners.contains(trigger.mark) ? "beta" : "")
    #expect(out.contains(want), "expected \(want), got \(out.debugDescription)")
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

  /// The strongest isolation proof: run the ENTIRE parity corpus both ways and pin exactly
  /// which rows the toggle changes. Any row outside the pinned set means the gate leaked; an
  /// empty set means the test went vacuous.
  ///
  /// The pinned counts are derived from a real run, never predicted. Three categories move:
  /// the punctuation-category rows that carry a trigger; `url` rows whose spelled-out or
  /// refused input still carries "colon", "question mark" or a bare "slash" the URL passes
  /// left behind (#2257 guard fixtures and the degenerate "h t t p colon slash slash" rows);
  /// and `negative` rows that carry a bare "slash" the URL passes deliberately refused to
  /// convert (#2955). None of them is URL handling changing with the toggle — the URL rules
  /// are untouched by `spokenPunctuation`; the applyPunct pass beside them is what moves.
  /// Two pins, both required: the category+count pin catches a rule firing on a row it
  /// should not touch, and the trigger-presence pin catches a row moving for a reason that
  /// is not in the table at all.
  @Test("Toggle changes exactly the pinned corpus rows and no others")
  func corpusIsolation() throws {
    let rows = try InverseTextNormalizerParityTests.loadRows()
    #expect(rows.count > 1500, "parity fixture looks truncated: \(rows.count) rows")

    let divergent = rows.filter {
      Self.itn.normalize($0.input, spokenPunctuation: false)
        != Self.itn.normalize($0.input, spokenPunctuation: true)
    }
    #expect(divergent.isEmpty == false, "vacuous: the toggle changed nothing across the corpus")

    let allowed: Set<String> = ["punctuation", "url", "negative"]
    let unexpected = divergent.filter { !allowed.contains($0.category) }
    let leaked = unexpected.prefix(10)
      .map { "[\($0.category)] \($0.input.debugDescription)" }
      .joined(separator: ", ")
    #expect(unexpected.isEmpty, "toggle leaked outside punctuation/url/negative: \(leaked)")

    let urlDivergent = divergent.filter { $0.category == "url" }
    let negativeDivergent = divergent.filter { $0.category == "negative" }
    let urlSample = urlDivergent.prefix(5).map { $0.input.debugDescription }.joined(separator: ", ")
    let negSample = negativeDivergent.prefix(5).map { $0.input.debugDescription }
      .joined(separator: ", ")
    #expect(
      urlDivergent.count == 9,
      "expected exactly the 9 pinned url rows (3 degenerate colon spellouts, 2 #2257 guard fixtures, 4 refused spelled-out paths with a bare slash), got \(urlDivergent.count): \(urlSample)")
    #expect(
      negativeDivergent.count == 20,
      "expected exactly the 20 pinned negative rows (bare slash after a refused URL conversion, #2955), got \(negativeDivergent.count): \(negSample)")
    for row in urlDivergent {
      let reasonMessage =
        "a url row diverged for a reason other than colon/question mark/slash: "
        + "\(row.input.debugDescription)"
      #expect(
        row.input.contains("colon") || row.input.contains("question mark")
          || row.input.contains("slash"), "\(reasonMessage)")
    }

    let phrases = Self.triggers.map(\.spoken) + ["new line", "new paragraph"]
    for row in divergent {
      let carriesTrigger = phrases.contains { phrase in
        let pattern = #"\b"# + NSRegularExpression.escapedPattern(for: phrase) + #"\b"#
        return row.input.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
      }
      #expect(carriesTrigger, "row moved without a spoken command in it: \(row.input.debugDescription)")
    }
  }

  /// #2955: the list-marker guard reads a spoken "slash"/"backslash" as the word it is, so the
  /// marker after it converts in both switch positions; only the joiner itself follows the
  /// toggle. Pins the deliberate decision NOT to add the joiners to `punctCommandTails`.
  @Test(
    "A list marker after a spoken joiner converts whether or not the joiner does",
    arguments: [
      ("docs slash A one", "docs/A1", "docs slash A1"),
      ("docs backslash A one", "docs\\A1", "docs backslash A1"),
    ])
  func joinerDoesNotShieldListMarker(input: String, on: String, off: String) {
    #expect(Self.itn.normalize(input, spokenPunctuation: true) == on)
    #expect(Self.itn.normalize(input, spokenPunctuation: false) == off)
  }

  /// #2955: a wider gap inside the two-word alias must not leave the slash rule a bare "slash"
  /// to eat ("back  slash" is one command, never "back/"). ON only: with the setting off the
  /// normalizer collapses the run to one space, so the OFF arm is the ordinary "back slash" row.
  @Test("A wide gap inside back slash is still one command")
  func wideGapAliasIsOneCommand() {
    #expect(Self.itn.normalize("alpha back  slash beta", spokenPunctuation: true) == "alpha\\beta")
    #expect(Self.itn.normalize("alpha back\tslash beta", spokenPunctuation: true) == "alpha\\beta")
  }

  /// #2955: a joiner consumes the spaces around it but never the line break that "new line"
  /// or "new paragraph" just inserted, so a path dictated at the start of a new line stays on
  /// that line.
  @Test("A joiner keeps a line break the line-break commands inserted")
  func joinerKeepsLineBreak() {
    #expect(
      Self.itn.normalize("alpha new line slash beta", spokenPunctuation: true).contains("\n/beta"))
    #expect(
      Self.itn.normalize("alpha new paragraph backslash beta", spokenPunctuation: true)
        .contains("\n\n\\beta"))
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
