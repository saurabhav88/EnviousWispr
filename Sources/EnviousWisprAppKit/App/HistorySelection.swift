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
  /// Targets of the deletion running now. They stay selected while their outcomes settle, even
  /// when their text leaves the list first (Codex PR2 r5).
  private var pendingTargets: Set<HistoryItemID> = []
  /// Items whose deletion failed, with the kind that failed. They stay selected and retryable
  /// even when their text row is already gone (text removed, audio cleanup failed), until a
  /// retry succeeds or the person unticks them. A list disappearance is never read as success.
  private(set) var retryKinds: [HistoryItemID: HistoryDeleteKind] = [:]
  /// Advanced by `clear()`: a deletion started under an older epoch may finish its storage
  /// commands but never changes the newer selection, retry state or summary (Codex PR2 r6).
  private var epoch = 0

  /// Ticks `id` when it is not selected, else unticks it.
  func toggle(_ id: HistoryItemID) {
    if selectedIDs.contains(id) {
      selectedIDs.remove(id)
      retryKinds[id] = nil
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
    retryKinds = [:]
    pendingTargets = []
    epoch &+= 1
  }

  /// Drops selected items that the tab no longer lists (deleted elsewhere, expired, or hidden by
  /// a changed search or filter), so a deletion never acts on an item the person cannot see.
  /// A deletion target still settling, and an item whose deletion failed, stay selected.
  func retain(_ listed: Set<HistoryItemID>) {
    let keep = listed.union(pendingTargets).union(retryKinds.keys)
    guard selectedIDs.isSubset(of: keep) == false else { return }
    selectedIDs.formIntersection(keep)
    if let anchorID, keep.contains(anchorID) == false { self.anchorID = nil }
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
    let started = epoch
    // Frozen before the first await: each target with its kind (a failed item retries with
    // the kind that failed, since its text may already be gone).
    let targets = selectedIDs.map { (id: $0, kind: retryKinds[$0] ?? kind) }
    pendingTargets = Set(targets.map(\.id))
    defer {
      isDeleting = false
      if epoch == started { pendingTargets = [] }
    }
    var summary = DeletionSummary()
    for target in targets {
      let outcome = await delete(target.id, target.kind)
      // A clear() while this awaited ends this deletion's say over the selection.
      guard epoch == started else { continue }
      switch outcome {
      case .removed, .alreadyAbsent:
        summary.removed += 1
        selectedIDs.remove(target.id)
        retryKinds[target.id] = nil
        if anchorID == target.id { anchorID = nil }
      case .skipped:
        summary.skipped += 1
      case .failed:
        summary.failed += 1
        // An item unticked while it was deleting stays dismissed.
        if selectedIDs.contains(target.id) { retryKinds[target.id] = target.kind }
      }
    }
    guard epoch == started else { return }
    lastDeletion = summary
  }
}
