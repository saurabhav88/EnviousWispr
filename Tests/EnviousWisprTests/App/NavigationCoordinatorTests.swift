import EnviousWisprAppKitTestSupport
import Foundation
import Testing

@testable import EnviousWisprAppKit

/// Issue #765 (PR2 of epic #763) — pins the `NavigationCoordinator` contract
/// that was extracted from the former root state.
@MainActor
@Suite("NavigationCoordinator — pending settings tab handoff", .tags(.productOutcome))
struct NavigationCoordinatorTests {

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

  @Test("A share survives until its matching navigation commits")
  func shareOnlyReachesItsOwnCommit() throws {
    let folder = TestTemporaryDirectory.url
      .appendingPathComponent(UUID().uuidString)
      .resolvingSymlinksInPath()
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let fixture = folder.appendingPathComponent("sample.m4a")
    try Data([1, 2, 3]).write(to: fixture)
    let transfer = SharedMediaTransfer(root: folder.appendingPathComponent("Inbox"))
    let receiver = folder.appendingPathComponent("App.app")
    let first = try transfer.offer(fixture, suffix: "m4a", suggestedName: nil, receiver: receiver)
    let second = try transfer.offer(fixture, suffix: "m4a", suggestedName: nil, receiver: receiver)
    let accepted = try #require(transfer.claim(first, receiver: receiver))
    let extra = try #require(transfer.claim(second, receiver: receiver))
    let coordinator = NavigationCoordinator()
    #expect(coordinator.requestSharedMedia(accepted))
    #expect(coordinator.requestSharedMedia(extra) == false)
    #expect(coordinator.takeSharedMedia(matching: extra.url) == nil)
    #expect(coordinator.takeSharedMedia(matching: accepted.url) === accepted)
    #expect(coordinator.takeSharedMedia(matching: accepted.url) == nil)

    #expect(coordinator.requestSharedMedia(extra))
    coordinator.request(.appSettings(.permissions))
    #expect(coordinator.takeSharedMedia(matching: extra.url) == nil)
  }

}
