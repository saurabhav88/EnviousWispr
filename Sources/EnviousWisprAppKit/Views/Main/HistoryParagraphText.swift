import EnviousWisprCore
import SwiftUI

extension EnvironmentValues {
  @Entry var historyHighlightQuery = ""
}

/// A dictation card's text as blocks (#3147 §3.4). Each block is one line of the shown text.
///
/// Marked up blocks draw each change's removed words struck through (red) and its polished
/// words highlighted (green tint, bold), from `MarkUpPalette`, the table the other Marked up
/// views read. Either half of a change is a link that opens the change inspector.
struct HistoryParagraphText: View {
  enum Content: Equatable {
    case plain(String)
    case markedUp([HistoryDictationPresentation.MarkRun])
  }

  struct Block: Equatable, Identifiable {
    let id: Int
    let content: Content
  }

  let blocks: [Block]
  var query = ""
  let onOpenChange: (Int) -> Void

  /// The link scheme the Marked up runs carry; never leaves the app.
  static let changeScheme = "ew-history-change"

  var body: some View {
    VStack(alignment: .leading, spacing: DesignSpacing.md) {
      ForEach(blocks) { block in
        text(for: block)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
    .environment(
      \.openURL,
      OpenURLAction { url in
        guard let index = Self.changeIndex(from: url) else { return .systemAction }
        onOpenChange(index)
        return .handled
      })
  }

  @ViewBuilder
  private func text(for block: Block) -> some View {
    switch block.content {
    case .plain(let text):
      Self.searchText(text, query: query)
        .font(.stBody)
        .foregroundStyle(.stTextPrimary)
        .textSelection(.enabled)
    case .markedUp(let runs):
      let styled = Self.attributed(runs)
      Text(query.isEmpty ? styled : Self.highlighting(
        styled, in: runs.map(\.text).joined(), query: query, markedUp: true))
        .font(.stBody)
        .textSelection(.enabled)
        .accessibilityRepresentation {
          Text(Self.accessibilityText(runs))
        }
        .accessibilityActions {
          ForEach(Self.changeIndices(runs), id: \.self) { index in
            Button(Self.accessibilityActionName(runs, change: index)) { onOpenChange(index) }
          }
        }
    }
  }

  // MARK: - Pure helpers (read by tests)

  static func searchText(_ source: String, query: String) -> Text {
    query.isEmpty
      ? Text(verbatim: source)
      : Text(highlighting(AttributedString(source), in: source, query: query))
  }

  static func highlighting(
    _ styled: AttributedString, in source: String, query: String, markedUp: Bool = false
  ) -> AttributedString {
    guard !query.isEmpty else { return styled }
    var result = styled
    var start = source.startIndex
    while start < source.endIndex,
      let match = source.range(of: query, options: .caseInsensitive,
        range: start..<source.endIndex, locale: .current), !match.isEmpty
    {
      let composed = (source as NSString).rangeOfComposedCharacterSequences(for: NSRange(match, in: source))
      if let characters = Range(composed, in: source), let range = Range(characters, in: result) {
        if markedUp {
          // Keep the edit colors and links legible while marking the search hit.
          result[range].underlineStyle = Text.LineStyle(pattern: .solid, color: .stAccent)
        } else {
          result[range].backgroundColor = Color.stAccent.opacity(0.32)
        }
      }
      start = match.upperBound
    }
    return result
  }

  static func changeURL(_ index: Int) -> URL? {
    URL(string: "\(changeScheme):\(index)")
  }

  static func changeIndex(from url: URL) -> Int? {
    guard url.scheme == changeScheme else { return nil }
    return Int(url.absoluteString.dropFirst(changeScheme.count + 1))
  }

  static func attributed(
    _ runs: [HistoryDictationPresentation.MarkRun], linksChanges: Bool = true
  ) -> AttributedString {
    var out = AttributedString()
    for run in runs {
      var piece = AttributedString(run.text)
      switch run.kind {
      case .same:
        piece.foregroundColor = Color.stTextBody
      case .removed:
        piece.foregroundColor = MarkUpPalette.removed
        piece.strikethroughStyle = .single
      case .added:
        piece.foregroundColor = MarkUpPalette.changedText
        piece.backgroundColor = MarkUpPalette.changedBackground
        piece.inlinePresentationIntent = MarkUpPalette.changedIntent
      }
      if linksChanges, let change = run.change, let url = changeURL(change) {
        piece.link = url
      }
      out.append(piece)
    }
    return out
  }

  /// The marks in words: strikethrough and highlight say nothing aloud. Reuses the Marked up
  /// view's spoken forms ("Removed: um.", "Added: so.").
  static func accessibilityText(_ runs: [HistoryDictationPresentation.MarkRun]) -> String {
    TranscribeFileExport.markedUpAccessibilityText(
      runs.map { run in
        let kind: WordDiff.Kind =
          switch run.kind {
          case .same: .same
          case .removed: .removed
          case .added: .added
          }
        return WordDiff.Segment(kind: kind, text: run.text, trailing: "")
      })
  }

  static func changeIndices(_ runs: [HistoryDictationPresentation.MarkRun]) -> [Int] {
    var seen = Set<Int>()
    return runs.compactMap(\.change).filter { seen.insert($0).inserted }
  }

  static func accessibilityActionName(
    _ runs: [HistoryDictationPresentation.MarkRun], change: Int
  ) -> String {
    let words = runs.filter { $0.change == change }.map(\.text).joined(separator: " ")
    return String(
      localized: "Show change: \(words)",
      comment:
        "History dictation card, VoiceOver action: opens the details of one AI Polish change. %@ is the changed words."
    )
  }
}
