import EnviousWisprServices
import Foundation
import Testing

@testable import EnviousWisprAppKit

/// When these fail, update dashboards lose the entry point that began the install.
/// No real updater, notification, clipboard, Keychain or app activation is used.
@MainActor
@Suite("Update attribution", .tags(.observabilityContract))
struct UpdateAttributionTests {
  private final class Notifier: UpdateNotifying {
    var onInstallTapped: (() -> Void)?
    func post(displayVersion: String) {}
    func activateTapRouting() {}
  }

  @Test("Gift check dispatches once, after attribution is assigned")
  func giftDispatchOrder() throws {
    let defaults = try #require(TestDefaults.suite("ew.attribution.\(UUID().uuidString)"))
    var sources: [String?] = []
    var coordinator: UpdateCoordinator!
    coordinator = UpdateCoordinator(
      updaterController: nil, defaults: defaults, notifier: Notifier(),
      attendedCheck: { sources.append(coordinator.lastInstallSource) })
    defer { coordinator = nil }
    coordinator.checkForUpdatesFromWhatsNew()
    #expect(sources == ["whats_new_menu"])
    #expect(coordinator.lastInstallSource == "whats_new_menu")
  }

  @Test(
    "User-initiated Sparkle presentation preserves every explicit entry point",
    arguments: ["whats_new_menu", "menu", "banner", "settings"])
  func attendedSource(source: String) throws {
    let defaults = try #require(TestDefaults.suite("ew.attribution.\(UUID().uuidString)"))
    let coordinator = UpdateCoordinator(
      updaterController: nil, defaults: defaults, notifier: Notifier())
    coordinator.lastInstallSource = source
    coordinator.noteSparkleShowingUpdate(userInitiated: true)
    #expect(coordinator.lastInstallSource == source)
  }

  @Test("Scheduled Sparkle presentation replaces stale source; unattributed attended UI is default")
  func sparkleOwnedSource() throws {
    let defaults = try #require(TestDefaults.suite("ew.attribution.\(UUID().uuidString)"))
    let coordinator = UpdateCoordinator(
      updaterController: nil, defaults: defaults, notifier: Notifier())
    coordinator.lastInstallSource = "whats_new_menu"
    coordinator.noteSparkleShowingUpdate(userInitiated: false)
    #expect(coordinator.lastInstallSource == "sparkle_default")
    coordinator.lastInstallSource = nil
    coordinator.noteSparkleShowingUpdate(userInitiated: true)
    #expect(coordinator.lastInstallSource == "sparkle_default")
  }

  @Test(
    "Persisted gift attempt retains its source across completed and cancelled launches",
    arguments: [true, false])
  func persistedOutcome(completed: Bool) throws {
    let defaults = try #require(TestDefaults.suite("ew.attribution.\(UUID().uuidString)"))
    let first = UpdateCoordinator(updaterController: nil, defaults: defaults, notifier: Notifier())
    first.checkForUpdatesFromWhatsNew()
    first.noteSparkleShowingUpdate(userInitiated: true)
    let source = try #require(first.lastInstallSource)
    first.recordInstallAttempt(version: "99.0.0", source: source)
    let relaunched = UpdateCoordinator(
      updaterController: nil, defaults: defaults, notifier: Notifier())
    let outcome = relaunched.evaluateLastInstallAttempt(
      currentBundleVersion: completed ? "99.0.0" : "98.0.0")
    #expect(
      outcome
        == (completed
          ? .completed(version: "99.0.0", source: "whats_new_menu")
          : .cancelled(version: "99.0.0", source: "whats_new_menu")))
    #expect(relaunched.evaluateLastInstallAttempt(currentBundleVersion: "99.0.0") == .none)
  }
}
