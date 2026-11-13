import EnviousWisprCore
import EnviousWisprServices
import SwiftUI

/// History's one help panel (#3147 §3.3), opened from the `?` beside the filters. Each tab gets
/// the items that are true for it in this release; Polish again is left out until it ships
/// (§3.8 PR6), and the recording line reads the real retention setting.
struct HistoryHelpPopover: View {
  let tab: HistoryTab
  @Environment(SettingsManager.self) private var settings

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("How History works", comment: "History help: the panel's title.")
        .font(.stRowTitle)
        .foregroundStyle(.stTextPrimary)
      ForEach(HistoryHelpContent.items(for: tab, retention: settings.dictationRecordingRetention)) {
        item in
        HStack(alignment: .top, spacing: 10) {
          Image(systemName: item.icon)
            .foregroundStyle(.stAccent)
            .frame(width: 20)
            .accessibilityHidden(true)
          VStack(alignment: .leading, spacing: 2) {
            Text(item.title)
              .font(.stRowLabel)
              .foregroundStyle(.stTextPrimary)
            Text(item.body)
              .font(.stHelper)
              .foregroundStyle(.stTextSecondary)
              .fixedSize(horizontal: false, vertical: true)
          }
        }
        .accessibilityElement(children: .combine)
      }
    }
    .frame(width: 340, alignment: .leading)
  }
}

/// The help panel's items as plain values, so each tab's list is tested without a view.
enum HistoryHelpContent {
  struct Item: Identifiable, Equatable {
    let icon: String
    let title: String
    let body: String
    var id: String { title }
  }

  static func items(for tab: HistoryTab, retention: DictationRecordingRetention) -> [Item] {
    switch tab {
    case .dictations:
      return [play, playFromParagraph, showEdits, recordings(retention), search, select]
    case .transcripts, .meetings:
      return [open(tab), search, select]
    }
  }

  private static let play = Item(
    icon: "play.circle",
    title: String(localized: "Play your recording", comment: "History help: item title."),
    body: String(
      localized:
        "Press play, or drag along the wave to jump. The left number is where you are, the right number is the length.",
      comment: "History help: how the dictation player works."))

  private static let playFromParagraph = Item(
    icon: "clock",
    title: String(localized: "Play from a paragraph", comment: "History help: item title."),
    body: String(
      localized:
        "When a recording has times, point at a paragraph to see when you said it, or Tab to it. Click the time to hear that part.",
      comment: "History help: the time beside each paragraph of a dictation."))

  private static let showEdits = Item(
    icon: "pencil.and.list.clipboard",
    title: String(localized: "Show edits", comment: "History help: item title."),
    body: String(
      localized:
        "See what AI Polish changed. Click a marked word to compare your words before AI polish with the polished words, or hear it. Your words before AI polish can include the speech engine's own mistakes.",
      comment:
        "History help: what Show edits does. Never say the original is exactly what the person said."
    ))

  private static func recordings(_ retention: DictationRecordingRetention) -> Item {
    let kept: String
    switch retention {
    case .day1:
      kept = String(
        localized:
          "Audio is not uploaded. Dictation recordings are kept for 1 day unless you choose Keep this recording. Change this in Settings > Recordings.",
        comment: "History help: where recordings are stored and for how long (1 day).")
    case .day7:
      kept = String(
        localized:
          "Audio is not uploaded. Dictation recordings are kept for 7 days unless you choose Keep this recording. Change this in Settings > Recordings.",
        comment: "History help: where recordings are stored and for how long (7 days).")
    case .day30:
      kept = String(
        localized:
          "Audio is not uploaded. Dictation recordings are kept for 30 days unless you choose Keep this recording. Change this in Settings > Recordings.",
        comment: "History help: where recordings are stored and for how long (30 days).")
    case .forever:
      kept = String(
        localized:
          "Audio is not uploaded. Dictation recordings are kept until you delete them. Change this in Settings > Recordings.",
        comment: "History help: where recordings are stored; they are kept until deleted.")
    }
    return Item(
      icon: "lock",
      title: String(
        localized: "Recordings are stored on this Mac", comment: "History help: item title."),
      body: kept)
  }

  private static func open(_ tab: HistoryTab) -> Item {
    Item(
      icon: "chevron.right",
      title: tab == .transcripts
        ? String(localized: "Open a transcript", comment: "History help: item title.")
        : String(localized: "Open a meeting", comment: "History help: item title."),
      body: String(
        localized: "Click a card to open it. Back returns to the list where you were.",
        comment: "History help: opening a transcript or meeting and coming back."))
  }

  private static let search = Item(
    icon: "magnifyingglass",
    title: String(localized: "Search and filters", comment: "History help: item title."),
    body: String(
      localized:
        "Each tab keeps its own search and filters. Pick a day in the date filter; a dot marks days with items.",
      comment: "History help: search and filters are per tab; dots in the date picker."))

  private static let select = Item(
    icon: "checkmark.circle",
    title: String(localized: "Delete several at once", comment: "History help: item title."),
    body: String(
      localized:
        "Choose Select, then tick items, Shift-click for a range, or use Select day or Select all matching. Anything that could not be deleted stays ticked.",
      comment: "History help: selection mode and bulk deletion."))
}
