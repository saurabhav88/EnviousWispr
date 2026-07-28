import Foundation

/// Gate 2: locate the input line inside a terminal's rendered screen.
///
/// **This never decides WHETHER to act.** Screen content is spoofable and that is
/// proven, not argued: in live measurement a printed `❯` line, and a file
/// containing two box-drawing rows shown in vim and in less, were BOTH read as
/// live input boxes. Guards close instances; the class stays open, because
/// anything drawn on a screen looks like an input box to a screen reader. Gate 1
/// — is a supported CLI actually running — is what authorises a read. This type
/// only answers "where is the line", and only after that.
///
/// Ported from the parked Level 3 prototype rather than reinvented
/// (`research/seam-joining/code/join_hotkey.py`), which drove ten dictated chunks
/// through Ghostty and paid for every rule here.
package enum TerminalScreenParser {

  /// Where the input line is, and which tool drew it.
  package struct Located: Equatable, Sendable {
    package let cli: SupportedTerminalCLI
    package let inputLine: String

    package init(cli: SupportedTerminalCLI, inputLine: String) {
      self.cli = cli
      self.inputLine = inputLine
    }
  }

  // MARK: - Glyphs

  /// Box rules drawn by Claude Code. Matched as a CLASS, never one codepoint.
  static let lightBoxGlyphs: Set<Character> = ["\u{2500}", "\u{2501}", "\u{2550}"]
  /// Half-block rules drawn by Gemini CLI.
  static let blockBoxGlyphs: Set<Character> = ["\u{2584}", "\u{2580}", "\u{2588}"]

  /// Codex opens its input row with this and draws no box at all.
  static let codexMarker: Character = "\u{203A}"
  /// Claude Code's in-box marker.
  static let claudeMarker: Character = "\u{276F}"
  /// Gemini's in-box marker.
  ///
  /// A bare `>` is ordinary in mail quoting, diffs and shell redirection, so it
  /// is STRIPPED once the box has already identified the row, and NEVER searched
  /// for. Searching by it would anchor on any quoted line on screen.
  static let geminiMarker: Character = ">"

  /// Markers that indicate a LIVE shell prompt.
  ///
  /// Used defensively only — never to locate input, because bare shell is
  /// deliberately unsupported (prompts are user-customisable, so there is no set
  /// to enumerate). A prompt appearing BELOW a matched box proves the box was
  /// scrollback rather than the live input.
  static let shellPromptMarkers: Set<Character> = ["\u{276F}", "\u{279C}", "$", "%", "#"]

  // MARK: - Row helpers

  /// Whether a row is one repeated box glyph — the rule above or below an input
  /// box. Requires four to avoid matching a short `---` in prose.
  static func boundaryClass(of row: Substring) -> BoundaryClass? {
    let trimmed = row.trimmingCharacters(in: .whitespaces)
    // ONE repeated glyph, which is what the rule always claimed and did not
    // enforce: a mixture such as `─━═─` was accepted, so ASCII art or another
    // tool's output could be misread as a box.
    guard
      trimmed.count >= 4,
      let glyph = trimmed.first,
      trimmed.dropFirst().allSatisfy({ $0 == glyph })
    else { return nil }

    if lightBoxGlyphs.contains(glyph) { return .light }
    if blockBoxGlyphs.contains(glyph) { return .block }
    return nil
  }

  package enum BoundaryClass: Equatable, Sendable {
    case light
    case block
  }

  /// A row carrying nothing a user typed. `CharacterSet.whitespaces` includes
  /// the non-breaking space a box pads with, so padding counts as blank.
  static func isBlank(_ row: Substring) -> Bool {
    row.trimmingCharacters(in: .whitespaces).isEmpty
  }

  /// The first non-whitespace character of a row, treating the box's
  /// non-breaking padding as whitespace.
  static func openingCharacter(of row: Substring) -> Character? {
    row.first { !$0.isWhitespace && $0 != "\u{00A0}" }
  }

  /// Strip one leading marker and the single space that separates it from the
  /// user's text.
  ///
  /// Trailing whitespace SURVIVES, deliberately: every dictation ends with a
  /// space, so the buffer is one character longer than the visible sentence, and
  /// dropping it welds the next word onto the last.
  static func stripLeadingMarker(_ row: Substring, _ marker: Character) -> String {
    var body = Substring(row.drop(while: { $0.isWhitespace || $0 == "\u{00A0}" }))
    if body.first == marker {
      body = body.dropFirst()
      if let next = body.first, next == " " || next == "\u{00A0}" {
        body = body.dropFirst()
      }
    }
    // NBSP is what a box pads with: whitespace to a human, a distinct character
    // to everything else.
    return String(body).replacingOccurrences(of: "\u{00A0}", with: " ")
  }

  // MARK: - Entry point

  /// Locate the input line, or nil to refuse.
  ///
  /// Refusals ARE the feature. A wrapped box, an empty box, a stale box, an
  /// unrecognised layout and a bare shell all return nil, and the user gets
  /// today's behaviour unchanged.
  package static func locate(inScreenTail tail: String) -> Located? {
    let rows = tail.split(separator: "\n", omittingEmptySubsequences: false)

    // Codex first: it draws NO box, so the box search cannot find it, and its
    // status bar sits below the input. Anchoring on "the last non-empty row"
    // was measured to return `weekly 63% left` from that status bar.
    if let located = locateCodex(rows) { return located }
    return locateBoxed(rows)
  }

  // MARK: - Codex

  /// Codex: the last row that OPENS with `›`, with at most two populated rows
  /// below it (its status bar).
  ///
  /// "Opens" is load-bearing. A row that merely CONTAINS the marker — a footer
  /// reading `Press › to continue` — is not input, and requiring the marker to
  /// start the row is what separates them.
  static func locateCodex(_ rows: [Substring]) -> Located? {
    guard
      let index = rows.indices.last(where: { openingCharacter(of: rows[$0]) == codexMarker })
    else { return nil }

    let populatedBelow = rows[(index + 1)...].filter { !isBlank($0) }.count
    guard populatedBelow <= 2 else { return nil }

    let line = stripLeadingMarker(rows[index], codexMarker)
    guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
    return Located(cli: .codex, inputLine: line)
  }

  // MARK: - Boxed layouts

  /// Claude Code and Gemini both draw a box; the RULE GLYPH tells them apart.
  static func locateBoxed(_ rows: [Substring]) -> Located? {
    let boundaries = rows.indices.compactMap { index -> (Int, BoundaryClass)? in
      boundaryClass(of: rows[index]).map { (index, $0) }
    }
    guard boundaries.count >= 2 else { return nil }

    let closing = boundaries[boundaries.count - 1]
    let opening = boundaries[boundaries.count - 2]
    // Both rules must be the same kind of box.
    guard opening.1 == closing.1, closing.0 > opening.0 + 1 else { return nil }

    let body = rows[(opening.0 + 1)..<closing.0].filter { !isBlank($0) }
    // More than one populated row means the input wrapped, and joining screen
    // rows reconstructs different text — a soft wrap can fall mid-word.
    guard body.count == 1, let row = body.first else { return nil }

    // A LIVE shell prompt below the box proves the box is scrollback: the user
    // ran a full-screen tool earlier, quit it, and is now at a shell.
    for below in rows[(closing.0 + 1)...] where !isBlank(below) {
      if let opener = openingCharacter(of: below), shellPromptMarkers.contains(opener) {
        return nil
      }
    }

    let cli: SupportedTerminalCLI = closing.1 == .block ? .geminiCLI : .claudeCode
    let marker = closing.1 == .block ? geminiMarker : claudeMarker
    // The row must carry its tool's marker.
    //
    // Grounded review caught a real error here, and the error was in my
    // reasoning rather than the code: because screen matching is spoofable AS A
    // CLASS, I concluded it was not worth refusing a measured INSTANCE. Wrong.
    // The measured spoof — a file of box-drawing rows shown in vim or less —
    // carries NO marker, while both real input rows always do, so this refuses
    // it at no cost. A faithful spoof that reproduces the marker still passes,
    // which is exactly why Gate 1 remains the authority; closing an instance is
    // not a claim to have closed the class.
    guard openingCharacter(of: row) == marker else { return nil }

    let line = stripLeadingMarker(row, marker)
    // An EMPTY box refuses. The prototype's exact failure was reading an empty
    // box back as the hint text printed below it, which would delete words
    // nobody typed.
    guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
    return Located(cli: cli, inputLine: line)
  }
}
