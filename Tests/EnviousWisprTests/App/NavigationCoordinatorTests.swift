import Testing

@testable import EnviousWisprAppKit

/// Issue #765 (PR2 of epic #763) — pins the `NavigationCoordinator` contract
/// that was extracted from the former root state.
@MainActor
@Suite("NavigationCoordinator — pending settings tab handoff", .tags(.productOutcome))
struct NavigationCoordinatorTests {

  @Test("initial pending destination is nil")
  func initialPendingDestinationIsNil() {
    let coordinator = NavigationCoordinator()
    #expect(coordinator.pendingDestination == nil)
  }

  @Test("request sets pending destination")
  func requestSetsPendingDestination() {
    let coordinator = NavigationCoordinator()
    coordinator.request(.appSettings(.permissions))
    #expect(coordinator.pendingDestination == .appSettings(.permissions))
  }

  @Test("consume clears pending destination")
  func consumeClearsPending() {
    let coordinator = NavigationCoordinator()
    coordinator.request(.dictation(.engine))
    coordinator.consume()
    #expect(coordinator.pendingDestination == nil)
  }

  @Test("request replaces a prior unconsumed value")
  func requestReplacesPriorUnconsumed() {
    let coordinator = NavigationCoordinator()
    coordinator.request(.dictation(.engine))
    coordinator.request(.appSettings(.permissions))
    #expect(coordinator.pendingDestination == .appSettings(.permissions))
  }

  @Test("consume when nil is a no-op")
  func consumeWhenNilIsNoop() {
    let coordinator = NavigationCoordinator()
    coordinator.consume()
    #expect(coordinator.pendingDestination == nil)
  }
}
