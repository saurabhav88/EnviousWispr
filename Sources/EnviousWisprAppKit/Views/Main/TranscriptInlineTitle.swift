import EnviousWisprCore
import SwiftUI

/// An imported transcript's title, renamed in place on the Transcripts card and page (#4611).
/// The editing is `HistoryInlineTitle`, shared with meetings; this wrapper supplies the row's
/// title (`HistoryTranscriptPresentation.title(for:)`: the custom name, else the file name)
/// and its one rename owner, `TranscriptCoordinator.renameTitle(id:title:)`. Until the row is
/// loaded the catalog's `fallbackTitle` shows, without rename controls.
struct TranscriptInlineTitle: View {
  let rowID: UUID
  let fallbackTitle: String
  var font: Font = .stRowTitle
  /// Set to true by the owner (Rename in More) to open the field; reset by the shared title.
  var beginRequest: Binding<Bool> = .constant(false)
  var searchQuery = ""
  var isEditing: Binding<Bool> = .constant(false)
  var clickAwayStamp: Binding<TimeInterval?> = .constant(nil)

  @Environment(TranscriptCoordinator.self) private var transcripts

  var body: some View {
    let row = transcripts.currentRow(id: rowID)
    HistoryInlineTitle(
      identity: rowID, title: row.map(HistoryTranscriptPresentation.title(for:)) ?? fallbackTitle,
      canRename: row?.isImported == true,
      renameHelp: Self.renameHelp,
      fieldLabel: String(
        localized: "Transcript name", comment: "History transcript: the rename field's placeholder."),
      storedTitle: { [transcripts, rowID] in transcripts.currentRow(id: rowID)?.customTitle },
      rename: { [transcripts, rowID] title in await transcripts.renameTitle(id: rowID, title: title) },
      font: font, truncation: .middle, beginRequest: beginRequest, searchQuery: searchQuery,
      isEditing: isEditing, clickAwayStamp: clickAwayStamp)
  }

  static var renameHelp: String {
    String(
      localized: "Rename transcript",
      comment: "History transcript: tooltip and VoiceOver label of the title's rename control.")
  }
}
