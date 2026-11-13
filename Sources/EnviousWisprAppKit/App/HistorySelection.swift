import Foundation

/// The History items a person has ticked in selection mode (#3147 §3.4), and the bulk deletion
/// that acts on them.
///
/// Select day and Select all matching take their IDs from the coordinator's full matching list
/// (`matchingHistoryItems(in:)`), never from the drawn page, so an item on a page not yet loaded
/// is still selected. Deletion freezes its targets when it starts, deletes each one through the
/// coordinator's per-item command, and keeps every item that was skipped or failed selected, so
/// the person sees exactly what is left. It never calls the global Delete all.
@MainActor
@Observable
final class HistorySelection {
  /// What one bulk deletion did, counted per item by its owner's reported outcome.
  struct DeletionSummary: Equatable, Sendable {
    /// Items the owner removed, or that were already gone.
    var removed = 0
    /// Items the owner kept on purpose (for example a meeting still recording).
    var skipped = 0
    /// Items the owner tried and could not remove.
    var failed = 0

    /// Items still selected because of this deletion.
    var kept: Int { skipped + failed }
  }

  private(set) var selectedIDs: Set<HistoryItemID> = []
  /// The item a Shift-click range starts from: the last item ticked or unticked on its own.
  private(set) var anchorID: HistoryItemID?
  /// True while a bulk deletion runs; a second one is refused until it ends.
  private(set) var isDeleting = false
  /// The last bulk deletion's result, until the selection changes again.
  private(set) var lastDeletion: DeletionSummary?

  /// Ticks `id` when it is not selected, else unticks it.
  func toggle(_ id: HistoryItemID) {
    if selectedIDs.contains(id) {
      selectedIDs.remove(id)
    } else {
      selectedIDs.insert(id)
    }
    anchorID = id
    lastDeletion = nil
  }

  /// Shift-click: selects every item from the anchor to `id` in the order the list shows them.
  /// With no anchor, or an anchor no longer listed, it ticks `id` alone.
  func extend(to id: HistoryItemID, in ordered: [HistoryItemID]) {
    guard let anchorID, let from = ordered.firstIndex(of: anchorID),
      let to = ordered.firstIndex(of: id)
    else {
      selectedIDs.insert(id)
      self.anchorID = id
      lastDeletion = nil
      return
    }
    selectedIDs.formUnion(ordered[min(from, to)...max(from, to)])
    lastDeletion = nil
  }

  /// Adds `ids` to the selection (Select day, Select all matching).
  func select(_ ids: Set<HistoryItemID>) {
    selectedIDs.formUnion(ids)
    lastDeletion = nil
  }

  /// Unticks everything.
  func clear() {
    selectedIDs = []
    anchorID = nil
    lastDeletion = nil
  }

  /// Drops selected items that the tab no longer lists (deleted elsewhere, expired, or hidden by
  /// a changed search or filter), so a deletion never acts on an item the person cannot see.
  func retain(_ listed: Set<HistoryItemID>) {
    guard selectedIDs.isSubset(of: listed) == false else { return }
    selectedIDs.formIntersection(listed)
    if let anchorID, listed.contains(anchorID) == false { self.anchorID = nil }
  }

  /// Deletes the selected items through `coordinator`, one owner command per item.
  func deleteSelected(kind: HistoryDeleteKind, coordinator: TranscriptCoordinator) async {
    await deleteSelected(kind: kind) { id, kind in
      await coordinator.deleteHistoryItem(id: id, kind: kind)
    }
  }

  /// The deletion itself, with the per-item command injected so tests can drive every outcome.
  /// Targets are frozen at the start; ticks made while it runs are kept.
  func deleteSelected(
    kind: HistoryDeleteKind,
    using delete: (HistoryItemID, HistoryDeleteKind) async -> HistoryDeleteOutcome
  ) async {
    guard isDeleting == false, selectedIDs.isEmpty == false else { return }
    isDeleting = true
    defer { isDeleting = false }
    let targets = selectedIDs
    var summary = DeletionSummary()
    for id in targets {
      switch await delete(id, kind) {
      case .removed, .alreadyAbsent:
        summary.removed += 1
        selectedIDs.remove(id)
        if anchorID == id { anchorID = nil }
      case .skipped:
        summary.skipped += 1
      case .failed:
        summary.failed += 1
      }
    }
    lastDeletion = summary
  }
}
