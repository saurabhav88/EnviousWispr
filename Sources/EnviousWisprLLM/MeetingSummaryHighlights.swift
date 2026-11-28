import Foundation

/// #5049: the summary an EG-1 size leaves when it cannot write one. Up to eight unchanged
/// transcript lines, one per equal chronological span, chosen by how much they say. Pure and
/// language-neutral: lines are scored by their letters and numbers, so scripts without spaces
/// rank like any other. A small polish model rewrote the transcript instead of summarizing it
/// (#5049 findings), and a cleanup pass could change a speaker, number or negation, so the
/// lines are never rewritten.
enum MeetingSummaryHighlights {
  /// The most lines kept.
  static let maxLines = 8
  /// A line needs at least this many letters and numbers (after any speaker label) to count as
  /// saying something; fillers such as "Mm-hmm." fall below it.
  static let minimumScore = 12
  /// The longest line kept, in UTF-8 bytes; a longer one is cut and ends with "…".
  static let maxLineBytes = 240

  static func select(from transcript: String) -> [String] {
    // A missing-audio marker is removed from every line; a line with nothing said after that is
    // never a highlight, and with no line left the summary keeps its original failure.
    // Known limits (#5049 diff review rounds 4-7; a structured, per-turn source would close
    // them): the selector reads the flattened transcript, so it guesses the speaker label as the
    // text before the first ": ". A speaker name containing ": " with only a marker shows as the
    // name, and such a name can change a line's rank; unlabeled speech ending in ":" that shares
    // its turn with a marker is dropped; bracketed text holding a time inside speech or a name
    // ("Jamie [UTC+05:30]", a Custom Word "Build [12:30]") is removed as a marker; a speaker
    // name longer than the byte cap leaves an excerpt without speech.
    let candidates = lines(in: transcript).compactMap { original -> String? in
      let line = withoutGapMarkers(original)
      // Only a removed marker can leave a speaker label alone ("Call:"); speech that merely
      // ends in a colon stays.
      if line != original, line.hasSuffix(":"), !line.contains(": "), line.count <= 81 {
        return nil
      }
      return line.isEmpty ? nil : line
    }
    .map { (line: excerpt($0), score: score($0)) }
    .filter { $0.score > 0 }
    let substantive = candidates.filter { $0.score >= minimumScore }
    if substantive.isEmpty {
      return candidates.max(by: { $0.score < $1.score }).map { [$0.line] } ?? []
    }
    let spanCount = min(maxLines, substantive.count)
    var seen = Set<String>()
    var selected: [String] = []
    for span in 0..<spanCount {
      let start = span * substantive.count / spanCount
      let end = (span + 1) * substantive.count / spanCount
      let options = substantive[start..<end].filter { !seen.contains($0.line) }
      if let best = options.max(by: { $0.score < $1.score }) {
        seen.insert(best.line)
        selected.append(best.line)
      }
    }
    return selected
  }

  static var heading: String {
    String(
      localized: "Highlights",
      comment: "Meeting summary heading when the local model could not write a summary and the app saved key transcript lines instead.")
  }

  static var explanation: String {
    String(
      localized: "Key moments from the transcript. This model could not write a full summary of this meeting.",
      comment: "Meeting summary: the line under the Highlights heading, explaining the lines below are quoted from the transcript.")
  }

  static func markdown(_ lines: [String]) -> String {
    let bullets = lines.map { "- \(escaped($0))" }.joined(separator: "\n")
    return "## \(heading)\n\n\(explanation)\n\n\(bullets)"
  }

  /// The line as literal text: Markdown marks are escaped, so the summary view shows the quote
  /// exactly as it was spoken (a `[label](value)` would otherwise render as a link).
  static func escaped(_ line: String) -> String {
    var out = String.UnicodeScalarView()
    // Scalars, not characters: a mark inside an emoji ("*️⃣") is still a mark to the parser.
    for character in line.unicodeScalars {
      // The marks that change text inside a list item: escapes, code, emphasis, links and
      // images, raw HTML and autolinks, tables, strikethrough and entities. Line-start syntax
      // (headings, lists, quotes) cannot start here, after the "- " bullet. Fewer escapes keep
      // the saved file readable.
      if "\\`*_[]<>|~&".unicodeScalars.contains(character) { out.append("\\") }
      out.append(character)
    }
    return String(out)
  }

  private static func lines(in text: String) -> [String] {
    text.split(whereSeparator: \.isNewline)
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
  }

  private static func score(_ line: String) -> Int {
    var words = line[...]
    // A speaker label affects the score only; the saved line keeps it.
    if let separator = line.range(of: ": "), line[..<separator.lowerBound].count <= 80 {
      words = line[separator.upperBound...]
    }
    return words.lazy.filter { $0.isLetter || $0.isNumber }.prefix(64).count
  }

  /// The line without missing-audio markers, spaces tidied. A marker is a bracketed span that
  /// holds a meeting time ("[Could not transcribe 1:00 to 1:30]", in any interface language);
  /// other bracketed text, such as a speaker named "Jamie [Legal]", stays.
  private static func withoutGapMarkers(_ line: String) -> String {
    guard line.contains("[") else { return line }
    // The marker and the one space the composer put beside it; other spacing stays as written.
    return line.replacing(/\ ?\[[^\[\]]*\d:\d\d[^\[\]]*\]/, with: "")
      .trimmingCharacters(in: .whitespaces)
  }

  private static func excerpt(_ line: String) -> String {
    guard line.utf8.count > maxLineBytes else { return line }
    let suffix = "…"
    return MeetingSummary.prefix(line, tokens: maxLineBytes - suffix.utf8.count, .bytes)
      .trimmingCharacters(in: .whitespaces) + suffix
  }
}
