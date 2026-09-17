import Foundation
import Testing

@testable import EnviousWisprCore

/// #3018 — the fill-in grammar: `{{date}}`, `{{time}}`, `{{clipboard}}`.
///
/// `.productOutcome`: when this fails the user sees `{{date}}` pasted into their email, or
/// yesterday's date, or somebody else's clipboard text where their own belonged.
@Suite("Snippet fill-ins (#3018)", .tags(.productOutcome))
struct SnippetPlaceholderTests {

  /// 2026-09-16T18:45:00Z, written as its epoch so no formatter builds the subject's input.
  private static let instant = Date(timeIntervalSince1970: 1_789_584_300)
  /// 2026-09-17T00:00:00Z — midnight UTC, which is still the 16th in New York.
  private static let midnightUTC = Date(timeIntervalSince1970: 1_789_603_200)

  private static let newYork = TimeZone(identifier: "America/New_York")!
  private static let utc = TimeZone(identifier: "UTC")!

  private static let corpusSavedTexts: [String] = [
    "sam@example.com",
    "see {{clipboard}}",
    "{{clipboard}}",
    "{{date}}{{time}}",
    "EWS{{clipboard}}",
    "{{clipboard}}NIP",
    "E{{clipboard}}S{{clipboard}}NIP",
    "a{{clipboard}}b{{clipboard}}c",
    "{{cursor}} {{clipboard}}",
    "caf\u{e9}{{clipboard}}",
    "e{{clipboard}}",
    "EWS",
    "NIP",
  ]
  private static let corpusClipboards: [String?] = [
    nil, "", "W", "NIP", "NIPx", "EWSNIPinside", "EWSNIPfallback0", "abc", "\u{301}fter",
    String(repeating: "z", count: 300) + "EWSNIPinside",
  ]
  private static let corpusNeedles: [String] = [
    "EWSNIP", "EWSNIPinside", "EWSNIPfallback0", "EWSNIPfallback1", "EWSWNIP", "EWSNIPx",
    "abc", "caf\u{e9}", "e\u{301}", "Sep 16, 2026", "2:45\u{202F}PM", "{{cursor}}", "",
  ]

  private static func values(
    at now: Date = instant,
    locale: String = "en_US",
    zone: TimeZone = newYork,
    clipboard: String? = nil
  ) -> SnippetDynamicValues {
    SnippetDynamicValues(
      now: now, locale: Locale(identifier: locale), timeZone: zone, clipboard: clipboard)
  }

  // MARK: - The rendered values

  /// The literals were MEASURED on this machine before the resolver was written, by running
  /// `Date.FormatStyle` against these exact inputs in a scratch program, and they are written out
  /// here as text. No formatter is built inside this test: an expectation built with the mechanism
  /// under test cannot fail.
  ///
  /// **The `en_US` time separator is U+202F, a NARROW NO-BREAK SPACE, not a plain space.** Read off
  /// the bytes (`e2 80 af`) rather than off the screen, where the two look identical. Anything that
  /// searches the delivered text for `2:45 PM` with an ordinary space will not find it.
  @Test(
    "The date and the time read as each locale's own user expects",
    arguments: [
      ("en_US", "Sep 16, 2026", "2:45\u{202F}PM"),
      ("en_GB", "16 Sep 2026", "14:45"),
      ("de_DE", "16. Sept. 2026", "14:45"),
    ])
  func rendersPerLocale(locale: String, expectedDate: String, expectedTime: String) {
    let values = Self.values(locale: locale)
    #expect(SnippetPlaceholder.resolve("{{date}}", using: values) == expectedDate)
    #expect(SnippetPlaceholder.resolve("{{time}}", using: values) == expectedTime)
  }

  /// One instant, two zones, two different DATES. A resolver that ignored `timeZone` passes a
  /// before-and-after-midnight pair — measured, both read `Sep 16, 2026` in New York — so that
  /// pair cannot be the control and this one is.
  @Test("The same instant is a different day in two zones")
  func theZoneDecidesTheDay() {
    #expect(
      SnippetPlaceholder.resolve("{{date}}", using: Self.values(at: Self.midnightUTC))
        == "Sep 16, 2026")
    #expect(
      SnippetPlaceholder.resolve(
        "{{date}}", using: Self.values(at: Self.midnightUTC, zone: Self.utc)) == "Sep 17, 2026")
  }

  @Test("A clipboard that was not read, and an empty one, both resolve to nothing")
  func clipboardAbsentOrEmpty() {
    #expect(SnippetPlaceholder.resolve("[{{clipboard}}]", using: Self.values()) == "[]")
    #expect(
      SnippetPlaceholder.resolve("[{{clipboard}}]", using: Self.values(clipboard: "")) == "[]")
    #expect(
      SnippetPlaceholder.resolve("[{{clipboard}}]", using: Self.values(clipboard: "https://x.dev"))
        == "[https://x.dev]")
  }

  /// The one a second pass would get wrong. Whatever the user copied is CONTENT, never grammar.
  @Test("A fill-in inside the clipboard text is pasted, not resolved")
  func aSubstitutedValueIsNeverRescanned() {
    let resolved = SnippetPlaceholder.resolve(
      "{{clipboard}}", using: Self.values(clipboard: "{{date}} and {{clipboard}}"))
    #expect(resolved == "{{date}} and {{clipboard}}")
  }

  // MARK: - Case and padding

  @Test(
    "A supported name matches whatever case and padding it is written in",
    arguments: [
      "{{date}}", "{{DATE}}", "{{Date}}", "{{dAtE}}", "{{ date }}", "{{\tdate\t}}", "{{\ndate\n}}",
    ])
  func caseAndPaddingDoNotMatter(spelling: String) {
    #expect(SnippetPlaceholder.resolve(spelling, using: Self.values()) == "Sep 16, 2026")
    #expect(SnippetPlaceholder.placeholders(in: spelling) == [.date])
    #expect(SnippetPlaceholder.carriesUnsupportedPlaceholder(spelling) == false)
  }

  @Test("placeholders reports the fill-ins used, and only those")
  func placeholdersReportsWhatIsUsed() {
    #expect(SnippetPlaceholder.placeholders(in: "{{clipboard}}") == [.clipboard])
    #expect(SnippetPlaceholder.placeholders(in: "{{CLIPBOARD}}") == [.clipboard])
    #expect(SnippetPlaceholder.placeholders(in: "{{clip}}").isEmpty)
    #expect(SnippetPlaceholder.placeholders(in: "no braces here").isEmpty)
    #expect(
      SnippetPlaceholder.placeholders(in: "{{date}} {{time}} {{date}}") == [.date, .time])
  }

  @Test("Every case's canonical token round-trips through the scanner")
  func everyTokenIsItsOwnSpelling() {
    for placeholder in SnippetPlaceholder.allCases {
      #expect(SnippetPlaceholder.placeholders(in: placeholder.token) == [placeholder])
      #expect(SnippetPlaceholder.carriesUnsupportedPlaceholder(placeholder.token) == false)
    }
    #expect(SnippetPlaceholder.allCases.count == 3, "a fourth fill-in needs its own decision table")
  }

  // MARK: - The span decision table

  /// One row per input CLASS, and the table is the same one the plan and the PR carry. `resolved`
  /// is what the user gets; `unsupported` is the import's answer.
  @Test(
    "The span table decides every class of input",
    arguments: [
      // (input, resolved, unsupported)
      ("{{date}}", "Sep 16, 2026", false),
      ("{{TIME}}", "2:45\u{202F}PM", false),
      ("{{ clipboard }}", "copied", false),
      ("{{cursor}}", "{{cursor}}", true),
      ("{{}}", "{{}}", true),
      ("{{date time}}", "{{date time}}", true),
      ("plain text", "plain text", false),
      ("a {{ b", "a {{ b", false),
      ("}} then {{", "}} then {{", false),
      ("{{date}} {{time}}", "Sep 16, 2026 2:45\u{202F}PM", false),
      ("{{date}} {{cursor}}", "Sep 16, 2026 {{cursor}}", true),
      ("{{{{date}}}}", "{{{{date}}}}", true),
      ("Hi {{date}}, from {{clipboard}}.", "Hi Sep 16, 2026, from copied.", false),
    ])
  func spanTable(input: String, resolved: String, unsupported: Bool) {
    let values = Self.values(clipboard: "copied")
    #expect(SnippetPlaceholder.resolve(input, using: values) == resolved)
    #expect(SnippetPlaceholder.carriesUnsupportedPlaceholder(input) == unsupported)
  }

  /// The doubled-brace reading, stated rather than implied: ONE unsupported span `{{{{date}}`
  /// whose inner text is `{{date`, then the literal `}}`. The row above asserts the bytes come
  /// back unchanged; this asserts WHY, so a future scanner that split it differently and happened
  /// to rebuild the same string is still caught.
  @Test("Doubled braces are one unsupported span followed by a literal closer")
  func doubledBracesReading() {
    #expect(SnippetPlaceholder.placeholders(in: "{{{{date}}}}").isEmpty)
    #expect(SnippetPlaceholder.carriesUnsupportedPlaceholder("{{{{date}}}}"))
    // The inner `{{date` is not a name, so nothing is filled in, and the trailing `}}` is text.
    #expect(SnippetPlaceholder.resolve("{{{{date}}}}", using: Self.values()) == "{{{{date}}}}")
  }

  @Test("Text with no fill-in comes back byte for byte")
  func untouchedTextSurvives() {
    let saved = """
      Dear {name},
      \tThe path is C:\\Users\\{{  }}\\x — see attached.

      Regards
      """
    #expect(SnippetPlaceholder.resolve(saved, using: Self.values(clipboard: "x")) == saved)
  }

  // MARK: - The collision domain answers what the resolved strings would

  /// `SnippetResolvedExpansions` exists so a large clipboard is not copied once per saved snippet.
  /// Its contract is ONE-WAY — it never misses an occurrence, and may report one the resolved
  /// string does not have — so the oracle here is the real `resolve` and the assertion is the
  /// implication, not equality. The corpus is a cross product rather than a list of remembered
  /// bugs.
  ///
  /// The over-report is also counted, and asserted to happen only where two segments MERGE at their
  /// splice. `café` followed by a combining acute is the case that found this: the resolved text no
  /// longer contains `café`, and a segment searched on its own still does. Rejecting one extra
  /// random sentinel costs nothing; missing one would put a live sentinel into delivered text.
  ///
  /// The axes are the ones a segment search can get wrong: a match inside one segment, across a
  /// literal/value splice, across a value/value splice, across several SHORT segments, an empty
  /// substitution, an unsupported span carried as a literal, a grapheme that merges at a splice,
  /// a repeated value, a near miss that shares the prefix, and a fallback candidate. The last row
  /// of the corpus is two SEPARATE expansions that would spell the needle if joined, which must
  /// stay false.
  @Test("The segment domain never misses what the resolved strings hold")
  func segmentDomainAgreesWithResolvedStrings() {

    var overReports: [String] = []

    for clipboard in Self.corpusClipboards {
      let values = Self.values(clipboard: clipboard)
      let resolved = Self.corpusSavedTexts.map { SnippetPlaceholder.resolve($0, using: values) }
      let whole = SnippetResolvedExpansions(savedTexts: Self.corpusSavedTexts, using: values)

      for needle in Self.corpusNeedles {
        let expected = resolved.contains { $0.contains(needle) }
        if expected {
          #expect(
            whole.contains(needle),
            Comment(
              rawValue:
                "MISSED: whole domain, needle [\(needle)], clipboard [\(clipboard ?? "nil")]"
            ))
        }

        // One expansion at a time as well: a whole-array answer can be right for the wrong reason.
        for (saved, text) in zip(Self.corpusSavedTexts, resolved) {
          let single = SnippetResolvedExpansions(savedTexts: [saved], using: values)
          let reported = single.contains(needle)
          if text.contains(needle) {
            #expect(
              reported,
              Comment(
                rawValue:
                  "MISSED: [\(saved)], needle [\(needle)], clipboard [\(clipboard ?? "nil")]"))
          } else if reported {
            // An over-report is allowed, and only where a splice merges graphemes. Anything else
            // is a real defect, so the allowance is narrow rather than a blanket.
            overReports.append("[\(saved)] / [\(needle)] / [\(clipboard ?? "nil")]")
          }
        }
      }
    }

    // Every over-report in this corpus has the SAME cause: the literal `café` and a clipboard
    // opening with a combining acute merge into one grapheme at their splice, so the resolved text
    // holds neither `café` nor `é` while the literal segment on its own holds both. A row here for
    // any other reason is a new class, which is what this is watching for.
    let expectedOverReports: [String] = [
      "[café{{clipboard}}] / [café] / [́fter]",
      "[café{{clipboard}}] / [é] / [́fter]",
    ]
    #expect(
      overReports == expectedOverReports, Comment(rawValue: overReports.joined(separator: "\n")))
  }

  @Test("A needle is never assembled across two separate expansions")
  func theDomainDoesNotJoinExpansions() {
    let values = Self.values()
    #expect(
      SnippetResolvedExpansions(savedTexts: ["EWS", "NIP"], using: values).contains("EWSNIP")
        == false)
    #expect(SnippetResolvedExpansions(savedTexts: ["EWSNIP"], using: values).contains("EWSNIP"))
  }

  @Test("Segments are the same pieces resolve emits, including an unsupported span")
  func segmentsMatchWhatResolveEmits() {
    let values = Self.values(clipboard: "COPIED")
    let segments = SnippetPlaceholder.segments(of: "a{{clipboard}}b{{cursor}}c", using: values)
    #expect(
      segments == [
        .literal("a"), .value(.clipboard, "COPIED"), .literal("b"), .literal("{{cursor}}"),
        .literal("c"),
      ])
    // Joining the segments reproduces `resolve` byte for byte, which is the invariant the search
    // rests on.
    let joined = segments.map { segment -> String in
      switch segment {
      case .literal(let text): return text
      case .value(_, let text): return text
      }
    }.joined()
    #expect(joined == SnippetPlaceholder.resolve("a{{clipboard}}b{{cursor}}c", using: values))
  }

  /// A non-ASCII character can canonically EQUAL an ASCII one, so a raw byte search would miss it
  /// and the domain would hand back a sentinel that is already in the delivered text. Executed
  /// rather than reasoned about: all three of these match today.
  @Test(
    "A character that canonically equals an ASCII one still collides",
    arguments: [("\u{212A}", "K"), ("\u{037E}", ";"), ("\u{1FEF}", "`")])
  func canonicalEquivalentsOfASCIIAreNotMissed(source: String, needle: String) {
    // The premise first: if this stops being true the case below proves nothing.
    #expect(source.contains(needle), "the premise of this case no longer holds")

    var clipboard = "before " + source + " after"
    clipboard.makeContiguousUTF8()
    let domain = SnippetResolvedExpansions(
      savedTexts: ["{{clipboard}}"], using: Self.values(clipboard: clipboard))
    #expect(domain.contains(needle))
  }

  /// The other half: an ALL-ASCII haystack is where the byte search is trusted to say no, so a
  /// needle that is genuinely absent must come back absent rather than over-reported into a retry
  /// loop.
  @Test("An all-ASCII haystack answers absent needles exactly")
  func anASCIIHaystackAnswersExactly() {
    let domain = SnippetResolvedExpansions(
      savedTexts: ["see {{clipboard}} please"],
      using: Self.values(clipboard: "plain ascii clipboard text"))
    #expect(domain.contains("clipboard text"))
    #expect(domain.contains("EWSNIPabc") == false)
    #expect(domain.contains("zzz") == false)
  }
}
