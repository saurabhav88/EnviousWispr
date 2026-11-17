import SwiftUI

/// Polished transcript text with its list lines drawn as dot bullets (founder, #4611).
///
/// Display only: the stored text, Copy, Save as, Share, Paste and search keep the real "- ".
/// A list line is one whose first non-space characters are a marker and a space (`listItem`);
/// AI Polish writes "- " (`CloudFixedPromptBuilder`, `AppleIntelligenceConnector`), and "* " and
/// "• " are read too. A wrapped item hangs under its text, not under the dot, the look of the
/// meeting summary's bullets (`MeetingReadableSummary`).
///
/// Text with no list line stays one `Text`, exactly as before. Text with list lines becomes
/// one `Text` per run of other lines and one row per item, so selection spans one block, as in
/// the meeting summary. Search highlights each block's own visible words.
struct HistoryListText: View {
  let text: String
  var query = ""
  /// `blocks(text)` when the caller already parsed it (#4586: the dictation card parses once
  /// for its whole and clamped text). `text` stays the source for text with no list line.
  private let parsed: [Block]?

  init(text: String, query: String = "") {
    self.text = text
    self.query = query
    self.parsed = nil
  }

  /// `blocks` must be `HistoryListText.blocks(text)`.
  init(text: String, blocks: [Block], query: String = "") {
    self.text = text
    self.query = query
    self.parsed = blocks
  }

  enum Block: Equatable {
    case prose(String)
    case item(String)
    /// An empty line between a list and the text around it.
    case gap
  }

  var body: some View {
    let blocks = parsed ?? Self.blocks(text)
    if Self.hasItem(blocks) {
      VStack(alignment: .leading, spacing: DesignSpacing.sm) {
        ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
          switch block {
          case .prose(let lines):
            HistoryParagraphText.searchText(lines, query: query)
              .fixedSize(horizontal: false, vertical: true)
          case .item(let item):
            HStack(alignment: .firstTextBaseline, spacing: DesignSpacing.sm) {
              Text(verbatim: "•").foregroundStyle(.stTextSecondary).accessibilityHidden(true)
              HistoryParagraphText.searchText(item, query: query)
                .fixedSize(horizontal: false, vertical: true)
            }
          case .gap:
            // With the stack's two gaps, about one empty line of the 14 pt text.
            Color.clear.frame(height: DesignSpacing.md).accessibilityHidden(true)
          }
        }
      }
    } else {
      HistoryParagraphText.searchText(text, query: query)
    }
  }

  // MARK: - Pure helpers (read by tests)

  /// Whether the blocks hold a list line, so the text draws as a list.
  nonisolated static func hasItem(_ blocks: [Block]) -> Bool {
    blocks.contains { if case .item = $0 { true } else { false } }
  }

  /// The words of a list line after its marker, or nil for any other line. "-" alone, "-5",
  /// "--", an en or em dash, and a dash inside a sentence are not list lines.
  nonisolated static func listItem(_ line: Substring) -> String? {
    let trimmed = line.drop { $0 == " " || $0 == "\t" }
    guard let marker = trimmed.first, ["-", "*", "•"].contains(marker) else { return nil }
    let rest = trimmed.dropFirst()
    guard rest.first == " " else { return nil }
    let words = rest.trimmingCharacters(in: .whitespaces)
    return words.isEmpty ? nil : words
  }

  /// The text as runs of other lines and single list items, in order. Blank lines at the edge
  /// of a run become one `gap`, so a list keeps the empty line the text had around it; a gap
  /// never starts or ends the text.
  nonisolated static func blocks(_ text: String) -> [Block] {
    var blocks: [Block] = []
    var prose: [Substring] = []
    func isBlank(_ line: Substring) -> Bool { line.allSatisfy { $0 == " " || $0 == "\t" || $0 == "\r" } }
    func appendGap() {
      if !blocks.isEmpty, blocks.last != .gap { blocks.append(.gap) }
    }
    func flushProse() {
      var lines = prose[...]
      var leadingBlank = false
      var trailingBlank = false
      while let first = lines.first, isBlank(first) { lines.removeFirst(); leadingBlank = true }
      while let last = lines.last, isBlank(last) { lines.removeLast(); trailingBlank = true }
      if leadingBlank { appendGap() }
      if !lines.isEmpty {
        blocks.append(.prose(lines.joined(separator: "\n")))
        if trailingBlank { appendGap() }
      }
      prose.removeAll()
    }
    for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
      if let item = listItem(line) {
        flushProse()
        blocks.append(.item(item))
      } else {
        prose.append(line)
      }
    }
    flushProse()
    if blocks.last == .gap { blocks.removeLast() }
    return blocks
  }
}
