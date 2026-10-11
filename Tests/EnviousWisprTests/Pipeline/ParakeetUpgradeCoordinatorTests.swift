import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprPipeline

/// #3546 chunk 7a: the Parakeet selection-policy owner with no upgrade target.
/// If it breaks, dictation loads the wrong directory or mode, or a direct load
/// (crash recovery, file import) reads a request an earlier selection
/// published instead of the one the current selection chose.
@MainActor
@Suite("Parakeet upgrade coordinator", .tags(.productOutcome))
struct ParakeetUpgradeCoordinatorTests {

  @Test("with no handle, a preparation publishes the legacy v3 request")
  func noHandlePublishesLegacyRequest() async throws {
    let selection = ParakeetSelectionProvider()
    let coordinator = ParakeetUpgradeCoordinator(parakeetSelection: selection, delivery: nil)
    let prepared = try await coordinator.prepareLoad()
    guard let expected = ParakeetInstallLocation.directoryFromSystemApplicationSupport() else {
      #expect(prepared.selection == nil)
      #expect(selection.current == nil)
      return
    }
    let request = try #require(selection.current)
    #expect(prepared.selection == request)
    #expect(request.model == .v3)
    #expect(request.directory == expected)
    #expect(request.cacheOnly == false)
    #expect(request.repairable == false)
    #expect(request.displayBytes == 483_256_769)
  }

  @Test("a direct load with no pending selection point prepares nothing")
  func settleWithoutSelectionPointIsANoOp() async throws {
    let selection = ParakeetSelectionProvider()
    let coordinator = ParakeetUpgradeCoordinator(parakeetSelection: selection, delivery: nil)
    #expect(coordinator.hasPendingSelectionPoint == false)
    try await coordinator.settlePendingSelection()
    #expect(selection.current == nil)
  }

  @Test("a pending selection point is prepared before a direct load, and only once")
  func settlePreparesThePendingSelectionOnce() async throws {
    let selection = ParakeetSelectionProvider()
    let coordinator = ParakeetUpgradeCoordinator(parakeetSelection: selection, delivery: nil)
    coordinator.markSelectionPoint()
    coordinator.markSelectionPoint()  // a second launch poke coalesces
    #expect(coordinator.hasPendingSelectionPoint)
    try await coordinator.settlePendingSelection()
    #expect(coordinator.hasPendingSelectionPoint == false)
    let afterSettle = selection.current
    try await coordinator.settlePendingSelection()
    #expect(selection.current == afterSettle, "a settled point is not prepared again")
    if ParakeetInstallLocation.directoryFromSystemApplicationSupport() != nil {
      #expect(afterSettle?.generation == 1)
    }
  }

  @Test("a selection point marked after a preparation started stays pending")
  func laterSelectionPointIsNotConsumedEarly() async throws {
    let selection = ParakeetSelectionProvider()
    let coordinator = ParakeetUpgradeCoordinator(parakeetSelection: selection, delivery: nil)
    coordinator.markSelectionPoint()
    _ = try await coordinator.prepareLoad()
    coordinator.markSelectionPoint()
    #expect(coordinator.hasPendingSelectionPoint)
  }
}
