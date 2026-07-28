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

  @Test("A WRAPPED box refuses rather than joining rows")
  func wrappedBoxRefuses() {
    // Joining screen rows reconstructs different text, and a soft wrap can fall
    // mid-word.
    let wrapped = """
      \u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}
      \u{276F} this line is long enough that it
      wrapped onto a second row
      \u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}
      """
    #expect(TerminalScreenParser.locate(inScreenTail: wrapped) == nil)
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

  @Test("A file drawing two box rules, shown in a pager, does not become input")
  func boxDrawingFileSpoofIsBoundedToOneLine() {
    // MEASURED live: a file with two `────` rows displayed in vim and in less
    // returned `text between rules`. Gate 2 CANNOT tell this from a real box —
    // that is precisely why Gate 1 exists and why this test asserts the shape is
    // matched rather than pretending a guard closes it.
    let spoofed = """
      \u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}
      text between rules
      \u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}
      """
    let located = TerminalScreenParser.locate(inScreenTail: spoofed)
    #expect(
      located?.inputLine == "text between rules",
      "the screen alone cannot refuse this — Gate 1 is the gate that does")
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
