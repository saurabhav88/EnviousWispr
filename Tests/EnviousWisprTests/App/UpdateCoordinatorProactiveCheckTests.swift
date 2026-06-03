import EnviousWisprCore
import EnviousWisprServices
import Foundation
import Testing

@testable import EnviousWisprAppKit

/// Issue #958 — unit tests for `UpdateCoordinator.checkForUpdatesProactively`
/// (cooldown gate + auto-checks guard) and `checkForUpdatesFromSettings`
/// (source tagging).
///
/// `SPUUpdater` is not test-constructible (`init NS_UNAVAILABLE`), so the
/// proactive method takes a `probe:` seam (`ProactiveUpdaterProbe`). These
/// tests inject `FakeProactiveUpdater` and drive the clock via `now:`. The
/// `UpdateCoordinator` is built with `updaterController: nil`; the probe
/// override supplies the updater for the proactive path.
@MainActor
@Suite("UpdateCoordinator proactive checks", .serialized)
struct UpdateCoordinatorProactiveCheckTests {

  /// Fake satisfying the narrow `ProactiveUpdaterProbe` seam.
  @MainActor
  final class FakeProactiveUpdater: ProactiveUpdaterProbe {
    var automaticallyChecksForUpdates: Bool
    var lastUpdateCheckDate: Date?
    var sessionInProgress: Bool
    private(set) var backgroundCheckCount = 0

    init(autoChecks: Bool = true, lastCheck: Date? = nil, sessionInProgress: Bool = false) {
      self.automaticallyChecksForUpdates = autoChecks
      self.lastUpdateCheckDate = lastCheck
      self.sessionInProgress = sessionInProgress
    }

    func checkForUpdatesInBackground() { backgroundCheckCount += 1 }
  }

  private func makeCoordinator() -> UpdateCoordinator {
    // No real Sparkle controller; the proactive path uses the injected probe,
    // and `checkForUpdatesFromSettings` is a no-op call against a nil updater
    // (we only assert the source tag it sets).
    UpdateCoordinator(updaterController: nil)
  }

  // MARK: - Cooldown gate

  @Test("fires when the updater has never checked (lastUpdateCheckDate nil)")
  func firesWhenNeverChecked() {
    let coordinator = makeCoordinator()
    let fake = FakeProactiveUpdater(autoChecks: true, lastCheck: nil)

    let fired = coordinator.checkForUpdatesProactively(trigger: "launch", probe: fake)

    #expect(fired == true)
    #expect(fake.backgroundCheckCount == 1)
  }

  @Test("fires at exactly the cooldown boundary (elapsed == 3600)")
  func firesAtCooldownBoundary() {
    let coordinator = makeCoordinator()
    let now = Date(timeIntervalSince1970: 1_000_000)
    let fake = FakeProactiveUpdater(
      autoChecks: true,
      lastCheck: now.addingTimeInterval(-UpdateCoordinator.proactiveCheckCooldown))

    let fired = coordinator.checkForUpdatesProactively(trigger: "foreground", now: now, probe: fake)

    #expect(fired == true)
    #expect(fake.backgroundCheckCount == 1)
  }

  @Test("skips just below the cooldown boundary (elapsed == 3599)")
  func skipsJustBelowCooldown() {
    let coordinator = makeCoordinator()
    let now = Date(timeIntervalSince1970: 1_000_000)
    let fake = FakeProactiveUpdater(
      autoChecks: true,
      lastCheck: now.addingTimeInterval(-(UpdateCoordinator.proactiveCheckCooldown - 1)))

    let fired = coordinator.checkForUpdatesProactively(trigger: "foreground", now: now, probe: fake)

    #expect(fired == false)
    #expect(fake.backgroundCheckCount == 0)
  }

  // MARK: - Auto-checks opt-out guard (product choice)

  @Test("skips when automatic checks are off, regardless of elapsed time")
  func skipsWhenAutoChecksOff() {
    let coordinator = makeCoordinator()
    let now = Date(timeIntervalSince1970: 1_000_000)
    // Elapsed is effectively infinite (never checked), but the user opted out.
    let fake = FakeProactiveUpdater(autoChecks: false, lastCheck: nil)

    let fired = coordinator.checkForUpdatesProactively(trigger: "launch", now: now, probe: fake)

    #expect(fired == false)
    #expect(fake.backgroundCheckCount == 0)
  }

  // MARK: - Session-in-progress guard (truthful fired=false)

  @Test("skips when a Sparkle session is already in progress, even if cooldown elapsed")
  func skipsWhenSessionInProgress() {
    let coordinator = makeCoordinator()
    // Cooldown satisfied (never checked) but a session is already running, so
    // checkForUpdatesInBackground would no-op — must NOT claim fired=true.
    let fake = FakeProactiveUpdater(autoChecks: true, lastCheck: nil, sessionInProgress: true)

    let fired = coordinator.checkForUpdatesProactively(trigger: "foreground", probe: fake)

    #expect(fired == false)
    #expect(fake.backgroundCheckCount == 0)
  }

  // MARK: - No updater

  @Test("returns false when there is no updater (nil probe + nil controller)")
  func returnsFalseWithNoUpdater() {
    let coordinator = makeCoordinator()
    // probe defaults to nil; coordinator was built with updaterController: nil.
    let fired = coordinator.checkForUpdatesProactively(trigger: "launch")
    #expect(fired == false)
  }

  // MARK: - Settings attended check source tag

  @Test("checkForUpdatesFromSettings tags the install source 'settings'")
  func settingsCheckTagsSource() {
    let coordinator = makeCoordinator()
    #expect(coordinator.lastInstallSource == nil, "Precondition: no source yet.")
    coordinator.checkForUpdatesFromSettings()
    #expect(coordinator.lastInstallSource == "settings")
  }

  // MARK: - Telemetry (DEBUG-only testEventHook seam)

  #if DEBUG

    /// Sendable storage box for the `@Sendable` testEventHook closure.
    @MainActor final class EventBox { var events: [CapturedTelemetryEvent] = [] }

    @Test("emits proactive_check_triggered fired=true when it fires")
    func emitsTelemetryFiredTrue() async {
      let box = EventBox()
      let originalHook = TelemetryService.shared.testEventHook
      TelemetryService.shared.testEventHook = { @Sendable event in
        Task { @MainActor in box.events.append(event) }
      }
      defer { TelemetryService.shared.testEventHook = originalHook }

      let coordinator = makeCoordinator()
      let fake = FakeProactiveUpdater(autoChecks: true, lastCheck: nil)
      coordinator.checkForUpdatesProactively(trigger: "launch", probe: fake)

      await Task.yield()
      await Task.yield()

      let evt = box.events.first { $0.name == "update.proactive_check_triggered" }
      #expect(
        evt != nil, "Expected update.proactive_check_triggered. Got \(box.events.map(\.name)).")
      #expect(evt?.stringProps["trigger"] == "launch")
      #expect(evt?.stringProps["reason"] == "fired")
      #expect(evt?.boolProps["fired"] == true)
    }

    @Test("emits proactive_check_triggered fired=false when cooldown-skipped")
    func emitsTelemetryFiredFalseOnCooldownSkip() async {
      let box = EventBox()
      let originalHook = TelemetryService.shared.testEventHook
      TelemetryService.shared.testEventHook = { @Sendable event in
        Task { @MainActor in box.events.append(event) }
      }
      defer { TelemetryService.shared.testEventHook = originalHook }

      let coordinator = makeCoordinator()
      let now = Date(timeIntervalSince1970: 1_000_000)
      let fake = FakeProactiveUpdater(autoChecks: true, lastCheck: now.addingTimeInterval(-60))
      coordinator.checkForUpdatesProactively(trigger: "foreground", now: now, probe: fake)

      await Task.yield()
      await Task.yield()

      let evt = box.events.first { $0.name == "update.proactive_check_triggered" }
      #expect(evt != nil)
      #expect(evt?.stringProps["trigger"] == "foreground")
      #expect(evt?.stringProps["reason"] == "cooldown")
      #expect(evt?.boolProps["fired"] == false)
    }

  #endif  // DEBUG
}
