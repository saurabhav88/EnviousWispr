import EnviousWisprAppKitTestSupport
import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprAppKit
@testable import EnviousWisprStorage

/// History's selection mode (#3147 §3.4): what is ticked, Shift-click ranges, and bulk deletion
/// that keeps every item it could not remove ticked and never touches an item it was not given.
@MainActor
/// Class: `.productOutcome` — a bulk delete that removes the wrong items, loses track of the
/// ones that failed, or deletes items the person cannot see.
@Suite("History selection and bulk deletion (#3147)", .tags(.productOutcome))
struct HistorySelectionTests {
  private static func ids(_ count: Int) -> [HistoryItemID] {
    (0..<count).map { _ in .transcript(UUID()) }
  }

  /// A per-item delete command that answers from `outcomes` and records every call.
  @MainActor
  private final class FakeDelete {
    var outcomes: [HistoryItemID: HistoryDeleteOutcome] = [:]
    private(set) var calls: [(HistoryItemID, HistoryDeleteKind)] = []

    func run(_ id: HistoryItemID, _ kind: HistoryDeleteKind) async -> HistoryDeleteOutcome {
      calls.append((id, kind))
      return outcomes[id] ?? .removed
    }
  }

  @Test("toggle ticks and unticks one item and moves the range anchor to it")
  func toggle() {
    let selection = HistorySelection()
    let items = Self.ids(3)
    selection.toggle(items[0])
    selection.toggle(items[1])
    #expect(selection.selectedIDs == [items[0], items[1]])
    #expect(selection.anchorID == items[1])
    selection.toggle(items[0])
    #expect(selection.selectedIDs == [items[1]])
    #expect(selection.anchorID == items[0])
  }

  @Test("Shift-click ticks the whole range from the anchor, in either direction")
  func shiftClickRange() {
    let items = Self.ids(10)
    let down = HistorySelection()
    down.toggle(items[2])
    down.extend(to: items[5], in: items)
    #expect(down.selectedIDs == Set(items[2...5]))

    let up = HistorySelection()
    up.toggle(items[7])
    up.extend(to: items[4], in: items)
    #expect(up.selectedIDs == Set(items[4...7]))

    // With no anchor, Shift-click ticks only the item clicked, and becomes the anchor.
    let fresh = HistorySelection()
    fresh.extend(to: items[3], in: items)
    #expect(fresh.selectedIDs == [items[3]])
    #expect(fresh.anchorID == items[3])
  }

  @Test("Select day and Select all add to what is already ticked; clear unticks everything")
  func selectAddsAndClearEmpties() {
    let selection = HistorySelection()
    let items = Self.ids(6)
    selection.toggle(items[0])
    selection.select(Set(items[3...5]))
    #expect(selection.selectedIDs == Set([items[0]] + items[3...5]))
    selection.clear()
    #expect(selection.selectedIDs.isEmpty)
    #expect(selection.anchorID == nil)
  }

  @Test("items the tab no longer lists drop out of the selection")
  func retainDropsUnlisted() {
    let selection = HistorySelection()
    let items = Self.ids(4)
    selection.select(Set(items))
    selection.toggle(items[3])  // anchor on an item about to vanish; this unticks it
    selection.toggle(items[3])  // and ticks it again
    selection.retain(Set(items[0...1]))
    #expect(selection.selectedIDs == Set(items[0...1]))
    #expect(selection.anchorID == nil)
  }

  @Test("a deletion removes what succeeded and keeps skipped and failed items ticked")
  func partialFailureKeepsTheRest() async {
    let selection = HistorySelection()
    let items = Self.ids(5)
    let fake = FakeDelete()
    fake.outcomes = [
      items[0]: .removed, items[1]: .alreadyAbsent, items[2]: .skipped, items[3]: .failed,
      items[4]: .failed,
    ]
    selection.select(Set(items))
    await selection.deleteSelected(kind: .textAndRecordings, using: fake.run)

    #expect(selection.selectedIDs == Set(items[2...4]))
    #expect(selection.lastDeletion == .init(removed: 2, skipped: 1, failed: 2))
    #expect(selection.lastDeletion?.kept == 3)
    #expect(selection.isDeleting == false)
    // Every selected item got exactly one command, of the kind chosen.
    #expect(fake.calls.count == 5)
    #expect(Set(fake.calls.map(\.0)) == Set(items))
    #expect(fake.calls.allSatisfy { $0.1 == .textAndRecordings })
  }

  @Test("Delete recordings only passes its kind to every item")
  func recordingsOnlyKind() async {
    let selection = HistorySelection()
    let items = Self.ids(3)
    let fake = FakeDelete()
    selection.select(Set(items))
    await selection.deleteSelected(kind: .recordingsOnly, using: fake.run)
    #expect(fake.calls.count == 3)
    #expect(fake.calls.allSatisfy { $0.1 == .recordingsOnly })
    #expect(selection.selectedIDs.isEmpty)
  }

  @Test("an empty selection sends no command")
  func emptySelectionDeletesNothing() async {
    let selection = HistorySelection()
    let fake = FakeDelete()
    await selection.deleteSelected(kind: .textAndRecordings, using: fake.run)
    #expect(fake.calls.isEmpty)
    #expect(selection.lastDeletion == nil)
  }

  @Test("targets are frozen at the start: an item ticked during the deletion stays and is kept")
  func targetsAreFrozen() async {
    let selection = HistorySelection()
    let items = Self.ids(3)
    selection.select(Set(items[0...1]))
    var tickedDuring = false
    await selection.deleteSelected(kind: .textAndRecordings) { id, _ in
      if tickedDuring == false {
        tickedDuring = true
        selection.toggle(items[2])
      }
      return .removed
    }
    #expect(selection.selectedIDs == [items[2]])
  }

  @Test("a failed item stays ticked after its row leaves the list, and retries with the kind that failed")
  func failedItemSurvivesPruningAndRetries() async {
    let selection = HistorySelection()
    let items = Self.ids(2)
    selection.select(Set(items))
    let fake = FakeDelete()
    fake.outcomes[items[0]] = .failed
    await selection.deleteSelected(kind: .textAndRecordings, using: fake.run)
    // Its text left the list (text removed, audio cleanup failed): the prune keeps it.
    selection.retain([])
    #expect(selection.selectedIDs == [items[0]])
    #expect(selection.retryKinds[items[0]] == .textAndRecordings)

    // Retried under another chosen kind, it still uses the kind that failed; success clears it.
    fake.outcomes[items[0]] = .alreadyAbsent
    await selection.deleteSelected(kind: .recordingsOnly, using: fake.run)
    #expect(fake.calls.last.map { $0.1 } == .textAndRecordings)
    #expect(selection.selectedIDs.isEmpty)
    #expect(selection.retryKinds.isEmpty)
    selection.retain([])
    #expect(selection.selectedIDs.isEmpty)
  }

  @Test("targets stay ticked while their outcomes settle, even if the list drops them first")
  func pruneDuringDeletionKeepsTargets() async {
    let selection = HistorySelection()
    let items = Self.ids(2)
    selection.select(Set(items))
    await selection.deleteSelected(kind: .textAndRecordings) { id, _ in
      // The list redraws mid-deletion without either item.
      selection.retain([])
      #expect(selection.selectedIDs.isSuperset(of: Set(items).subtracting([items[0]])))
      return id == items[0] ? .removed : .failed
    }
    #expect(selection.selectedIDs == [items[1]])
  }

  @Test("unticking a failed item or clearing dismisses its retry")
  func untickDismissesRetry() async {
    let selection = HistorySelection()
    let items = Self.ids(1)
    selection.select(Set(items))
    let fake = FakeDelete()
    fake.outcomes[items[0]] = .failed
    await selection.deleteSelected(kind: .recordingsOnly, using: fake.run)
    selection.toggle(items[0])
    #expect(selection.retryKinds.isEmpty)
    selection.retain([])
    #expect(selection.selectedIDs.isEmpty)
  }

  @Test("a second deletion while one runs is refused and sends nothing")
  func secondDeletionIsRefused() async {
    let selection = HistorySelection()
    let items = Self.ids(2)
    selection.select(Set(items))
    var nestedCalls = 0
    var firstCalls = 0
    await selection.deleteSelected(kind: .textAndRecordings) { _, _ in
      firstCalls += 1
      if firstCalls == 1 {
        // The person presses Delete again while the first deletion is still running.
        #expect(selection.isDeleting)
        await selection.deleteSelected(kind: .recordingsOnly) { _, _ in
          nestedCalls += 1
          return .removed
        }
      }
      return .removed
    }
    #expect(nestedCalls == 0)
    #expect(firstCalls == 2)
    #expect(selection.selectedIDs.isEmpty)
  }

  @Test("Select all matching and Select day reach items on pages not yet drawn")
  func selectionReachesUndrawnPages() {
    let coordinator = TranscriptCoordinator(
      store: TranscriptStore(
        directory: TestTemporaryDirectory.url
          .appendingPathComponent("ew-3147-selection-\(UUID().uuidString)", isDirectory: true)))
    let calendar = Calendar.current
    let today = calendar.startOfDay(for: Date())
    // 75 dictations: 40 today (newest first, one minute apart), 35 yesterday.
    let rows = (0..<75).map { index -> Transcript in
      let day = index < 40 ? today : calendar.date(byAdding: .day, value: -1, to: today)!
      let createdAt = day.addingTimeInterval(TimeInterval(12 * 3600 - (index % 40) * 60))
      return Transcript(text: "row \(index)", createdAt: createdAt)
    }
    coordinator.setTranscriptsForTesting(rows)
    let matching = coordinator.matchingHistoryItems(in: .dictations)
    #expect(matching.count == 75)
    let drawn = HistoryPaging.window(
      items: matching, context: HistoryPaging.Context(tab: .dictations, state: HistoryTabState()),
      state: HistoryPaging.State(), selected: nil
    ).boundary
    #expect(drawn == 30)

    let yesterday = HistorySelection()
    yesterday.select(
      HistoryDiaryLayout.ids(
        onDayOf: calendar.date(byAdding: .day, value: -1, to: today)!, in: matching,
        calendar: calendar))
    #expect(yesterday.selectedIDs.count == 35, "every one of yesterday's items is past page 1")

    let all = HistorySelection()
    all.select(Set(matching.map(\.id)))
    #expect(all.selectedIDs.count == 75)
  }
}
