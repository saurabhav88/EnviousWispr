import Foundation
import Testing

@testable import EnviousWisprPostProcessing

/// Inert padding: no number word, ordinal, unit noun, age period, month, or connector this
/// file reacts to, and no `.!?` (so `applyPunct`'s sentence-capitalization pass cannot touch its
/// first letter and change the text under the comparisons below). Appending it must extend a take
/// without adding a single match of its own.
private let inertTail = String(
  repeating: " plus the discussion kept going quite a while longer afterwards", count: 300)

/// Sentence-initial inert lead: ends on `. `, so a match placed after it is still
/// sentence-initial however many times the unit repeats. Already capitalized, so `applyPunct`
/// leaves every copy alone.
private let sentenceLead = "This is prior context. "

/// Mid-sentence inert lead: ends on an ordinary word, so a match placed after it is NOT
/// sentence-initial. Also already capitalized, for the same reason.
private let midSentenceLead = "Then he said that "

/// The neighbour reads the ITN passes make around a match are BOUNDED, and bounding them
/// changed nothing about what those passes decide.
///
/// Why this exists: the cardinal pass fires once per number-word run and used to answer
/// "what follows this match" with `ns.substring(from: end)` — a copy, then a `splitWords`
/// tokenization, of every remaining character of the take. That is O(text) per match and so
/// O(text x matches) per call, quadratic in a long numeric dictation, which is how a chain
/// that costs milliseconds on a sentence reaches `InverseTextNormalizationStep`'s 0.5s
/// `withDeadline` and reports `inverse_normalization_timeout` (Sentry, v2.4.8, macOS 26.6.2).
/// `tailWindow` / `lastTokenBefore` answer the same questions from the neighbouring TOKENS.
///
/// The parity fixture cannot cover this on its own: `parity.jsonl` rows are single sentences,
/// so their tails are already short and a window that is too small would still pass every one
/// of them. What needs proving here is the pair of claims parity does not reach:
///
/// 1. The window really is bounded — its size tracks the neighbouring tokens, NOT the rest of
///    the take. That is the whole complexity claim, asserted structurally rather than with a
///    wall clock (which would be flaky in CI and says nothing on a fast machine anyway).
/// 2. Every guard that reads a neighbour decides the same way with a long take around it as it
///    does alone — the case the old whole-tail read paid for and a too-small window breaks.
///
/// Claim 1 is this suite, and it is a DRIFT GUARD: an unbounded window still produces the
/// right text, just slowly, so nothing here is safety for the user. Claim 2 is the product
/// outcome and lives in `InverseTextNormalizerLongTakeConversionTests` below.
@Suite("ITN neighbour reads stay bounded (#2758)", .tags(.driftGuard))
struct InverseTextNormalizerNeighbourWindowTests {

  /// The invariant the timeout fix rests on: text beyond the second token cannot make the
  /// window any bigger, so the per-match cost stops tracking the length of the take.
  @Test("tailWindow size is set by the next few tokens, not by the length of the take")
  func tailWindowIsBounded() {
    let head = "we counted twenty"
    let short = "\(head) miles out"
    let long = "\(head) miles out\(inertTail)"
    let end = (head as NSString).length

    // A tail with nothing past its own two tokens stops at the end of the text.
    #expect(InverseTextNormalizer.tailWindow(short as NSString, end) == " miles out")
    // 15 characters of window against a take of more than fifteen THOUSAND — and the padding is
    // what the old read copied, and `splitWords` then tokenized, on every single match.
    #expect(InverseTextNormalizer.tailWindow(long as NSString, end) == " miles out plus")
    #expect((long as NSString).length > 15_000)
  }

  /// Same claim on the other side: text further back than the previous token is never read.
  @Test("lastTokenBefore size is set by the previous token, not by the length of the take")
  func lastTokenBeforeIsBounded() {
    let lead = String(repeating: sentenceLead, count: 500) + "roughly"
    let ns = "\(lead) twenty miles" as NSString
    let before = InverseTextNormalizer.lastTokenBefore(ns, (lead as NSString).length)

    #expect(before.token == "roughly")
    #expect(before.headIsBlank == false)
    #expect(ns.length > 10_000)
  }

  /// `lastTokenBefore` collapses the two questions the old whole-head read answered: `token`
  /// is `splitWords(head).last ?? ""`, and `headIsBlank` is whether the head trimmed of
  /// trailing whitespace is empty — so when it is not, `token.last` is that trimmed head's
  /// last character, which is the sentence-boundary sentinel the cardinal pass tests.
  @Test(
    "lastTokenBefore reproduces the whole-head read",
    arguments: [
      ("", true, ""),
      ("   ", true, ""),
      ("\n\n", true, ""),
      ("He said.", false, "said."),
      ("He said. ", false, "said."),
      ("He said.\n", false, "said."),
      ("(", false, "("),
      ("a NASA", false, "NASA"),
    ] as [(head: String, blank: Bool, token: String)])
  func lastTokenBeforeMatchesWholeHead(head: String, blank: Bool, token: String) {
    let ns = "\(head)twenty" as NSString
    let got = InverseTextNormalizer.lastTokenBefore(ns, (head as NSString).length)
    #expect(got.headIsBlank == blank)
    #expect(got.token == token)
  }

  /// The equivalence the whole thing rests on, checked against the whole-text read it replaced
  /// rather than against baked values.
  ///
  /// `splitWords` asks `Character.isWhitespace`, which classifies a whole GRAPHEME CLUSTER by its
  /// FIRST scalar, so a combining mark sitting against a space is whitespace to it and a token to
  /// a scalar scan. An earlier draft of `tailWindow` scanned scalars and stopped a token short on
  /// exactly that input, which cost `"it covers two \u{0301} square miles"` its conversion.
  @Test(
    "the window's first two tokens are the whole tail's first two tokens",
    arguments: [
      "",
      " ",
      " miles",
      " square miles out",
      "-year-old boy now",
      " of a second",
      " and one hundred more",
      " \u{0301} square miles",
      " \u{0301}\u{0301} square miles out",
      "\u{0301} square miles out",
      "\r\n square miles out",
      "\u{00A0}square\u{2028}miles out",
      " \u{1F1FA}\u{1F1F8} square miles",
      " e\u{0301}clair square miles",
      " \u{200D} square miles",
    ])
  func windowKeepsTheFirstTwoTokens(tail: String) {
    let head = "twenty"
    let ns = "\(head)\(tail)" as NSString
    let window = InverseTextNormalizer.tailWindow(ns, (head as NSString).length)
    #expect(
      Array(InverseTextNormalizer.splitWords(window).prefix(2))
        == Array(InverseTextNormalizer.splitWords(tail).prefix(2)))
    // The anchored `^\s+...` probes and the `.first == "-"` glue test read from the very start.
    #expect(window.first == tail.first)
  }

  /// The head side of the same equivalence, against the same oracle.
  @Test(
    "lastTokenBefore reports the whole head's last token and its blankness",
    arguments: [
      "", "   ", "\n\n", "He said.", "He said. ", "He said.\n", "(", "a NASA ",
      "He said. \u{0301} ", "NASA \u{0301} ", "x\u{0301} ", " \u{0301}\u{0301} ",
      "He said.\u{00A0}", "one\r\ntwo ", "\u{0301}", "he said e\u{0301}clair ",
    ])
  func headMatchesTheWholeHead(head: String) {
    let ns = "\(head)twenty" as NSString
    let got = InverseTextNormalizer.lastTokenBefore(ns, (head as NSString).length)
    var trimmed = head
    while let last = trimmed.last, last.isWhitespace { trimmed.removeLast() }
    #expect(got.headIsBlank == trimmed.isEmpty)
    #expect(got.token == (InverseTextNormalizer.splitWords(head).last ?? ""))
  }

  /// The leading gap is kept, because the anchored probes that read the window
  /// (`^\s+and\s+...`, `^\s+of\b`) and the `.first == "-"` glue test all start at `end`. A
  /// tail with fewer than two tokens degrades to exactly what the whole-tail read gave.
  @Test(
    "tailWindow preserves the leading gap and handles a short tail",
    arguments: [
      ("", ""),
      (" ", " "),
      ("-year-old", "-year-old"),
      (" of a second", " of a second"),
      (" and one hundred", " and one hundred"),
      (" miles", " miles"),
    ] as [(tail: String, window: String)])
  func tailWindowShapes(tail: String, window: String) {
    let head = "twenty"
    let ns = "\(head)\(tail)" as NSString
    #expect(InverseTextNormalizer.tailWindow(ns, (head as NSString).length) == window)
  }
}

/// Bounding the neighbour reads changed nothing about what the ITN passes DECIDE: a take with
/// numbers in it comes back formatted the same way whether it stands alone or sits inside a
/// long dictation. When this fails the user is pasted a phone number, date, currency amount or
/// measurement left in spoken form.
///
/// Claim 2 is asserted as an INVARIANT (`long` extends `short`) rather than against baked
/// output, so these tests pin the property under test and cannot drift into a second, weaker
/// copy of the parity fixture. The exact outputs in the last test are the oracle's own rows,
/// re-run with a long tail attached.
@Suite("ITN converts the same inside a long take (#2758)", .tags(.productOutcome))
struct InverseTextNormalizerLongTakeConversionTests {

  private static let itn = InverseTextNormalizer()

  /// One row per guard that reads across the match boundary. Each is normalized alone and
  /// again with `inertTail` appended; since the padding adds no match of its own, a correct
  /// window makes the long output the short one with the padding carried through verbatim.
  ///
  /// A window too small to reach the deciding neighbour flips exactly one of these and breaks
  /// the prefix — which is the failure the old whole-tail read bought at O(text) per match.
  @Test(
    "a neighbour-reading guard decides the same buried in a long take as it does alone",
    arguments: [
      // AP unit-noun anchor: forces digits below the spell-out threshold (reads token 1).
      "I walked two miles",
      // unit with a modifier (reads token 2).
      "it covers two square miles",
      // age period (reads token 2).
      "she is five years old",
      // hyphenated age compound (anchored probe inside token 1).
      "a five-year-old boy",
      // unit inside a hyphenated compound (splits token 1 on "-").
      "a five-foot-tall person",
      // no anchor at all: AP spells it out, and the padding must not change that.
      "I walked two blocks",
      // capitalized mid-sentence is ambiguous and stays spelled (reads the previous token).
      "the Forty Niners won",
      // all-caps title guard, which reads the previous token (this take is not shout: the
      // padding is lowercase either way, so the shout branch is not what is being compared).
      "TWELVE ANGRY MEN screened tonight",
      // "by" idiom guard (reads token 1 after the match) ...
      "go one by one",
      // ... and the same shape with a unit noun after it, which IS a dimension.
      "a one by one inch tile",
      // "between A and B" declines when a trailing "and <number>" means a truncated endpoint.
      "between one hundred and five and one hundred and ten",
      // scale-ordinal fraction guard (anchored "of" probe) ...
      "a thousandth of a second",
      // ... and without the "of", the ordinal.
      "the thousandth visitor",
    ])
  func guardDecidesTheSameWithALongTail(input: String) {
    let alone = Self.itn.normalize(input, spokenPunctuation: false)
    let buried = Self.itn.normalize(input + inertTail, spokenPunctuation: false)
    #expect(buried == alone + inertTail)
  }

  /// The head side of the same claim. Repeating an inert lead moves the match further from the
  /// start of the take without changing the token immediately before it, so every guard that
  /// reads backwards must reach the same verdict and leave the same suffix.
  @Test(
    "a neighbour-reading guard decides the same after a long lead as after a short one",
    arguments: [
      "Twenty people came",  // sentence-initial capital vs capitalized mid-sentence
      "TWELVE ANGRY MEN screened tonight",  // all-caps title guard reads the previous token
      "I said TWELVE times",  // isolated all-caps number, same guard, other verdict
      "two miles per hour",
    ], [sentenceLead, midSentenceLead])
  func guardDecidesTheSameAfterALongLead(input: String, lead: String) {
    let short = Self.itn.normalize(lead + input, spokenPunctuation: false)
    let long = Self.itn.normalize(
      String(repeating: lead, count: 300) + input, spokenPunctuation: false)
    #expect(long.hasSuffix(short))
  }

  /// A combining mark between a number and the unit noun that anchors it is whitespace to
  /// `splitWords`, so the unit is still the neighbour the AP rule reads and the number still
  /// becomes a figure.
  @Test("a combining mark beside a number does not cost it its conversion")
  func combiningMarkKeepsTheConversion() {
    let got = Self.itn.normalize("it covers two \u{0301} square miles", spokenPunctuation: false)
    #expect(got.contains("2"))
    #expect(!got.contains("two"))
  }

  // MARK: - The oracle's own rows, re-run with a long tail

  /// A prefix invariant proves the window did not change the decision; these pin what that
  /// decision IS, so a window failure cannot hide behind two identically-wrong outputs. Every
  /// pair here is a row of `parity.jsonl` (the Python oracle's baked output).
  @Test(
    "oracle rows still convert correctly with a long tail attached",
    arguments: [
      ("two miles per hour", "2 miles per hour"),
      ("she is five years old", "she is 5 years old"),
      ("two square miles", "2 square miles"),
      ("a five-year-old boy", "a 5-year-old boy"),
      ("a five-foot-tall person", "a 5-foot-tall person"),
      ("the Forty Niners won", "the Forty Niners won"),
      ("go one by one", "go one by one"),
      ("a thousandth of a second", "a thousandth of a second"),
      (
        "between one hundred and five and one hundred and ten",
        "between one hundred and five and one hundred and ten"
      ),
    ] as [(input: String, expected: String)])
  func oracleRowsWithALongTail(input: String, expected: String) {
    #expect(Self.itn.normalize(input, spokenPunctuation: true) == expected)
    #expect(
      Self.itn.normalize(input + inertTail, spokenPunctuation: true)
        == expected + inertTail)
  }
}
