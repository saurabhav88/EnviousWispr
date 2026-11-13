import EnviousWisprCore
import SwiftUI

/// A dictation card's text as blocks with a reserved time gutter (#3147 §3.4). Each block is one
/// line of the shown text. When the recording and its passage times exist, a block whose passage
/// was heard shows a small "▶ 0:07" button in the gutter; the gutter's width is always reserved,
/// so revealing it never moves the text. The card decides when the gutter shows (hover, or any
/// keyboard focus in the card); a hidden gutter button stays keyboard reachable, and focusing it
/// reveals the gutter through `focus`.
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
    /// Where the block's passage starts in the recording; nil leaves its gutter empty.
    let seconds: Double?
  }

  let blocks: [Block]
  /// The recording and its passage times exist: reserve the gutter.
  let hasGutter: Bool
  /// Hover or focus in the card: show the gutter's buttons.
  let revealGutter: Bool
  /// Reduce Motion: the gutter appears without its fade.
  let reduceMotion: Bool
  let focus: FocusState<HistoryDictationCard.Focus?>.Binding
  let onPlay: (Double) -> Void
  let onOpenChange: (Int) -> Void

  /// The link scheme the Marked up runs carry; never leaves the app.
  static let changeScheme = "ew-history-change"

  var body: some View {
    VStack(alignment: .leading, spacing: DesignSpacing.md) {
      ForEach(blocks) { block in
        HStack(alignment: .firstTextBaseline, spacing: DesignSpacing.sm) {
          if hasGutter { gutter(for: block) }
          text(for: block)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
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
  private func gutter(for block: Block) -> some View {
    let label = HistoryDictationPresentation.clock(block.seconds ?? 0)
    ZStack(alignment: .leading) {
      // Reserves the widest label this card can need, so the text never moves.
      Text(verbatim: "▶ 00:00").font(.stHelper).hidden().accessibilityHidden(true)
      if let seconds = block.seconds {
        Button {
          onPlay(seconds)
        } label: {
          HStack(spacing: DesignSpacing.xxs) {
            Image(systemName: "play.fill")
              .font(.stHelper)
              .imageScale(.small)
              .accessibilityHidden(true)
            Text(verbatim: label).font(.stHelper).monospacedDigit()
          }
          .foregroundStyle(.stAccent)
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focused(focus, equals: .gutter(block.id))
        .opacity(revealGutter ? 1 : 0)
        .animation(reduceMotion ? nil : SettingsHover.animation, value: revealGutter)
        .accessibilityLabel(
          Text(
            "Play from \(label)",
            comment:
              "History dictation card: plays the recording from where this paragraph starts. %@ is a time like 0:07."
          ))
      }
    }
  }

  @ViewBuilder
  private func text(for block: Block) -> some View {
    switch block.content {
    case .plain(let text):
      Text(verbatim: text)
        .font(.stBody)
        .foregroundStyle(.stTextPrimary)
        .textSelection(.enabled)
    case .markedUp(let runs):
      Text(Self.attributed(runs))
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

  static func changeURL(_ index: Int) -> URL? {
    URL(string: "\(changeScheme):\(index)")
  }

  static func changeIndex(from url: URL) -> Int? {
    guard url.scheme == changeScheme else { return nil }
    return Int(url.absoluteString.dropFirst(changeScheme.count + 1))
  }

  static func attributed(_ runs: [HistoryDictationPresentation.MarkRun]) -> AttributedString {
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
      if let change = run.change, let url = changeURL(change) {
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
