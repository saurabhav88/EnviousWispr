import EnviousWisprCore
import Foundation

/// What an imported transcript's Copy, Share, Save and Paste hand over (#3147 PR3), extracted
/// from the legacy `TranscriptDetailView` so the new transcript view keeps the same rules.
/// Both read the LIVE row by id at the moment of delivery; nil for a row that is gone.
@MainActor
enum HistoryTranscriptExport {
  /// Copy, Share and Save: a turn-labelled document through the presenter (its labels, Times
  /// and view mode), else `textForDelivery`'s expiry-checked selection, unchanged.
  static func text(
    rowID: UUID, coordinator: TranscriptCoordinator, mode: FileImportCoordinator.DocumentView,
    timesOn: Bool
  ) -> String? {
    guard let live = coordinator.currentRow(id: rowID) else { return nil }
    guard let base = coordinator.textForDelivery(live) else { return nil }
    if let turns = live.turns,
      let result = TranscriptDocumentPresenter.exportText(
        turns: turns, rawText: live.text, speakerNames: live.speakerNames ?? [:],
        timesOn: timesOn, mode: mode)
    {
      return result.text
    }
    return base
  }

  /// Paste: the plain delivery text (`textForDelivery`), never the mode-sensitive export.
  static func pasteText(rowID: UUID, coordinator: TranscriptCoordinator) -> String? {
    guard let live = coordinator.currentRow(id: rowID) else { return nil }
    return coordinator.textForDelivery(live)
  }
}
