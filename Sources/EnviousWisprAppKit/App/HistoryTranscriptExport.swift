import CoreTransferable
import EnviousWisprCore
import Foundation
import UniformTypeIdentifiers

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

/// Defers reading the export text to whenever the system actually asks for the data, rather
/// than whenever SwiftUI last evaluated `body` (found by chunk review) — `resolve` closes
/// over `transcriptCoordinator` (a reference) and re-reads `exportText`'s own live,
/// expiry-checked selection at that later point, the same delivery-time validation Save gets
/// from being read after its modal returns.
// Module-internal so regression tests can cross the real CoreTransferable boundary.
struct DeliverableText: Transferable, Sendable {
  // #3566: the system requests data away from the UI executor. The resolver reads
  // MainActor-owned History state, so its type must preserve that isolation.
  let resolve: @MainActor @Sendable () -> String?

  /// A `nil` resolve must REFUSE delivery, never substitute empty content (found by chunk
  /// review): `Data("".utf8)` reads to the receiving app as a successful, if empty, export —
  /// exactly the silent "expiry reads as success" failure `textForDelivery`'s own contract
  /// exists to prevent.
  struct ExpiredError: Error {}

  @MainActor
  func exportData() throws -> Data {
    guard let text = resolve() else { throw ExpiredError() }
    return Data(text.utf8)
  }

  static var transferRepresentation: some TransferRepresentation {
    DataRepresentation(exportedContentType: .plainText) { deliverable in
      try await deliverable.exportData()
    }
  }
}
