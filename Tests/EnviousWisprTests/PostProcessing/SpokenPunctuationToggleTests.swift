import Foundation
import Testing

@testable import EnviousWisprPostProcessing

/// #1794: the spoken-punctuation toggle gates the bare command rewrites and NOTHING else in
/// the inverse-text normalizer. #2955 added the joiners "slash" and "backslash" to the same table;
/// #3038 took the spoken SLASH out of the toggle: it is read in both switch positions by
/// `InverseTextNormalizer.slashReading` (see `SpokenSlashReadingTests` below), and only
/// backslash still follows the setting.
///
/// These tests deliberately do NOT characterise how badly the rules misfire on
/// content words ("the grace period expires", "in a coma"). `matcher-set-adversarial-tests`
/// would normally demand that for a routing matcher, but that rule protects a matcher we
/// rely on. We do not rely on this one: it is known-bad (#1367), now ships OFF, and the
/// long-term answer is the model handling it natively (#1364). What must be proven is
/// narrower — the switch works, and nothing else moved.
struct SpokenPunctuationToggleTests {

  private static let itn = InverseTextNormalizer()

  /// The spoken phrases the SETTING gates, line breaks aside: the nine marks in `punct` and the
  /// backslash joiner. Mirrors `SpokenPunctuationCopy.phrases` plus the two-word "back slash"
  /// alias the panel does not list; the copy-freeze test in the AppKit suite pins the
  /// user-facing side.
  static let gatedTriggers: [(spoken: String, mark: String)] = [
    ("comma", ","), ("period", "."), ("full stop", "."),
    ("question mark", "?"), ("exclamation mark", "!"), ("exclamation point", "!"),
    ("colon", ":"), ("semicolon", ";"),
    ("backslash", "\\"), ("back slash", "\\"),
  ]

  /// The spoken slash converts in BOTH switch positions (#3038); it is listed apart so the OFF
  /// tests below cannot accidentally require it to stay literal.
  static let alwaysOnCommands: [(spoken: String, mark: String)] = [
    ("slash", "/"), ("forward slash", "/"),
  ]

  /// Marks that glue to BOTH neighbours in the "alpha <phrase> beta" frame used below (two
  /// content words either side: `.glue` for the slash, the joiner rule for the backslash); every
  /// other mark keeps the space after it.
  static let joiners: Set<String> = ["/", "\\"]

  // MARK: - The switch works

  @Test("OFF leaves every gated trigger phrase as ordinary words", arguments: gatedTriggers)
  func offLeavesTriggersLiteral(trigger: (spoken: String, mark: String)) {
    let input = "alpha \(trigger.spoken) beta"
    let out = Self.itn.normalize(input, spokenPunctuation: false)
    #expect(
      out.contains(trigger.spoken),
      "\(trigger.spoken.debugDescription) should survive as text with the toggle OFF, got \(out.debugDescription)"
    )
    #expect(out.contains(trigger.mark) == false, "no mark expected, got \(out.debugDescription)")
  }

  @Test("ON converts every trigger phrase", arguments: gatedTriggers + alwaysOnCommands)
  func onConvertsTriggers(trigger: (spoken: String, mark: String)) {
    let input = "alpha \(trigger.spoken) beta"
    let out = Self.itn.normalize(input, spokenPunctuation: true)
    let want = "alpha\(trigger.mark)" + (Self.joiners.contains(trigger.mark) ? "beta" : "")
    #expect(out.contains(want), "expected \(want), got \(out.debugDescription)")
    #expect(
      out.contains(trigger.spoken) == false,
      "trigger word should be consumed, got \(out.debugDescription)")
  }

  /// #3038: the slash no longer waits for the setting. Same frame as the ON test, OFF.
  @Test("OFF converts the spoken slash too", arguments: alwaysOnCommands)
  func offConvertsSlash(trigger: (spoken: String, mark: String)) {
    let out = Self.itn.normalize("alpha \(trigger.spoken) beta", spokenPunctuation: false)
    #expect(out == "alpha/beta", "got \(out.debugDescription)")
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

  /// The `negative` and `url` parity rows whose bare spoken "slash" made the toggle diverge
  /// before #3038 (measured 2026-09-18 by running the pre-change oracle with and without its
  /// joiner). Listed by input so a row that stops converting, or starts converting differently,
  /// is named rather than counted.
  static let formerlyGatedBareSlashRows: [String] = [
      "So we need to stop worrying about oh don't worry it hasn't reached any users yet. No shit. We are we've not cut a release. We're just building in our sandbox slash dev environment.",
      "So I'm logged in right now under app.nbstaging.com slash dashboard.",
      "w w w dot c o m d a i l y n e w s dot a b slash s m",
      "c o m d a i l y n e w s dot a b slash s m",
      "example.com slash blog",
      "example dot ai slash docs",
      "example dot app slash download",
      "docs-2 dot xyz slash page-4",
      "docs-2.xyz slash page-4",
      "example.io slash docs",
      "alice at startup dot ai slash docs",
      "alice@sub.example.com slash docs",
      "alice@a.b.example.com slash docs",
      "find it at docs dot xyz slash page",
      "bob at example dot com slash unsubscribe",
      "bob at example.com slash unsubscribe",
      "bob at  example.com slash unsubscribe",
      "alice@example dot ai slash unsubscribe",
      "alice@sub.example dot ai slash unsubscribe",
      "find it at docs.xyz slash page",
      "look inside the dot app slash Contents slash MacOS folder",
      "plot the X dot XYZ slash Y coordinates",
      "www dot example.com slash docs",
      "my dash site.com slash docs",
      "alice @ example.com slash unsubscribe",
      "example.com slash docs dot html",
      "example.com slash user underscore settings",
      "https: slash slash example.com slash docs",
      "example.com slash search? q equals test",
      "example.com slash docs- slash next",
      "example.com slash docs slash",
      "example.com slash docs:",
      "example.com slash docs?",
      "3m dot com slash products",
      "check out 1password.com slash downloads",
  ]

  /// The strongest isolation proof: run the ENTIRE parity corpus both ways and pin exactly
  /// which rows the toggle changes, BY IDENTITY. Any row outside the pinned set means the gate
  /// leaked; an empty set means the test went vacuous.
  ///
  /// The pinned rows come from a real run (2026-09-18), never a prediction. Since #3038 the
  /// spoken slash is read in both switch positions, so the only corpus rows the toggle still
  /// moves are the `punctuation` rows that carry one of the nine marks and five `url` rows: four
  /// whose protocol carries a spoken "colon" (the reading sees a scheme with its colon ON and a
  /// bare "colon" word OFF: `h t t p://` versus `h t t p colon slash slash`) and one #2257 guard
  /// fixture carrying "question mark". The 20 `negative` rows and 4 `url` rows that used to
  /// diverge on a bare "slash" (#2955) no longer do, because the slash reading does not consult
  /// the setting. Two pins, both required: the identity pin
  /// catches a rule firing on a row it should not touch, and the trigger-presence pin catches a
  /// row moving for a reason that is not in the table at all.
  @Test("Toggle changes exactly the pinned corpus rows and no others")
  func corpusIsolation() throws {
    let rows = try InverseTextNormalizerParityTests.loadRows()
    #expect(rows.count > 1500, "parity fixture looks truncated: \(rows.count) rows")

    let divergent = rows.filter {
      Self.itn.normalize($0.input, spokenPunctuation: false)
        != Self.itn.normalize($0.input, spokenPunctuation: true)
    }
    #expect(divergent.isEmpty == false, "vacuous: the toggle changed nothing across the corpus")

    let allowed: Set<String> = ["punctuation", "url"]
    let unexpected = divergent.filter { !allowed.contains($0.category) }
    let leaked = unexpected.prefix(10)
      .map { "[\($0.category)] \($0.input.debugDescription)" }
      .joined(separator: ", ")
    #expect(unexpected.isEmpty, "toggle leaked outside punctuation/url: \(leaked)")

    // The url rows, by identity, with what each switch position writes.
    let urlDivergent = divergent.filter { $0.category == "url" }
    let pinnedURL: [String: (off: String, on: String)] = [
      "h t t p colon slash slash w w w dot o u r d a i l y n e w s dot com dot s m": (
        "h t t p colon slash slash w w w dot o u r d a i l y n e w s.com dot s m",
        "h t t p://w w w dot o u r d a i l y n e w s.com dot s m"),
      "h t t p colon slash slash w w w dot c o m d a i l y n e w s dot a b dot s m": (
        "h t t p colon slash slash w w w dot c o m d a i l y n e w s dot a b dot s m",
        "h t t p://w w w dot c o m d a i l y n e w s dot a b dot s m"),
      "h t t p colon slash slash w w w dot c o m d a i l y n e w s dot a b slash s m": (
        "h t t p colon slash slash w w w dot c o m d a i l y n e w s dot a b/s m",
        "h t t p://w w w dot c o m d a i l y n e w s dot a b/s m"),
      "https colon slash slash example.com slash docs": (
        "https colon slash slash example.com/docs",
        "https://example.com/docs"),
      // A #2257 guard fixture: "question mark" is a gated command; the slash is not.
      "example.com slash search question mark q equals test": (
        "example.com/search question mark q equals test",
        "example.com/search? Q equals test"),
    ]
    #expect(
      Set(urlDivergent.map(\.input)) == Set(pinnedURL.keys),
      Comment(
        rawValue: "url rows the toggle moves: "
          + urlDivergent.map {
            "\($0.input.debugDescription) OFF=\(Self.itn.normalize($0.input, spokenPunctuation: false).debugDescription) ON=\(Self.itn.normalize($0.input, spokenPunctuation: true).debugDescription)"
          }.joined(separator: " | ")))
    for row in urlDivergent {
      guard let pin = pinnedURL[row.input] else { continue }
      #expect(
        Self.itn.normalize(row.input, spokenPunctuation: false) == pin.off,
        "OFF: \(row.input.debugDescription) -> \(Self.itn.normalize(row.input, spokenPunctuation: false).debugDescription)")
      #expect(
        Self.itn.normalize(row.input, spokenPunctuation: true) == pin.on,
        "ON: \(row.input.debugDescription) -> \(Self.itn.normalize(row.input, spokenPunctuation: true).debugDescription)")
    }

    // The bare-slash rows that DID diverge before #3038 (the joiner followed the setting), by
    // identity: both switch positions now write the baked fixture expectation, which is an
    // independent oracle output, not this implementation's.
    let byInput = Dictionary(rows.map { ($0.input, $0.expected) }, uniquingKeysWith: { first, _ in first })
    for input in Self.formerlyGatedBareSlashRows {
      guard let expected = byInput[input] else {
        Issue.record("formerly gated row is no longer in parity.jsonl: \(input.debugDescription)")
        continue
      }
      let off = Self.itn.normalize(input, spokenPunctuation: false)
      let on = Self.itn.normalize(input, spokenPunctuation: true)
      #expect(off == expected, "OFF \(input.debugDescription) -> \(off.debugDescription)")
      #expect(on == expected, "ON \(input.debugDescription) -> \(on.debugDescription)")
    }

    let phrases = Self.gatedTriggers.map(\.spoken) + ["new line", "new paragraph"]
    for row in divergent {
      let carriesTrigger = phrases.contains { phrase in
        let pattern = #"\b"# + NSRegularExpression.escapedPattern(for: phrase) + #"\b"#
        return row.input.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
      }
      #expect(carriesTrigger, "row moved without a spoken command in it: \(row.input.debugDescription)")
    }
  }

  /// #2955: the list-marker guard reads a spoken "slash"/"backslash" as the word it is, so the
  /// marker after it converts in both switch positions; the backslash joiner itself follows the
  /// toggle and the slash (#3038) does not. Pins the deliberate decision NOT to add the joiners
  /// to `punctCommandTails`.
  @Test(
    "A list marker after a spoken joiner converts whether or not the joiner does",
    arguments: [
      ("docs slash A one", "docs/A1", "docs/A1"),
      ("docs backslash A one", "docs\\A1", "docs backslash A1"),
      // #3038 R2: the recogniser's comma before a spoken slash is dropped when the slash glues;
      // the backslash keeps it in both positions.
      ("docs, back slash A one", "docs,\\A1", "docs, back slash A1"),
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
