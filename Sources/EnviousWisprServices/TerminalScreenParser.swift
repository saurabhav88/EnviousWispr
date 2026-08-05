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
/// Ported from the parked Level 3 prototype rather than reinvented — it drove
/// ten dictated chunks through Ghostty and paid for every rule here. That
/// prototype no longer lives in this repo; it is the git tag
/// `parked/level3-seam-joining-2026-07-28` (issue #1795), whose message says
/// how to check it out.
package enum TerminalScreenParser {

  /// Where the input line is, and which tool drew it.
  package struct Located: Equatable, Sendable {
    package let cli: SupportedTerminalCLI
    package let inputLine: String
    /// True when the line WRAPPED and a populated row above this one was
    /// dropped, so `inputLine` is the tail of what the user typed rather than
    /// all of it.
    ///
    /// Carried rather than inferred. The downstream document-start test was
    /// `leftWindow.utf16.count == selectionLocation`, which a terminal always
    /// satisfies because both come from the same string — so a cut tail claimed
    /// to reach the start of the input, and `completeLeftToken` would treat a
    /// wrap fragment as a complete word. That authorises the one rule that
    /// DELETES a dictated word.
    package let leftWasCut: Bool

    /// How the box's opening rule was drawn, or nil for a CLI that draws no box.
    ///
    /// Carried so a titled read is visible in the FIELD. The parser's own
    /// refusal names never leave the log: `TerminalContextResolver` collapses
    /// every one of them into `terminal_screen_refused` before telemetry,
    /// deliberately, because that enum's raw values are a shipped closed set. So
    /// "the titled path silently stopped matching" cannot be seen from the
    /// refusal side, which is what an earlier version of this change wrongly
    /// assumed when it declined to carry this.
    package let boxOpeningKind: BoxOpeningKind?

    package init(
      cli: SupportedTerminalCLI, inputLine: String, leftWasCut: Bool = false,
      boxOpeningKind: BoxOpeningKind? = nil
    ) {
      self.cli = cli
      self.inputLine = inputLine
      self.leftWasCut = leftWasCut
      self.boxOpeningKind = boxOpeningKind
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

  /// Any Box Drawing (U+2500–U+257F) or Block Element (U+2580–U+259F) codepoint.
  ///
  /// The two six-character sets above are the glyphs a rule is DRAWN with; this
  /// is the whole range a divider might use. They are different questions, and
  /// answering the second with the first let `──── a ├ b ──` pass as a titled
  /// border, because `├` is a box-drawing character that neither set contains.
  /// A title never legitimately contains one of these.
  static func isBoxDrawingGlyph(_ character: Character) -> Bool {
    character.unicodeScalars.contains { (0x2500...0x259F).contains($0.value) }
  }

  /// Which end of the box a row is being tested for.
  ///
  /// The two ends have DIFFERENT rules, so the mode is explicit rather than
  /// implied by which function was called. Only the opening may carry a title.
  enum BoundaryUse {
    case opening
    case closing
  }

  /// How the opening rule was drawn. Carried so the field can tell a titled
  /// read from an ordinary one; the title's text is never recorded.
  package enum BoxOpeningKind: String, Equatable, Sendable {
    case plain
    case titled
  }

  package struct BoundaryMatch: Equatable, Sendable {
    package let boxClass: BoundaryClass
    package let openingKind: BoxOpeningKind
  }

  /// Whether a row is the rule above or below an input box.
  ///
  /// ONE authority for both ends, taking the end as a parameter. This replaces
  /// `boundaryClass(of:)`, which no longer exists under that name: the first cut
  /// of #1932 kept it and added a second function beside it that re-derived the
  /// glyph set and the class, which grounded review correctly called two border
  /// authorities under a plan claiming one.
  ///
  /// A plain rule is one repeated glyph, at least four of them — the mixture
  /// `─━═─` is refused so ASCII art cannot be misread as a box.
  ///
  /// An OPENING rule may also carry Claude Code's session title:
  ///
  ///     ──────────────────────────────────── ollama-build-order-decision ──
  ///     ❯ commit it and keep going
  ///     ───────────────────────────────────────────────────────────────────
  ///
  /// Requiring one repeated glyph meant that row was not a boundary, so
  /// `locateBoxed` found fewer than two and continuation casing silently did
  /// nothing. MEASURED over 4,397 accessibility frames captured from the
  /// founder's own window: 15 refused this way, against 43 that located.
  ///
  /// The trailing run must be EXACTLY two, which is the only invariant the
  /// capture actually shows — both measured rows are 36/2 and 20/2. An earlier
  /// draft used the ratio `trailing * 4 <= leading` to mean "right-aligned",
  /// reasoning that a fixed suffix would break the day Claude Code changed its
  /// margin. Grounded review killed it with a counterexample that was then
  /// reproduced against the real parser: an ordinary rule of 24 glyphs, a title,
  /// and 6 glyphs satisfies the ratio exactly, so any right-heavy program output
  /// with a `❯` line under it was located and its rendered text returned as the
  /// user's own sentence. The two failure directions are not symmetric — a
  /// margin change under the fixed suffix refuses, which is merely today's
  /// behaviour, while the ratio accepts and PERMITS A REPAIR on text nobody
  /// typed. Widen this only when a different geometry is actually observed.
  ///
  /// The title is Claude Code's own AI-generated session name, so nothing is
  /// assumed about its language, characters or length — it is never read.
  static func boundary(of row: Substring, for use: BoundaryUse) -> BoundaryMatch? {
    let trimmed = Substring(row.trimmingCharacters(in: .whitespaces))
    guard trimmed.count >= 4, let glyph = trimmed.first else { return nil }

    let boxClass: BoundaryClass
    if lightBoxGlyphs.contains(glyph) {
      boxClass = .light
    } else if blockBoxGlyphs.contains(glyph) {
      boxClass = .block
    } else {
      return nil
    }

    if trimmed.dropFirst().allSatisfy({ $0 == glyph }) {
      return BoundaryMatch(boxClass: boxClass, openingKind: .plain)
    }

    // Titled openings are LIGHT-RULE ONLY, which is the only class the capture
    // ever showed one on. Cloud review caught the first cut extending it to
    // Gemini's block rules, and that combined the looser border rule with the
    // WEAKER marker: `>` is ordinary in quoted mail, diffs and redirects, which
    // is exactly why this file refuses to search by it. Claude Code's `❯` is
    // rare enough to carry the weight; `>` is not, so a titled block border
    // would widen the false-accept surface where it is already thinnest — and
    // on no evidence, since no Gemini session appears in the capture at all.
    //
    // Gemini therefore keeps today's strict behaviour exactly. Widen this when
    // a real titled Gemini layout is observed, not before: an accepted screen
    // permits a repair on text nobody typed, and a refusal costs a capital.
    guard use == .opening, boxClass == .light, trimmed.last == glyph else { return nil }

    let leading = trimmed.prefix(while: { $0 == glyph }).count
    let trailing = trimmed.reversed().prefix(while: { $0 == glyph }).count
    guard leading >= 4, trailing == 2, leading + trailing < trimmed.count else { return nil }

    let middle = trimmed.dropFirst(leading).dropLast(trailing)

    // The rest of the row is checked against the MEASURED STRUCTURE rather than
    // against the findings so far, because enumerating from findings is what
    // kept missing cases. Both captured rows are exactly:
    //
    //     <run of light glyph><space><title text><space><run of light glyph>
    //
    // so every part of that gets a guard: glyph CLASS and the two run LENGTHS
    // above, then PADDING on both sides of the title, no box glyph of any class
    // inside it, and at least one real character in it.
    //
    // An earlier revision listed "four ways this span can over-accept" and
    // called the class closed. It was not: that list covered what may be INSIDE
    // the middle and never its BOUNDARIES, so `────────────────────Section──`
    // still passed and a program-rendered divider above a `❯` line was read as
    // the live input. Deriving the guards from the row's shape closes the set
    // by construction, which enumerating symptoms did not.
    // A plain space or the non-breaking space a box pads with, and nothing else.
    // `isWhitespace` also admits tabs and the exotic Unicode spaces, which no
    // measured row uses — and program output that happens to use one would then
    // pass as a border.
    guard let opensPadding = middle.first, let closesPadding = middle.last,
      opensPadding == " " || opensPadding == "\u{00A0}",
      closesPadding == " " || closesPadding == "\u{00A0}"
    else { return nil }

    // No box glyph of ANY class, not merely the leading one: a plain rule
    // refuses the mixture `─━═─` deliberately, so admitting that same mixture
    // through the title span contradicted the boundary contract, and
    // `──── a ━━ b ──` was located with its rendered text returned as the
    // user's sentence. This also rejects `──── a ──── b ────`, which is
    // decoration rather than a border.
    guard !middle.contains(where: isBoxDrawingGlyph) else { return nil }

    // A title is text. Without this, `──── ────` — a rule broken by spaces —
    // would read as a titled border.
    guard middle.contains(where: { !$0.isWhitespace && $0 != "\u{00A0}" }) else { return nil }

    return BoundaryMatch(boxClass: boxClass, openingKind: .titled)
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

  /// Strip a CONTINUATION row's gutter — the blank cells a wrapped row is
  /// indented by, which are as wide as the marker prefix above it.
  ///
  /// Dropping all leading whitespace is equivalent to deriving that width, and
  /// needs no width to derive: a wrap can never put whitespace at the START of a
  /// row, because the spaces at a wrap boundary are consumed. MEASURED against a
  /// live Claude Code at 67 columns — `"A"x62 + "  next"` renders its
  /// continuation row as `next`, with BOTH spaces gone.
  static func stripContinuationGutter(_ row: Substring) -> String {
    String(row.drop(while: { $0.isWhitespace || $0 == "\u{00A0}" }))
      .replacingOccurrences(of: "\u{00A0}", with: " ")
  }

  /// The column a row's first non-whitespace character sits at, or nil when the
  /// row is blank.
  static func indentWidth(of row: Substring) -> Int? {
    let leading = row.prefix(while: { $0.isWhitespace || $0 == "\u{00A0}" }).count
    return leading == row.count ? nil : leading
  }

  /// Whether `row` can be part of the input block below a marker row.
  ///
  /// AT LEAST the gutter, never exactly it: a wrap continuation sits exactly at
  /// the gutter, but a hard-newline row the user indented themselves sits past
  /// it, and requiring equality ended the block early and read the row above
  /// the caret (whole-diff review r2, P1). A blank row qualifies because a user
  /// may leave one inside their own prompt.
  ///
  /// Without a readable gutter nothing can be judged part of the block, so the
  /// block collapses to the marker row — the conservative direction.
  static func continuesInput(_ row: Substring, gutter: Int?) -> Bool {
    if isBlank(row) { return true }
    guard let gutter, let indent = indentWidth(of: row) else { return false }
    return indent >= gutter
  }

  /// The column the user's text starts at on a MARKER row: past any leading
  /// blank cells, the marker itself, and the single space after it.
  ///
  /// This is the gutter every continuation row beneath it is indented by, so it
  /// is measured from the screen rather than hardcoded — Claude Code's is 2
  /// cells and Gemini's is 3, because their markers are different widths.
  static func markerTextColumn(of row: Substring, marker: Character) -> Int? {
    guard let indent = indentWidth(of: row) else { return nil }
    var index = row.index(row.startIndex, offsetBy: indent)
    guard index < row.endIndex, row[index] == marker else { return nil }
    var column = indent + 1
    index = row.index(after: index)
    if index < row.endIndex, row[index] == " " || row[index] == "\u{00A0}" {
      column += 1
    }
    return column
  }

  /// Whether a LIVE shell prompt sits below `index`, which proves the match was
  /// scrollback: the user ran a full-screen tool, quit it, and is now at a shell.
  ///
  /// CLASS FIX, whole-diff review r2. This check existed only on the boxed path,
  /// so an old Codex row with a shell prompt beneath it still matched — the
  /// prompt merely counted as one of the two permitted status rows. Both layout
  /// paths now share this one owner, because "which layouts apply the staleness
  /// check" is exactly the kind of question that drifts when each path answers
  /// it separately.
  static func aLivePromptSits(below index: Int, in rows: [Substring]) -> Bool {
    guard index + 1 < rows.count else { return false }
    for row in rows[(index + 1)...] where !isBlank(row) {
      if let opener = openingCharacter(of: row), shellPromptMarkers.contains(opener) {
        return true
      }
    }
    return false
  }

  // MARK: - Entry point

  /// Locate the input line, or nil to refuse.
  ///
  /// Refusals ARE the feature. An empty box, a stale box, an unrecognised
  /// layout and a bare shell all return nil, and the user gets today's
  /// behaviour unchanged.
  ///
  /// A WRAPPED box used to refuse too, and no longer does (#1926) — that
  /// refusal made the feature unavailable for most real dictations, because a
  /// 67-column terminal wraps at 63 characters and two sentences do not fit. It
  /// returns the LAST row instead. Rejoining rows is still impossible and still
  /// not attempted; the last row alone is exact.
  ///
  /// This shape is kept because the suite encodes its behaviour contract
  /// through it.
  ///
  /// DELEGATES rather than re-deciding: a second copy of the matching rules
  /// could drift from the first, and then the log would describe a decision the
  /// product did not make.
  package static func locate(inScreenTail tail: String) -> Located? {
    if case .located(let found) = locateDetailed(inScreenTail: tail) { return found }
    return nil
  }

  /// The same decision, carrying WHY it refused.
  package static func locateDetailed(inScreenTail tail: String) -> LocateResult {
    let rows = tail.split(separator: "\n", omittingEmptySubsequences: false)

    // Codex first: it draws NO box, so the box search cannot find it, and its
    // status bar sits below the input. Anchoring on "the last non-empty row"
    // was measured to return `weekly 63% left` from that status bar.
    switch locateCodex(rows) {
    case .located(let located): return .located(located)
    case .refused(let codexRefusal):
      switch locateBoxed(rows) {
      case .located(let located): return .located(located)
      case .refused(let boxedRefusal):
        // BOTH routes, deliberately. Every normal Claude Code screen fails the
        // Codex probe first, so logging that refusal alone would report
        // `no_opening_marker` on every dictation and send the next reader
        // chasing the wrong layout entirely.
        return .refused(Refusal(codex: codexRefusal, boxed: boxedRefusal))
      }
    }
  }

  // MARK: - Typed refusals
  //
  // `locate` returned a bare `nil` for ten structurally different reasons, and
  // the caller collapsed all of them into one telemetry value. That discarded
  // the only evidence that could explain a field failure: on 2026-08-04 three
  // of four dictations refused here in under a millisecond, and no amount of
  // reading could say which guard fired. Three hypotheses were tested by hand
  // and all three were wrong.
  //
  // Closed-set names only. Never the screen, the input text, the marker-adjacent
  // text, or any row's contents — the same boundary `TerminalContextRefusal`
  // keeps.

  package enum CodexRefusal: String, Sendable {
    case noOpeningMarker = "codex:no_opening_marker"
    case tooManyPopulatedRowsBelow = "codex:too_many_populated_rows_below"
    case livePromptBelow = "codex:live_prompt_below"
    case emptyInput = "codex:empty_input"
    /// The caret is on a new empty line of the user's own input, not on the
    /// last populated row.
    case ambiguousTrailingBlankRow = "codex:ambiguous_trailing_blank_row"
  }

  package enum BoxedRefusal: Sendable {
    case fewerThanTwoBoundaries
    case incompatibleBoundaries
    case populatedBodyRows(Int)
    case livePromptBelow
    case wrongOpeningMarker
    case emptyInput
    /// The last body row is blank while an earlier one is populated, which two
    /// different inputs produce and which want opposite answers.
    case ambiguousTrailingBlankRow

    package var telemetryName: String {
      switch self {
      case .fewerThanTwoBoundaries: return "boxed:fewer_than_two_boundaries"
      case .incompatibleBoundaries: return "boxed:incompatible_boundaries"
      case .populatedBodyRows(let count):
        // Retained for the ALL-BLANK body only, now that a wrapped box is read
        // rather than refused. It is a small non-negative integer describing
        // screen STRUCTURE, never content.
        return count == 0
          ? "boxed:zero_populated_body_rows"
          : "boxed:multiple_populated_body_rows(\(count))"
      case .livePromptBelow: return "boxed:live_prompt_below"
      case .wrongOpeningMarker: return "boxed:wrong_opening_marker"
      case .emptyInput: return "boxed:empty_input"
      case .ambiguousTrailingBlankRow: return "boxed:ambiguous_trailing_blank_row"
      }
    }
  }

  package struct Refusal: Sendable {
    package let codex: CodexRefusal
    package let boxed: BoxedRefusal
  }

  package enum LocateResult: Sendable {
    case located(Located)
    case refused(Refusal)
  }

  // MARK: - Codex

  /// Codex: the last row that OPENS with `›`, with at most two populated rows
  /// below it (its status bar).
  ///
  /// "Opens" is load-bearing. A row that merely CONTAINS the marker — a footer
  /// reading `Press › to continue` — is not input, and requiring the marker to
  /// start the row is what separates them.
  static func locateCodex(_ rows: [Substring]) -> CodexLocateResult {
    guard
      let index = rows.indices.last(where: { openingCharacter(of: rows[$0]) == codexMarker })
    else { return .refused(.noOpeningMarker) }

    // The input BLOCK: the marker row plus every following row indented to
    // exactly the gutter, stopping at the first blank row.
    //
    // Codex draws no box, so nothing else delimits its input, and the flat
    // "at most two populated rows below the marker" rule counted a WRAPPED
    // line's own continuation rows against its status-bar allowance. Worse, a
    // ONE-row wrap plus a one-row status bar is exactly two, so it passed and
    // returned the MARKER row — the text from before the wrap. That is a silent
    // wrong answer rather than a refusal, and it ships today.
    //
    // MEASURED at 67 columns: continuation rows carry the 2-cell gutter, then
    // ONE blank row, then the status bar.
    //
    // FOUND BY WALKING UP FROM THE BOTTOM, not down from the marker. Two review
    // rounds found the same class scanning downward — first the status bar
    // absorbed as continuation text, then a user-indented row ending the block
    // early — so the class is enumerated here rather than patched again.
    //
    // Every row that is the user's INPUT: the marker row; a wrap continuation
    // (indent == gutter); a hard-newline row the user indented further
    // (indent > gutter); a blank line inside their own prompt; and the caret's
    // own trailing blank line. Every row that is NOT: the single blank
    // separator, the 1-2 status rows below it — which carry the SAME gutter as
    // a continuation row and so cannot be told apart by indent — and any
    // trailing blanks below those.
    //
    // Downward scanning cannot separate those sets. Upward can, because the
    // separator is the FIRST blank row met walking up from the last populated
    // row on screen, and everything past it is by definition the status bar.
    let gutter = markerTextColumn(of: rows[index], marker: codexMarker)
    var separator: Int? = nil
    var statusRows = 0
    if let lastPopulated = rows.indices.last(where: { !isBlank(rows[$0]) }), lastPopulated > index {
      var probe = lastPopulated
      while probe > index {
        if isBlank(rows[probe]) {
          separator = probe
          break
        }
        statusRows += 1
        probe -= 1
      }
    }

    // Rows between the marker and the separator are the input, and every one of
    // them must be blank or indented to AT LEAST the gutter. A row that is not
    // was never part of this input, so the block collapses to the marker row
    // and the original limit judges everything below it — which is what keeps a
    // marker left in scrollback refused.
    var blockEnd = index
    if let separator, statusRows <= 2 {
      let inputRows = (index + 1)..<separator
      if inputRows.allSatisfy({ continuesInput(rows[$0], gutter: gutter) }) {
        // The caret sits on its own blank line, so the last populated row is
        // NOT where the next word goes and lowering against it would continue a
        // sentence the user deliberately ended. The boxed path already refuses
        // this; MEASURED at 67 columns, a caret at the end of the input leaves
        // no blank row here and a newline (Ctrl+J) leaves one.
        if let last = inputRows.last, isBlank(rows[last]) {
          return .refused(.ambiguousTrailingBlankRow)
        }
        blockEnd = inputRows.last ?? index
      }
    }

    // The ORIGINAL staleness limit, moved past the block rather than removed.
    // Ordinary output is not indented to the gutter, so it never joins the
    // block and still counts here — which is what keeps a marker row left in
    // scrollback refused.
    //
    // Codex's consult also proposed requiring every pre-wrap row to reach the
    // screen's content edge. REFUTED by measurement: in the real wrapped frame
    // the pre-wrap rows are 62 and 60 cells wide on a 67-column screen, because
    // a word wrap moves a whole word down. That rule would refuse almost every
    // real wrap.
    let populatedBelow = rows[(blockEnd + 1)...].filter { !isBlank($0) }.count
    guard populatedBelow <= 2 else { return .refused(.tooManyPopulatedRowsBelow) }
    // Same staleness rule as the boxed layouts: a live shell prompt below means
    // Codex has exited and this row is history. Scanned from the END of the
    // block, never from the marker row: a wrapped line whose own continuation
    // happens to start with `$`, `%`, `#` or `❯` would otherwise read as a live
    // shell prompt and refuse.
    guard !aLivePromptSits(below: blockEnd, in: rows) else { return .refused(.livePromptBelow) }

    let line =
      blockEnd == index
      ? stripLeadingMarker(rows[index], codexMarker)
      : stripContinuationGutter(rows[blockEnd])
    guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { return .refused(.emptyInput) }
    return .located(Located(cli: .codex, inputLine: line, leftWasCut: blockEnd != index))
  }

  enum CodexLocateResult {
    case located(Located)
    case refused(CodexRefusal)
  }

  // MARK: - Boxed layouts

  /// Claude Code and Gemini both draw a box; the RULE GLYPH tells them apart.
  static func locateBoxed(_ rows: [Substring]) -> BoxedLocateResult {
    // Only the opening border is permitted to carry a title. No titled closing
    // border appeared in 4,397 captured frames. Keeping the closing strict is an
    // explicit fail-closed POLICY, not a claim that titled closers never occur —
    // and it is what stops a decorative row being taken for the bottom of a box.
    guard
      let closing = rows.indices.reversed().lazy
        .compactMap({ index in boundary(of: rows[index], for: .closing).map { (index, $0) } })
        .first
    else { return .refused(.fewerThanTwoBoundaries) }

    guard
      let opening = rows[..<closing.0].indices.reversed().lazy
        .compactMap({ index in boundary(of: rows[index], for: .opening).map { (index, $0) } })
        .first
    else { return .refused(.fewerThanTwoBoundaries) }
    // Both rules must be the same kind of box.
    //
    // NOT the same WIDTH, though a revision of this change briefly required it.
    // The idea was sound — two sides of one rectangle — and it measured clean on
    // all 4,397 captured frames. It is still wrong, because `String.count` is
    // not terminal columns: a CJK or emoji title occupies two cells per
    // character, so a box that renders perfectly square has an opening whose
    // count is SHORTER than its closing rule, and the check would refuse it.
    // That silently disables terminal repair for anyone whose session title is
    // not Latin, which is a far worse trade than the P3 it was added for — a
    // divider pasted into the user's own input, which the marker check on the
    // first body row already refuses.
    //
    // Doing it properly needs a terminal-cell-width helper validated against
    // real captures, and no capture here contains a non-Latin title, so there is
    // nothing to validate one against. Measuring in the wrong unit is not a
    // smaller version of measuring correctly.
    guard opening.1.boxClass == closing.1.boxClass, closing.0 > opening.0 + 1 else {
      return .refused(.incompatibleBoundaries)
    }

    // UNFILTERED, deliberately. The old slice dropped blank rows before
    // counting, and the blank-row question cannot be asked once they are gone —
    // a blank row sitting AFTER the text is the one shape that has to refuse.
    let body = Array(rows[(opening.0 + 1)..<closing.0])
    let populated = body.indices.filter { !isBlank(body[$0]) }
    guard let first = populated.first, let last = populated.last else {
      return .refused(.populatedBodyRows(0))
    }

    guard !aLivePromptSits(below: closing.0, in: rows) else { return .refused(.livePromptBelow) }

    let cli: SupportedTerminalCLI = closing.1.boxClass == .block ? .geminiCLI : .claudeCode
    let marker = closing.1.boxClass == .block ? geminiMarker : claudeMarker
    // The marker sits on the FIRST populated row. A wrapped continuation row
    // never carries one, so this is checked where the marker actually is rather
    // than on whichever row is read.
    //
    // Grounded review caught a real error here, and the error was in my
    // reasoning rather than the code: because screen matching is spoofable AS A
    // CLASS, I concluded it was not worth refusing a measured INSTANCE. Wrong.
    // The measured spoof — a file of box-drawing rows shown in vim or less —
    // carries NO marker, while both real input rows always do, so this refuses
    // it at no cost. A faithful spoof that reproduces the marker still passes,
    // which is exactly why Gate 1 remains the authority; closing an instance is
    // not a claim to have closed the class.
    guard openingCharacter(of: body[first]) == marker else {
      return .refused(.wrongOpeningMarker)
    }

    // An UNTOUCHED box refuses, and is tested BEFORE the trailing-blank rule so
    // that a box drawn with spare height still reports "nothing typed" rather
    // than "ambiguous". The prototype's exact failure was reading an empty box
    // back as the hint text printed below it, which would delete words nobody
    // typed.
    if populated.count == 1,
      stripLeadingMarker(body[first], marker).trimmingCharacters(in: .whitespaces).isEmpty
    {
      return .refused(.emptyInput)
    }

    // A blank row BELOW the text is the one wrap shape that cannot be read.
    // MEASURED: `"A"x63 + " "` (ended exactly at the wrap) and
    // `"first line of text" + backslash + Enter` (a deliberate new line) render
    // the SAME two rows, and want opposite answers — continue-and-lowercase
    // versus new-line-and-capitalise. Refusing keeps today's behaviour instead
    // of inventing a new wrong one.
    guard last == body.count - 1 else { return .refused(.ambiguousTrailingBlankRow) }

    // The LAST populated row, not the first. Rejoining rows is impossible —
    // `"A"x63 + " next word"` and `"A"x64 + " next word"` render byte-identical
    // screens — but the last row is ALWAYS the verbatim tail of what was typed,
    // measured at every length from 40 to 260 characters on all three CLIs. And
    // the tail is all the repair needs: it walks backward to the first
    // non-whitespace character.
    let line =
      last == first
      ? stripLeadingMarker(body[last], marker)
      : stripContinuationGutter(body[last])
    guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { return .refused(.emptyInput) }
    return .located(
      Located(
        cli: cli, inputLine: line, leftWasCut: last != first,
        boxOpeningKind: opening.1.openingKind))
  }

  enum BoxedLocateResult {
    case located(Located)
    case refused(BoxedRefusal)
  }
}
