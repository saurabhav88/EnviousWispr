import Testing

@testable import EnviousWisprAppKit

/// Issue #765 (PR2 of epic #763) — pins the `NavigationCoordinator` contract
/// that was extracted from the former root state.
@MainActor
@Suite("NavigationCoordinator — pending settings tab handoff")
struct NavigationCoordinatorTests {

  @Test("initial pending section is nil")
  func initialPendingSectionIsNil() {
    let coordinator = NavigationCoordinator()
    #expect(coordinator.pendingSection == nil)
  }

  @Test("request sets pending section")
  func requestSetsPendingSection() {
    let coordinator = NavigationCoordinator()
    coordinator.request(.permissions)
    #expect(coordinator.pendingSection == .permissions)
  }

  @Test("consume clears pending section")
  func consumeClearsPending() {
    let coordinator = NavigationCoordinator()
    coordinator.request(.speechEngine)
    coordinator.consume()
    #expect(coordinator.pendingSection == nil)
  }

  @Test("request replaces a prior unconsumed value")
  func requestReplacesPriorUnconsumed() {
    let coordinator = NavigationCoordinator()
    coordinator.request(.speechEngine)
    coordinator.request(.permissions)
    #expect(coordinator.pendingSection == .permissions)
  }

  @Test("consume when nil is a no-op")
  func consumeWhenNilIsNoop() {
    let coordinator = NavigationCoordinator()
    coordinator.consume()
    #expect(coordinator.pendingSection == nil)
  }
}
