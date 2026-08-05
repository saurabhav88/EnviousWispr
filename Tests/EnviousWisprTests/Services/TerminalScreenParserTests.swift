import Foundation
import Testing

@testable import EnviousWisprServices

/// Gate 2: locating the input line on a terminal's rendered screen.
///
/// Every layout here mirrors a real one observed in Ghostty, and every refusal
/// freezes a failure that actually happened — the prototype's empty-box read, the
/// status-bar anchor, and both live spoofs.
@Suite("Terminal screen parser")
struct TerminalScreenParserTests {

  // MARK: - Layout builders

  /// Claude Code: light box rules with `❯` inside, hints printed BELOW.
  private static func claudeBox(_ input: String, footer: String = "  ? for shortcuts") -> String {
    """
    some earlier output
    \u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}
    \u{276F} \(input)
    \u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}
    \(footer)
    """
  }

  /// Claude Code with its session title drawn INTO the top rule.
  ///
  /// The default title row is the real one, copied byte-for-byte from frame
  /// 2419 of the 2026-08-04 capture of the founder's own 67-column window: a
  /// 36-glyph leading run, the space-padded title, then exactly 2 glyphs. The
  /// closing rule stays plain, which is what the same capture shows — opening
  /// titled 15 frames, closing titled 0.
  ///
  /// The closing rule is derived from the title row's width rather than
  /// hard-coded, because the first draft drew a 67-wide top over an 8-wide
  /// bottom and no real box looks like that — measured across all 4,397 frames
  /// the two rules match in 4,397 and differ in 0. The PARSER does not require
  /// it (a width check was tried and removed: `String.count` is not terminal
  /// columns, so it refused a square box with a CJK title). The fixture stays
  /// faithful anyway, because a fixture looser than production hides exactly the
  /// defect it exists to catch.
  private static func claudeTitledBox(
    _ input: String,
    title: String = "\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}"
      + "\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}"
      + "\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}"
      + "\u{2500}\u{2500}\u{2500}\u{2500}\u{2500} ollama-build-order-decision \u{2500}\u{2500}",
    footer: String = "  ? for shortcuts"
  ) -> String {
    """
    some earlier output
    \(title)
    \u{276F} \(input)
    \(String(repeating: "\u{2500}", count: title.count))
    \(footer)
    """
  }

  /// A screen whose opening row is `opening` and whose CLOSING rule is the same
  /// width, so the only thing a test varies is the opening's own shape.
  ///
  /// Every negative below needs this. While a width invariant was briefly in the
  /// parser, a fixture with a 34-wide opening over a 40-wide closing refused for
  /// the WIDTH — not for the centred title, the mixed glyph, or whatever the
  /// test was named after — and would have gone on passing while testing
  /// nothing. The invariant is gone, but the lesson is not: an acceptance check
  /// must be able to reach its own subject, so widths stay matched here.
  private static func boxWithOpening(
    _ opening: String, input: String = "rendered output", marker: Character = "\u{276F}",
    closingGlyph: Character = "\u{2500}"
  ) -> String {
    """
    earlier output
    \(opening)
    \(marker) \(input)
    \(String(repeating: String(closingGlyph), count: opening.count))
    """
  }

  /// Gemini: half-block rules with a plain `>` inside.
  private static func geminiBox(_ input: String) -> String {
    """
    earlier output
    \u{2584}\u{2584}\u{2584}\u{2584}\u{2584}\u{2584}\u{2584}\u{2584}
    > \(input)
    \u{2580}\u{2580}\u{2580}\u{2580}\u{2580}\u{2580}\u{2580}\u{2580}
    """
  }

  /// Codex: no box at all, status bar below the input.
  private static func codexScreen(
    _ input: String, status: String = "  weekly 63% left"
  ) -> String {
    """
    earlier output
    \u{203A} \(input)
    \(status)
    """
  }

  // MARK: - Wrapped layouts, MEASURED rather than invented
  //
  // Captured from live CLIs in a 67-column terminal on 2026-08-04. The gutter is
  // the width of the marker prefix and differs per tool — 2 cells for Claude
  // Code's `❯` plus its non-breaking space, 3 for Gemini's leading space, `>`
  // and space, 2 for Codex's `› `. The previous wrapped fixture used an
  // UNINDENTED continuation row, which no real CLI draws, so it could not have
  // caught a gutter mistake either way.

  /// Claude Code with the input wrapped across `rows`, the first carrying the
  /// marker and the rest the 2-cell gutter.
  private static func claudeWrapped(_ rows: [String], trailingBlank: Bool = false) -> String {
    let rule = String(repeating: "\u{2500}", count: 8)
    var body = rows.enumerated().map { index, text in
      index == 0 ? "\u{276F}\u{00A0}\(text)" : "  \(text)"
    }
    if trailingBlank { body.append("") }
    return (["some earlier output", rule] + body + [rule, "  ? for shortcuts"])
      .joined(separator: "\n")
  }

  /// Gemini with the input wrapped, whose gutter is 3 cells wide.
  private static func geminiWrapped(_ rows: [String]) -> String {
    let top = String(repeating: "\u{2584}", count: 8)
    let bottom = String(repeating: "\u{2580}", count: 8)
    let body = rows.enumerated().map { index, text in
      index == 0 ? " > \(text)" : "   \(text)"
    }
    return (["earlier output", top] + body + [bottom]).joined(separator: "\n")
  }

  /// Codex with the input wrapped: marker row, gutter-indented continuation
  /// rows, ONE blank row, then the status bar.
  private static func codexWrapped(
    _ rows: [String], status: [String] = ["  tab to queue message      100% context left"]
  ) -> String {
    let body = rows.enumerated().map { index, text in
      index == 0 ? "\u{203A} \(text)" : "  \(text)"
    }
    return (["earlier output"] + body + [""] + status).joined(separator: "\n")
  }

  // MARK: - The three tools

  @Test("Claude Code's boxed input line is found, and the footer below it is not")
  func findsClaudeCodeInput() {
    let located = TerminalScreenParser.locate(inScreenTail: Self.claudeBox("git commit -m fix the"))
    #expect(located?.cli == .claudeCode)
    #expect(located?.inputLine == "git commit -m fix the")
  }

  @Test("Gemini's block-ruled box is found and its plain marker is stripped")
  func findsGeminiInput() {
    let located = TerminalScreenParser.locate(inScreenTail: Self.geminiBox("explain this to me"))
    #expect(located?.cli == .geminiCLI)
    #expect(located?.inputLine == "explain this to me")
  }

  @Test("Codex is found from its opening marker, never from its status bar")
  func findsCodexInput() {
    // MEASURED failure this freezes: "take the last non-empty row" returned
    // `weekly 63% left` from Codex's status bar. Codex draws no box, so the box
    // search cannot find it either.
    let located = TerminalScreenParser.locate(
      inScreenTail: Self.codexScreen("refactor the handler"))
    #expect(located?.cli == .codex)
    #expect(located?.inputLine == "refactor the handler")
  }

  // MARK: - Refusals that are the feature

  // MARK: - Wrapping

  @Test("A WRAPPED box is read from its LAST row, never rejoined")
  func wrappedBoxReadsItsLastRow() {
    // This used to refuse, and that refusal made the feature unavailable for
    // most real dictations: a 67-column terminal wraps at 63 characters, so two
    // sentences do not fit. 8 of the 9 field refusals where the founder had
    // actually typed something were this guard (#1926).
    //
    // Rejoining is still impossible and still not attempted. MEASURED:
    // `"A"x63 + " next word"` and `"A"x64 + " next word"` render byte-identical
    // screens, so no join rule can recover which was typed. The LAST row needs
    // no join — it is the verbatim tail, confirmed at every typed length from
    // 40 to 260 characters.
    let located = TerminalScreenParser.locate(
      inScreenTail: Self.claudeWrapped([
        "I want to test if this works as intended and works properly.",
        "Now I dictate",
      ]))
    #expect(located?.cli == .claudeCode)
    #expect(located?.inputLine == "Now I dictate")
    #expect(located?.leftWasCut == true, "a wrapped tail has text hidden above it")
  }

  @Test("An UNWRAPPED box still reads its only row, and reports nothing was cut")
  func unwrappedBoxIsNotMarkedAsCut() {
    // The two-way control. Without it the assertion above passes for a parser
    // that marked EVERY line as cut, which would refuse seam de-duplication on
    // every short field in every terminal.
    let located = TerminalScreenParser.locate(inScreenTail: Self.claudeBox("git commit -m fix the"))
    #expect(located?.inputLine == "git commit -m fix the")
    #expect(located?.leftWasCut == false)
  }

  @Test("The gutter is the MARKER's width, so Gemini's 3-cell indent survives")
  func geminiWrappedKeepsItsOwnGutter() {
    // Claude Code indents continuation rows by 2 and Gemini by 3, because their
    // markers are different widths. A hardcoded 2 would leave a stray space on
    // every wrapped Gemini line.
    let located = TerminalScreenParser.locate(
      inScreenTail: Self.geminiWrapped(["explain this to me in a lot", "more detail please"]))
    #expect(located?.cli == .geminiCLI)
    #expect(located?.inputLine == "more detail please")
    #expect(located?.leftWasCut == true)
  }

  @Test("A wrapped Codex input reads its last row, not the row before the wrap")
  func codexWrappedReadsItsLastRow() {
    // The Codex path did NOT refuse a one-row wrap: its status bar allowance is
    // two populated rows, and one continuation plus one status row is exactly
    // two. So it passed and returned the MARKER row — the text from BEFORE the
    // wrap — and the repair acted on stale context with nothing logged. A
    // silent wrong answer, worse than the boxed refusal it sat beside.
    let located = TerminalScreenParser.locate(
      inScreenTail: Self.codexWrapped([
        "refactor the handler so it stops swallowing the error",
        "and then run the tests",
      ]))
    #expect(located?.cli == .codex)
    #expect(located?.inputLine == "and then run the tests")
    #expect(located?.leftWasCut == true)
  }

  @Test("A three-row Codex wrap is read too, not refused for having rows below")
  func codexDeepWrapIsRead() {
    let located = TerminalScreenParser.locate(
      inScreenTail: Self.codexWrapped(["first visual row", "second visual row", "third row"]))
    #expect(located?.inputLine == "third row")
  }

  @Test("A Codex continuation row starting with a shell glyph is not a live prompt")
  func codexWrapContainingAPromptGlyphIsStillInput() {
    // The staleness scan used to start at the MARKER row, so any row of the
    // user's own wrapped text beginning `$`, `%`, `#` or `❯` read as a live
    // shell prompt and refused. It now starts after the input block.
    let located = TerminalScreenParser.locate(
      inScreenTail: Self.codexWrapped([
        "run this for me and explain what it does:",
        "$ git rebase --onto main feature",
      ]))
    #expect(located?.inputLine == "$ git rebase --onto main feature")
  }

  @Test("Codex refuses when the caret sits on a new empty line of its own")
  func codexTrailingBlankRowRefuses() {
    // MEASURED at 67 columns: caret at the END of the input draws ONE blank row
    // before the status bar, wrapped or not; a newline (Ctrl+J) draws TWO. The
    // second blank IS the caret's line, so the last populated row is not where
    // the next word goes and lowering against it continues a sentence the user
    // deliberately ended. Found by whole-diff review, which spotted that the
    // boxed path already refused this and Codex read straight past it.
    let wrappedThenNewline = """
      earlier output
      \u{203A} a short line and now a much longer continuation that certainly
        wraps past the edge of this window


        gpt-5.6-sol high \u{00B7} /tmp \u{00B7} Ready
      """
    #expect(TerminalScreenParser.locate(inScreenTail: wrappedThenNewline) == nil)
    if case .refused(let detail) = TerminalScreenParser.locateDetailed(
      inScreenTail: wrappedThenNewline)
    {
      #expect(detail.codex == .ambiguousTrailingBlankRow)
    } else {
      Issue.record("a caret on its own blank line must refuse")
    }

    // Two-way control, and it is the SAME screen with ONE blank row instead of
    // two. Without it this passes for a parser that refuses every Codex wrap.
    let wrappedCaretAtEnd = """
      earlier output
      \u{203A} a short line and now a much longer continuation that certainly
        wraps past the edge of this window

        gpt-5.6-sol high \u{00B7} /tmp \u{00B7} Ready
      """
    #expect(
      TerminalScreenParser.locate(inScreenTail: wrappedCaretAtEnd)?.inputLine
        == "wraps past the edge of this window")
  }

  @Test("Every shape a Codex input block can take is read from its LAST row")
  func codexInputBlockShapes() {
    // The CLASS, enumerated. Two review rounds found the same defect scanning
    // DOWNWARD from the marker — first the status bar absorbed as continuation
    // text, then a row the user had indented ending the block early — so every
    // member is frozen here rather than the one that was reported.
    func line(_ tail: String) -> String? {
      TerminalScreenParser.locate(inScreenTail: tail)?.inputLine
    }
    let status = "  gpt-5.6-sol high \u{00B7} /tmp \u{00B7} Ready"

    // A wrap continuation sits exactly at the gutter.
    #expect(
      line(
        """
        earlier output
        \u{203A} first visual row of the prompt
          second visual row

        \(status)
        """) == "second visual row")

    // A hard-newline row the user indented FURTHER sits past the gutter. This
    // is review r2's P1: requiring equality ended the block at the marker row,
    // so the parser read the row ABOVE the caret and reported it as unwrapped —
    // which also let the seam rule delete a dictated word.
    #expect(
      line(
        """
        earlier output
        \u{203A} first line of my prompt
              an indented second line

        \(status)
        """) == "an indented second line")

    // A blank line inside the user's OWN prompt is not the separator.
    #expect(
      line(
        """
        earlier output
        \u{203A} first line

          third line after a blank one

        \(status)
        """) == "third line after a blank one")

    // Trailing blank rows below the status bar do not move the separator.
    #expect(
      line(
        """
        earlier output
        \u{203A} first visual row of the prompt
          second visual row

        \(status)


        """) == "second visual row")

    // Two status rows are still allowed, as they always were.
    #expect(
      line(
        """
        earlier output
        \u{203A} first visual row of the prompt
          second visual row

        \(status)
          tab to queue message
        """) == "second visual row")
  }

  @Test("An UNWRAPPED Codex line with the caret on a new line refuses too")
  func codexUnwrappedTrailingBlankRefuses() {
    // The same shape without a wrap, which the shipped parser also read past —
    // it counted one populated row below the marker, which is inside its limit.
    let shortThenNewline = """
      earlier output
      \u{203A} short text


        gpt-5.6-sol high \u{00B7} /tmp \u{00B7} Ready
      """
    #expect(TerminalScreenParser.locate(inScreenTail: shortThenNewline) == nil)
  }

  @Test("A blank row BELOW the text refuses — two inputs draw it and they disagree")
  func trailingBlankRowRefuses() {
    // MEASURED, and the reason this one case still refuses. `"A"x63 + " "`
    // (text that ended exactly at the wrap) and `"first line" + backslash +
    // Enter` (a deliberate new line) render the SAME two rows. The first wants
    // the sentence continued in lower case; the second wants a capital. The
    // screen cannot tell them apart, so the app declines rather than guessing.
    #expect(
      TerminalScreenParser.locate(
        inScreenTail: Self.claudeWrapped(["first line of text"], trailingBlank: true)) == nil)

    if case .refused(let detail) = TerminalScreenParser.locateDetailed(
      inScreenTail: Self.claudeWrapped(["first line of text"], trailingBlank: true))
    {
      #expect(detail.boxed.telemetryName == "boxed:ambiguous_trailing_blank_row")
    } else {
      Issue.record("a trailing blank row must refuse")
    }
  }

  @Test("An untouched box still says EMPTY even when the box is drawn taller")
  func emptyBoxOutranksTheTrailingBlankRule() {
    // Order matters: an empty box drawn with spare height has a blank row below
    // its marker row too, and it means "nothing typed", not "ambiguous".
    let taller = """
      \u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}
      \u{276F}\u{00A0}

      \u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}
      """
    if case .refused(let detail) = TerminalScreenParser.locateDetailed(inScreenTail: taller) {
      #expect(detail.boxed.telemetryName == "boxed:empty_input")
    } else {
      Issue.record("an untouched box must refuse as empty")
    }
  }

  @Test("#1921 diagnosis: refusals name WHICH guard fired, on both routes")
  func refusalsAreDistinguishable() {
    // Every one of the ten guards reported the same word, which is why a live
    // failure on 2026-08-04 could not be diagnosed at all: three hypotheses were
    // tested by hand against the founder's machine and all three were wrong.
    //
    // Both routes are recorded deliberately. Every normal Claude Code screen
    // fails the Codex probe first, so a line carrying only the Codex refusal
    // would read `no_opening_marker` on every single dictation and point the
    // next reader at the wrong layout entirely.
    func refusal(_ tail: String) -> TerminalScreenParser.Refusal? {
      if case .refused(let detail) = TerminalScreenParser.locateDetailed(inScreenTail: tail) {
        return detail
      }
      return nil
    }

    // A trailing blank row is the one wrap shape that still refuses, and it must
    // be nameable. The row-count refusal it replaced fired on ORDINARY wraps,
    // which are now read (#1926).
    let ambiguous = Self.claudeWrapped(["first line of text"], trailingBlank: true)
    let ambiguousRefusal = refusal(ambiguous)
    #expect(
      ambiguousRefusal?.boxed.telemetryName == "boxed:ambiguous_trailing_blank_row",
      "the one unreadable wrap shape must name itself")

    // The distinction that matters most: an EMPTY box and an unreadable one
    // meant the same word before the diagnostic existed, and they mean opposite
    // things — nothing typed yet, versus typed but unreadable.
    //
    // Corrected by this test failing: an empty box reports `empty_input`, not a
    // zero row count, because the marker row `\u{276F} ` is not blank and so
    // survives the body-count guard to be rejected later for having no text. I
    // expected the row count; the code was right and the assumption was mine.
    let emptyRefusal = refusal(Self.claudeBox(""))
    #expect(
      emptyRefusal?.boxed.telemetryName == "boxed:empty_input",
      "an empty box must be distinguishable from an unreadable one")

    // And the Codex probe is reported even when the boxed route is the one that
    // decided, because that is the pair the log has to carry.
    #expect(ambiguousRefusal?.codex == .noOpeningMarker)

    // Two-way control: a screen the parser ACCEPTS must not produce a refusal at
    // all, or every assertion above passes for the wrong reason.
    #expect(
      refusal(Self.claudeBox("fix the")) == nil,
      "a locatable box must not be reported as refused")
  }

  @Test("An EMPTY box refuses, never reading back the hints printed below it")
  func emptyBoxRefuses() {
    // The prototype's exact failure: an untouched box read back as
    // "/rc ⧉ seam-join-explainer". Joining onto that deletes words nobody typed.
    #expect(TerminalScreenParser.locate(inScreenTail: Self.claudeBox("")) == nil)
    #expect(TerminalScreenParser.locate(inScreenTail: Self.geminiBox("")) == nil)
  }

  @Test("A bare shell prompt refuses — it is deliberately unsupported")
  func bareShellRefuses() {
    // Founder 2026-07-27: prompts are user-customisable, so there is no set to
    // enumerate. The superseded design DID read this shape; V3 must not.
    let bare = """
      total 24
      drwxr-xr-x  5 user  staff  160 Jul 26 09:00 .
      \u{276F} git commit -m fix the
      """
    #expect(TerminalScreenParser.locate(inScreenTail: bare) == nil)
  }

  @Test("A box left in scrollback refuses once a live prompt sits below it")
  func staleBoxBelowALivePromptRefuses() {
    // The user ran a full-screen tool, quit it, and is now at a shell. The box
    // is history; anchoring on it would join onto text from minutes ago.
    let stale = """
      \u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}
      \u{276F} old input from earlier
      \u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}
      \u{276F} git commit -m fix the
      """
    #expect(TerminalScreenParser.locate(inScreenTail: stale) == nil)
  }

  @Test("A row that merely CONTAINS a marker is not an input row")
  func markerMustOpenTheRow() {
    // A live footer reading `Press › to continue` is not input. Requiring the
    // marker to START the row is what separates them.
    let footer = """
      earlier output
      Press \u{203A} to continue
      """
    #expect(TerminalScreenParser.locate(inScreenTail: footer) == nil)
  }

  @Test(
    "Weak markers never locate input",
    arguments: [
      "$ echo hello", "% echo hello", "# echo hello", "81% | $107.40", "> quoted mail line",
    ])
  func weakMarkersRefuse(row: String) {
    // `$` is also a dollar amount and `%` a percentage: Claude Code's own status
    // bar reads `81% | $107.40`, which anchored the prototype on the status bar.
    // A bare `>` is ordinary in mail, diffs and redirection — it is STRIPPED
    // once a box has identified the row, and never SEARCHED for.
    #expect(TerminalScreenParser.locate(inScreenTail: "output\n\(row)") == nil)
  }

  @Test("Mismatched box rules refuse")
  func mismatchedBoxRulesRefuse() {
    // A light rule above and a block rule below is not a box either tool draws.
    let mixed = """
      \u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}
      \u{276F} some text
      \u{2580}\u{2580}\u{2580}\u{2580}\u{2580}\u{2580}\u{2580}\u{2580}
      """
    #expect(TerminalScreenParser.locate(inScreenTail: mixed) == nil)
  }

  @Test("A short run of dashes is not a box rule")
  func shortDashRunIsNotABoundary() {
    let prose = """
      \u{2500}\u{2500}
      \u{276F} some text
      \u{2500}\u{2500}
      """
    #expect(TerminalScreenParser.locate(inScreenTail: prose) == nil)
  }

  @Test("An unrecognised screen refuses")
  func unrecognisedScreenRefuses() {
    #expect(TerminalScreenParser.locate(inScreenTail: "") == nil)
    #expect(TerminalScreenParser.locate(inScreenTail: "just some output\nand more") == nil)
  }

  // MARK: - #1932: a top rule carrying the session title
  //
  // Claude Code draws the session name into the OPENING rule. `boundaryClass`
  // wanted one repeated glyph, so the row was not a boundary and the whole box
  // was refused as `fewer_than_two_boundaries` — measured at 15 of 4,397 frames
  // captured from the founder's own window, against 43 that located.

  @Test("#1932: a titled top rule is still the top of the box")
  func titledOpeningRuleIsFound() throws {
    let located = try #require(
      TerminalScreenParser.locate(inScreenTail: Self.claudeTitledBox("Hey, so we")))
    #expect(located.cli == .claudeCode)
    #expect(located.inputLine == "Hey, so we")
    #expect(located.leftWasCut == false)
  }

  @Test("#1932: the title's own content is never read, whatever it contains")
  func titledRuleContentIsIrrelevant() throws {
    // The title is Claude Code's AI-generated session name, so it can be any
    // language and any length. Hold the GEOMETRY fixed at the measured
    // right-aligned shape and vary only the text, or the test stops being about
    // content — the first draft varied both and failed on its own short leading
    // runs rather than on anything to do with the characters.
    let lead = String(repeating: "\u{2500}", count: 20)
    let trail = String(repeating: "\u{2500}", count: 2)
    for text in [
      "\u{6E2C}\u{8A66}\u{30BB}\u{30C3}\u{30B7}\u{30E7}\u{30F3}",
      "a",
      "1.2.3 (draft)",
      "\u{0440}\u{0435}\u{0444}\u{0430}\u{043A}\u{0442}\u{043E}\u{0440}\u{0438}\u{043D}\u{0433}",
      "fix: don't drop the user's text",
    ] {
      // Closing rule sized in terminal COLUMNS, not `String.count` — a CJK
      // character occupies two cells. Building it from `title.count` is what
      // hid the width-invariant defect: the fixture reproduced the same wrong
      // count and passed while a real box would have been refused.
      let columns =
        lead.count + trail.count + 2
        + text.unicodeScalars.reduce(0) { $0 + (($1.value >= 0x1100) ? 2 : 1) }
      let screen = """
        some earlier output
        \(lead) \(text) \(trail)
        \u{276F} carry on
        \(String(repeating: "\u{2500}", count: columns))
          ? for shortcuts
        """
      let located = try #require(
        TerminalScreenParser.locate(inScreenTail: screen), "title \(text) should still locate")
      #expect(located.inputLine == "carry on")
    }
  }

  @Test("#1932: a titled rule composes with a WRAPPED input, still reading the tail")
  func titledRuleAroundWrappedInput() throws {
    let titled =
      String(repeating: "\u{2500}", count: 20) + " ollama-build-order-decision "
      + String(repeating: "\u{2500}", count: 2)
    // Same width as the opening, because that is what a box is.
    let rule = String(repeating: "\u{2500}", count: titled.count)
    let screen = """
      earlier output
      \(titled)
      \u{276F}\u{00A0}the first row of what was typed
      \u{00A0}\u{00A0}and the tail after it wrapped
      \(rule)
      """
    let located = try #require(TerminalScreenParser.locate(inScreenTail: screen))
    #expect(located.inputLine == "and the tail after it wrapped")
    #expect(located.leftWasCut, "a wrapped titled box must still report the cut")
  }

  // The adversarial negatives. Each is a DIFFERENT way the shape could
  // over-match, not three phrasings of one way.

  @Test("#1932: the CLOSING rule may not be titled")
  func titledClosingRuleRefuses() {
    let titled =
      String(repeating: "\u{2500}", count: 20) + " not a bottom border "
      + String(repeating: "\u{2500}", count: 2)
    let screen = """
      \(String(repeating: "\u{2500}", count: 8))
      \u{276F} some text
      \(titled)
      """
    #expect(TerminalScreenParser.locate(inScreenTail: screen) == nil)
  }

  @Test("#1932: a rule broken by text TWICE is decoration, not a border")
  func glyphReappearingInTheMiddleRefuses() {
    // `──── a ──── b ────` is a divider row some tools print. The middle
    // containing the glyph is exactly what separates it from a titled border.
    let decoration =
      String(repeating: "\u{2500}", count: 6) + " a " + String(repeating: "\u{2500}", count: 6)
      + " b " + String(repeating: "\u{2500}", count: 6)
    #expect(
      TerminalScreenParser.locate(
        inScreenTail: Self.boxWithOpening(decoration, input: "some text")) == nil)
  }

  @Test("#1932: an ASCII markdown rule with a title is not a box rule")
  func asciiRuleWithTitleRefuses() {
    let screen = """
      --- Chapter One ---
      \u{276F} some text
      \(String(repeating: "\u{2500}", count: 8))
      """
    #expect(TerminalScreenParser.locate(inScreenTail: screen) == nil)
  }

  @Test("#1932: a titled rule whose glyph CLASS differs from the closing refuses")
  func titledOpeningOfTheWrongClassRefuses() {
    let titled =
      String(repeating: "\u{2500}", count: 20) + " light on top "
      + String(repeating: "\u{2500}", count: 2)
    #expect(
      TerminalScreenParser.locate(
        inScreenTail: Self.boxWithOpening(titled, input: "some text", closingGlyph: "\u{2580}"))
        == nil)
  }

  @Test("#1932: a titled rule cannot rescue a box whose marker is missing")
  func titledRuleStillRequiresTheMarker() {
    // The measured spoof — a file of box-drawing rows shown in vim or less —
    // carries no marker, and a title must not become a way around that.
    let titled =
      String(repeating: "\u{2500}", count: 20) + " some-file.txt "
      + String(repeating: "\u{2500}", count: 2)
    let screen = """
      \(titled)
      just an ordinary line of a file
      \(String(repeating: "\u{2500}", count: 8))
      """
    #expect(TerminalScreenParser.locate(inScreenTail: screen) == nil)
  }

  @Test("#1932: a titled box left in scrollback still refuses under a live prompt")
  func titledBoxInScrollbackRefuses() {
    let titled =
      String(repeating: "\u{2500}", count: 20) + " old-session "
      + String(repeating: "\u{2500}", count: 2)
    let screen = """
      \(titled)
      \u{276F} something typed a while ago
      \(String(repeating: "\u{2500}", count: 8))
      \u{276F} \u{00A0}
      """
    #expect(TerminalScreenParser.locate(inScreenTail: screen) == nil)
  }

  @Test("#1932: glyph runs separated only by SPACES are not a title")
  func glyphRunsSplitBySpacesRefuse() {
    // `──── ────` has no text between the runs, so it is a broken rule rather
    // than a titled one. Without this the middle-has-no-glyph test alone would
    // accept it.
    let screen = """
      \(String(repeating: "\u{2500}", count: 6))   \(String(repeating: "\u{2500}", count: 6))
      \u{276F} some text
      \(String(repeating: "\u{2500}", count: 8))
      """
    #expect(TerminalScreenParser.locate(inScreenTail: screen) == nil)
  }

  @Test("#1932: a tree-drawing row is not a border even with a box glyph in it")
  func treeRowIsNotABorder() {
    let screen = """
      \u{251C}\u{2500}\u{2500} Sources
      \u{276F} some text
      \(String(repeating: "\u{2500}", count: 8))
      """
    #expect(TerminalScreenParser.locate(inScreenTail: screen) == nil)
  }

  @Test("#1932: a CENTRED titled rule is another tool's output, not our box")
  func centredTitledRuleRefuses() {
    // Python Rich's `Console.rule("Chapter 2")` centres its title, and a program
    // printing a line that happens to open with `❯` between two rules then looks
    // exactly like an input box. Found by coverage review and CONFIRMED by
    // replaying the real parser, which located it and returned the program's
    // output as the user's sentence. Right-alignment is what separates ours.
    let centred =
      String(repeating: "\u{2500}", count: 20) + " Chapter 2 "
      + String(repeating: "\u{2500}", count: 20)
    #expect(
      TerminalScreenParser.locate(
        inScreenTail: Self.boxWithOpening(centred, input: "this is rendered output")) == nil)
  }

  @Test("#1932: a LEFT-aligned titled rule refuses too")
  func leftAlignedTitledRuleRefuses() {
    let leftAligned =
      String(repeating: "\u{2500}", count: 2) + " Chapter 2 "
      + String(repeating: "\u{2500}", count: 30)
    #expect(
      TerminalScreenParser.locate(
        inScreenTail: Self.boxWithOpening(leftAligned, input: "this is rendered output")) == nil)
  }

  @Test("#1932: a titled GEMINI block border refuses — untested is not supported")
  func titledGeminiOpeningRefuses() {
    // Titled openings are light-rule only. Cloud review caught the first cut
    // extending them to Gemini's block rules, which combines the looser border
    // rule with the WEAKER marker — `>` is ordinary in quoted mail, diffs and
    // redirects, which is why this parser refuses to search by it. And there is
    // no evidence for it either way: no Gemini session appears in the 4,397-frame
    // capture. Refusing keeps Gemini exactly as it is today.
    let titled =
      String(repeating: "\u{2584}", count: 20) + " Gemini session "
      + String(repeating: "\u{2584}", count: 2)
    let screen = """
      earlier output
      \(titled)
      > explain this result
      \(String(repeating: "\u{2580}", count: 36))
      """
    #expect(TerminalScreenParser.locate(inScreenTail: screen) == nil)
  }

  @Test("#1932: an ordinary PLAIN Gemini box is untouched by any of this")
  func plainGeminiBoxStillWorks() throws {
    // The two-way control for the refusal above: Gemini must still work exactly
    // as before, or "restrict to light rules" would have broken it outright.
    let located = try #require(
      TerminalScreenParser.locate(inScreenTail: Self.geminiBox("explain this to me")))
    #expect(located.cli == .geminiCLI)
    #expect(located.inputLine == "explain this to me")
    #expect(located.boxOpeningKind == .plain)
  }

  @Test("#1932: a right-heavy rule outside the measured suffix refuses")
  func rightHeavyRuleRefuses() {
    // Grounded review's counterexample, reproduced against the real parser
    // before it was accepted: 24 glyphs, a title, 6 glyphs satisfies a
    // `trailing * 4 <= leading` ratio EXACTLY. Ordinary program output can
    // reproduce any ratio, so the matcher takes only the measured suffix of two.
    let opening =
      String(repeating: "\u{2500}", count: 24) + " report "
      + String(repeating: "\u{2500}", count: 6)
    #expect(
      TerminalScreenParser.locate(
        inScreenTail: Self.boxWithOpening(opening, input: "rendered output")) == nil)
  }

  @Test("#1932: a divider pasted INSIDE the box cannot shadow the real top rule")
  func titledDividerInsideTheBodyRefuses() {
    // Cloud review's finding: a titled row is now a legal opening, so a divider
    // pasted into the user's OWN input was picked ahead of the real top rule.
    // It refuses because the first body row after that divider carries no
    // marker, which is the guard this file already leans on hardest. A width
    // invariant was tried here and REMOVED: `String.count` is not terminal
    // columns, so it rejected a perfectly square box with a CJK title.
    let rule = String(repeating: "\u{2500}", count: 40)
    let screen = """
      earlier output
      \(rule)
      \u{276F} first line the user typed
        \(String(repeating: "\u{2500}", count: 8)) Section \(String(repeating: "\u{2500}", count: 2))
        more typed text
      \(rule)
      """
    #expect(TerminalScreenParser.locate(inScreenTail: screen) == nil)
  }

  @Test("#1932: an UNPADDED title is a program divider, not our border")
  func unpaddedTitleRefuses() {
    // Both measured rows pad the title with a space on each side. A divider
    // printed as `────────Section──` does not, and cloud review caught it being
    // accepted — a program-rendered rule above a `❯` output line then read as
    // the live input. Every side of the padding is covered, not just the one
    // reported, because the previous "enumerated the class" claim missed the
    // middle's BOUNDARIES while covering its contents.
    let cases = [
      String(repeating: "\u{2500}", count: 20) + "Section"
        + String(repeating: "\u{2500}", count: 2),
      String(repeating: "\u{2500}", count: 20) + "Section "
        + String(repeating: "\u{2500}", count: 2),
      String(repeating: "\u{2500}", count: 20) + " Section"
        + String(repeating: "\u{2500}", count: 2),
    ]
    for opening in cases {
      #expect(
        TerminalScreenParser.locate(inScreenTail: Self.boxWithOpening(opening)) == nil,
        "unpadded title must refuse: \(opening)")
    }
  }

  @Test("#1932: any box-drawing character in the title makes it a divider")
  func boxDrawingCharacterInTitleRefuses() {
    // The six glyphs a rule is DRAWN with are not the range a divider may USE.
    // Answering the second question with the first let `──── a ├ b ──` pass,
    // because `├` is box-drawing and in neither set. Local review caught it.
    for interloper in ["\u{251C}", "\u{253C}", "\u{2502}", "\u{2554}", "\u{2591}"] {
      let opening =
        String(repeating: "\u{2500}", count: 24) + " a \(interloper) b "
        + String(repeating: "\u{2500}", count: 2)
      #expect(
        TerminalScreenParser.locate(inScreenTail: Self.boxWithOpening(opening)) == nil,
        "box-drawing \(interloper) in a title must refuse")
    }
  }

  @Test("#1932: the title's padding must be a real space, not any whitespace")
  func exoticWhitespacePaddingRefuses() {
    // Every measured row pads with U+0020. `isWhitespace` also admits tabs and
    // the Unicode spaces, which program output can produce and no Claude Code
    // border does.
    for pad in ["\t", "\u{2003}", "\u{2009}"] {
      let opening =
        String(repeating: "\u{2500}", count: 24) + "\(pad)Section\(pad)"
        + String(repeating: "\u{2500}", count: 2)
      #expect(
        TerminalScreenParser.locate(inScreenTail: Self.boxWithOpening(opening)) == nil,
        "padding \(pad.debugDescription) must refuse")
    }
  }

  @Test("#1932: a titled rule mixing box glyphs is a divider, not a border")
  func mixedGlyphTitledRuleRefuses() {
    // Cloud review's finding, reproduced against the real parser: the middle
    // check was scoped to the LEADING glyph, so a different box glyph inside the
    // title span slipped through and a mixed divider under a `❯` line returned
    // its rendered text as the user's sentence. A plain rule already refuses the
    // mixture `─━═─` deliberately, so admitting it through the title span
    // contradicted the boundary contract.
    //
    // The whole class, not just the reported instance: every box glyph of every
    // class, in either box family, and in either run's neighbourhood.
    let cases = [
      String(repeating: "\u{2500}", count: 24) + " a \u{2501}\u{2501} b "
        + String(repeating: "\u{2500}", count: 2),
      String(repeating: "\u{2500}", count: 24) + " a \u{2550} b "
        + String(repeating: "\u{2500}", count: 2),
      String(repeating: "\u{2500}", count: 24) + " a \u{2584} b "
        + String(repeating: "\u{2500}", count: 2),
      String(repeating: "\u{2584}", count: 24) + " a \u{2580} b "
        + String(repeating: "\u{2584}", count: 2),
    ]
    for opening in cases {
      #expect(
        TerminalScreenParser.locate(inScreenTail: Self.boxWithOpening(opening)) == nil,
        "mixed-glyph divider must refuse: \(opening)")
    }
  }

  @Test("#1932: the opening kind is recorded, so the field can see this path")
  func openingKindIsRecorded() throws {
    let titled = try #require(
      TerminalScreenParser.locate(inScreenTail: Self.claudeTitledBox("Hey, so we")))
    #expect(titled.boxOpeningKind == .titled)

    let plain = try #require(
      TerminalScreenParser.locate(inScreenTail: Self.claudeBox("Hey, so we")))
    #expect(plain.boxOpeningKind == .plain)

    // Codex draws no box at all, so it has no opening kind to report.
    let codex = try #require(
      TerminalScreenParser.locate(inScreenTail: Self.codexScreen("Hey, so we")))
    #expect(codex.boxOpeningKind == nil)
  }

  // MARK: - The two live spoofs

  @Test("A printed prompt glyph in a file does not become an input line")
  func printedPromptSpoofRefuses() {
    // MEASURED live in Ghostty: `echo "❯ this is not a real prompt"` then typing
    // returned the PRINTED line. Gate 2 must not read it; Gate 1 is what refuses
    // the case where nothing supported is running at all.
    let spoof = """
      \u{276F} echo "\u{276F} this is not a real prompt"
      \u{276F} this is not a real prompt
      """
    #expect(TerminalScreenParser.locate(inScreenTail: spoof) == nil)
  }

  @Test("Box-drawn output carrying no tool marker refuses")
  func markerlessBoxDrawingOutputRefuses() {
    // The MEASURED spoof: a file with two box rows shown in vim and in less,
    // which was read as `text between rules`. It carries no marker, and both
    // real input rows always do — so it refuses at no cost.
    //
    // This corrects my own reasoning, not just the code. I had argued that
    // because screen matching is spoofable as a CLASS, refusing a measured
    // INSTANCE was not worth it, and froze the false positive in a test that
    // claimed Gate 2 "cannot tell". Gate 2 cannot defeat a FAITHFUL spoof; it
    // can reject this one.
    let claudeLike = """
      \u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}
      text between rules
      \u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}
      """
    let geminiLike = """
      \u{2584}\u{2584}\u{2584}\u{2584}\u{2584}\u{2584}\u{2584}\u{2584}
      text between rules
      \u{2580}\u{2580}\u{2580}\u{2580}\u{2580}\u{2580}\u{2580}\u{2580}
      """
    #expect(TerminalScreenParser.locate(inScreenTail: claudeLike) == nil)
    #expect(TerminalScreenParser.locate(inScreenTail: geminiLike) == nil)
  }

  @Test("A FAITHFUL spoof still passes — which is why Gate 1 is the authority")
  func faithfulSpoofStillPasses() {
    // A file that also reproduces the marker is indistinguishable from real
    // input, by construction. Asserting this keeps the honest framing: Gate 2
    // narrows, Gate 1 authorises.
    let faithful = """
      \u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}
      \u{276F} text between rules
      \u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}
      """
    #expect(TerminalScreenParser.locate(inScreenTail: faithful)?.inputLine == "text between rules")
  }

  @Test("A boundary must repeat ONE glyph")
  func mixedBoundaryGlyphsRefuse() {
    let mixed = """
      \u{2500}\u{2501}\u{2500}\u{2501}
      \u{276F} old text
      \u{2500}\u{2501}\u{2500}\u{2501}
      """
    #expect(TerminalScreenParser.locate(inScreenTail: mixed) == nil)
  }

  @Test("Every row-boundary shape is index-safe")
  func rowBoundaryShapesAreSafe() {
    // Swift ranges TRAP on invalid bounds and this runs on the paste heart path,
    // so a crash would be worse than a wrong answer.
    #expect(TerminalScreenParser.locate(inScreenTail: "") == nil)
    #expect(TerminalScreenParser.locate(inScreenTail: "ordinary row") == nil)
    #expect(
      TerminalScreenParser.locate(inScreenTail: "\u{203A} final row")?.inputLine == "final row")

    let boundedAtEdges = """
      \u{2500}\u{2500}\u{2500}\u{2500}
      \u{276F} edge text
      \u{2500}\u{2500}\u{2500}\u{2500}
      """
    #expect(TerminalScreenParser.locate(inScreenTail: boundedAtEdges)?.inputLine == "edge text")

    let adjacent = """
      \u{2500}\u{2500}\u{2500}\u{2500}
      \u{2500}\u{2500}\u{2500}\u{2500}
      """
    #expect(TerminalScreenParser.locate(inScreenTail: adjacent) == nil)

    let blanksOnly = """
      \u{2500}\u{2500}\u{2500}\u{2500}


      \u{2500}\u{2500}\u{2500}\u{2500}
      """
    #expect(TerminalScreenParser.locate(inScreenTail: blanksOnly) == nil)
  }

  @Test("A stale Codex row with a shell prompt below it refuses")
  func staleCodexRowBelowALivePromptRefuses() {
    // CLASS FIX, whole-diff review r2: the staleness check lived only on the
    // boxed path, so an exited Codex left its last input row matchable — the
    // shell prompt beneath merely counted as one of the two permitted status
    // rows. With another supported CLI open in a different tab, Gate 1 passes
    // too, and dictation at the shell prompt would have been joined onto stale
    // Codex text.
    let stale = """
      \u{203A} an old codex prompt
      \u{276F} git commit -m fix the
      """
    #expect(TerminalScreenParser.locate(inScreenTail: stale) == nil)
  }

  @Test("Both layout paths apply the SAME staleness rule", arguments: ["\u{203A}", "boxed"])
  func stalenessAppliesToEveryLayout(kind: String) {
    // Enumerating the class rather than fixing the reported instance: there are
    // exactly two layout paths, and both must refuse.
    let screen =
      kind == "boxed"
      ? """
      \u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}
      \u{276F} old boxed input
      \u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}
      $ ls -la
      """
      : """
      \u{203A} old codex input
      $ ls -la
      """
    #expect(TerminalScreenParser.locate(inScreenTail: screen) == nil)
  }

  @Test("Codex still matches when only its own status bar sits below")
  func codexStillMatchesWithItsStatusBar() {
    // The two-way control: the staleness rule must not refuse Codex's normal
    // screen, or the fix above would disable the tool entirely.
    let live = """
      earlier output
      \u{203A} refactor the handler
        weekly 63% left
      """
    #expect(TerminalScreenParser.locate(inScreenTail: live)?.cli == .codex)
  }

  // MARK: - Character handling

  @Test("The box's non-breaking padding becomes an ordinary space")
  func normalisesNonBreakingSpace() {
    let located = TerminalScreenParser.locate(inScreenTail: Self.claudeBox("git\u{00A0}commit the"))
    #expect(located?.inputLine == "git commit the")
    #expect(located?.inputLine.contains("\u{00A0}") == false)
  }

  @Test("Trailing whitespace survives, because it is load-bearing")
  func preservesTrailingWhitespace() {
    // Every dictation ends with a space, so the buffer is one character longer
    // than the visible sentence. Dropping it welds the next word onto the last.
    let located = TerminalScreenParser.locate(inScreenTail: Self.claudeBox("fix the "))
    #expect(located?.inputLine == "fix the ")
  }

  @Test("A marker with no separating space still strips cleanly")
  func stripsMarkerWithoutSpace() {
    let located = TerminalScreenParser.locate(inScreenTail: Self.claudeBox("\u{276F}no space"))
    // The builder already supplies one marker; this adds a second immediately
    // before the text, which must survive as ordinary content.
    #expect(located?.inputLine == "\u{276F}no space")
  }

  @Test("Emoji and non-Latin text survive intact")
  func preservesNonLatinText() {
    #expect(
      TerminalScreenParser.locate(inScreenTail: Self.claudeBox("ship it 🚀 déjà vu"))?.inputLine
        == "ship it 🚀 déjà vu")
    #expect(
      TerminalScreenParser.locate(inScreenTail: Self.codexScreen("日本語のテキスト"))?.inputLine
        == "日本語のテキスト")
  }

  @Test("Codex refuses when too much sits below its input row")
  func codexRefusesWhenBuriedInOutput() {
    // Its status bar is at most two rows. More means the marker row is
    // scrollback, not the live input.
    let buried = """
      \u{203A} an old command
      output line one
      output line two
      output line three
      """
    #expect(TerminalScreenParser.locate(inScreenTail: buried) == nil)
  }
}
