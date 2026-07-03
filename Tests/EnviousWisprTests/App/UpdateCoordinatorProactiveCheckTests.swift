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

  /// #1019 — fake `UpdateNotifying` so the once-per-version notification path is
  /// observable without touching `UNUserNotificationCenter`.
  @MainActor
  final class FakeNotifier: UpdateNotifying {
    var onInstallTapped: (() -> Void)?
    private(set) var posted: [String] = []
    private(set) var tapRoutingActivations = 0
    func post(displayVersion: String) { posted.append(displayVersion) }
    func activateTapRouting() { tapRoutingActivations += 1 }
  }

  private func makeCoordinator() -> UpdateCoordinator {
    // No real Sparkle controller; the proactive path uses the injected probe,
    // and `checkForUpdatesFromSettings` is a no-op call against a nil updater
    // (we only assert the source tag it sets). Ephemeral defaults so the
    // once-per-version notification marker never leaks across tests.
    UpdateCoordinator(updaterController: nil, defaults: ephemeralDefaults())
  }

  private func makeCoordinator(notifier: FakeNotifier) -> UpdateCoordinator {
    UpdateCoordinator(updaterController: nil, defaults: ephemeralDefaults(), notifier: notifier)
  }

  private func ephemeralDefaults() -> UserDefaults {
    let suite = "issue1019-tests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    return defaults
  }

  private func availableUpdate(_ version: String, critical: Bool = false)
    -> UpdateAvailabilityService.AvailableUpdate
  {
    UpdateAvailabilityService.AvailableUpdate(
      versionString: version, displayVersion: version, isCriticalUpdate: critical)
  }

  // MARK: - Cooldown gate (launch — Sparkle check-date anchored)

  @Test("launch fires when the updater has never checked (lastUpdateCheckDate nil)")
  func firesWhenNeverChecked() {
    let coordinator = makeCoordinator()
    let fake = FakeProactiveUpdater(autoChecks: true, lastCheck: nil)

    let fired = coordinator.checkForUpdatesProactively(trigger: "launch", probe: fake)

    #expect(fired == true)
    #expect(fake.backgroundCheckCount == 1)
  }

  @Test("launch fires at exactly the Sparkle cooldown boundary (elapsed == 3600)")
  func launchFiresAtCooldownBoundary() {
    let coordinator = makeCoordinator()
    let now = Date(timeIntervalSince1970: 1_000_000)
    let fake = FakeProactiveUpdater(
      autoChecks: true,
      lastCheck: now.addingTimeInterval(-UpdateCoordinator.proactiveCheckCooldown))

    let fired = coordinator.checkForUpdatesProactively(trigger: "launch", now: now, probe: fake)

    #expect(fired == true)
    #expect(fake.backgroundCheckCount == 1)
  }

  @Test("launch skips just below the Sparkle cooldown boundary (elapsed == 3599)")
  func launchSkipsJustBelowCooldown() {
    let coordinator = makeCoordinator()
    let now = Date(timeIntervalSince1970: 1_000_000)
    let fake = FakeProactiveUpdater(
      autoChecks: true,
      lastCheck: now.addingTimeInterval(-(UpdateCoordinator.proactiveCheckCooldown - 1)))

    let fired = coordinator.checkForUpdatesProactively(trigger: "launch", now: now, probe: fake)

    #expect(fired == false)
    #expect(fake.backgroundCheckCount == 0)
  }

  // MARK: - Outcome-aware cooldown (#1019 — foreground / wake / network)

  @Test("event-driven trigger fires when no successful outcome recorded yet")
  func eventTriggerFiresWithNoOutcome() {
    let coordinator = makeCoordinator()
    // Sparkle's check-date is recent, but event-driven triggers ignore it.
    let now = Date(timeIntervalSince1970: 1_000_000)
    let fake = FakeProactiveUpdater(autoChecks: true, lastCheck: now.addingTimeInterval(-60))

    let fired = coordinator.checkForUpdatesProactively(trigger: "wake", now: now, probe: fake)

    #expect(fired == true)
    #expect(fake.backgroundCheckCount == 1)
  }

  @Test("event-driven trigger fires at the 30-min outcome boundary")
  func eventTriggerFiresAtOutcomeBoundary() {
    let coordinator = makeCoordinator()
    let now = Date(timeIntervalSince1970: 1_000_000)
    coordinator.recordUpdateCheckOutcome(
      success: true, at: now.addingTimeInterval(-UpdateCoordinator.foregroundCheckCooldown))
    let fake = FakeProactiveUpdater(autoChecks: true, lastCheck: nil)

    let fired = coordinator.checkForUpdatesProactively(trigger: "network", now: now, probe: fake)

    #expect(fired == true)
    #expect(fake.backgroundCheckCount == 1)
  }

  @Test("event-driven trigger skips just below the 30-min outcome boundary")
  func eventTriggerSkipsJustBelowOutcomeBoundary() {
    let coordinator = makeCoordinator()
    let now = Date(timeIntervalSince1970: 1_000_000)
    coordinator.recordUpdateCheckOutcome(
      success: true, at: now.addingTimeInterval(-(UpdateCoordinator.foregroundCheckCooldown - 1)))
    let fake = FakeProactiveUpdater(autoChecks: true, lastCheck: nil)

    let fired = coordinator.checkForUpdatesProactively(trigger: "foreground", now: now, probe: fake)

    #expect(fired == false)
    #expect(fake.backgroundCheckCount == 0)
  }

  @Test("a failed outcome does NOT consume the event-driven cooldown")
  func failedOutcomeDoesNotConsumeCooldown() {
    let coordinator = makeCoordinator()
    let now = Date(timeIntervalSince1970: 1_000_000)
    // A check just failed — must not block the next wake/network re-check.
    coordinator.recordUpdateCheckOutcome(success: false, at: now.addingTimeInterval(-1))
    let fake = FakeProactiveUpdater(autoChecks: true, lastCheck: nil)

    let fired = coordinator.checkForUpdatesProactively(trigger: "wake", now: now, probe: fake)

    #expect(fired == true)
    #expect(fake.backgroundCheckCount == 1)
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

    @Test("emits proactive_check_triggered fired=true when it fires")
    func emitsTelemetryFiredTrue() async throws {
      let waiter = TelemetryEventWaiter()
      let originalHook = TelemetryService.shared.testEventHook
      TelemetryService.shared.testEventHook = { @Sendable event in
        MainActor.assumeIsolated { waiter.record(event) }
      }
      defer { TelemetryService.shared.testEventHook = originalHook }

      let coordinator = makeCoordinator()
      let fake = FakeProactiveUpdater(autoChecks: true, lastCheck: nil)
      coordinator.checkForUpdatesProactively(trigger: "launch", probe: fake)

      let evt = try await waiter.waitForEvent(named: "update.proactive_check_triggered")
      #expect(evt.stringProps["trigger"] == "launch")
      #expect(evt.stringProps["reason"] == "fired")
      #expect(evt.boolProps["fired"] == true)
    }

    @Test("emits proactive_check_triggered fired=false when cooldown-skipped")
    func emitsTelemetryFiredFalseOnCooldownSkip() async throws {
      let waiter = TelemetryEventWaiter()
      let originalHook = TelemetryService.shared.testEventHook
      TelemetryService.shared.testEventHook = { @Sendable event in
        MainActor.assumeIsolated { waiter.record(event) }
      }
      defer { TelemetryService.shared.testEventHook = originalHook }

      let coordinator = makeCoordinator()
      let now = Date(timeIntervalSince1970: 1_000_000)
      // #1019: foreground is outcome-aware — seed a recent successful outcome so
      // the gate skips on cooldown.
      coordinator.recordUpdateCheckOutcome(success: true, at: now.addingTimeInterval(-60))
      let fake = FakeProactiveUpdater(autoChecks: true, lastCheck: nil)
      coordinator.checkForUpdatesProactively(trigger: "foreground", now: now, probe: fake)

      let evt = try await waiter.waitForEvent(named: "update.proactive_check_triggered")
      #expect(evt.stringProps["trigger"] == "foreground")
      #expect(evt.stringProps["reason"] == "cooldown")
      #expect(evt.boolProps["fired"] == false)
    }

  #endif  // DEBUG

  // MARK: - Once-per-version notification (#1019)

  @Test("posts one notification per newly-available non-critical version")
  func notifiesOncePerVersion() {
    let notifier = FakeNotifier()
    let coordinator = makeCoordinator(notifier: notifier)

    coordinator.service.noteAvailable(availableUpdate("2.1.4"))
    coordinator.service.noteAvailable(availableUpdate("2.1.4"))  // same version → no re-fire
    #expect(notifier.posted == ["2.1.4"])

    coordinator.service.noteAvailable(availableUpdate("2.1.5"))  // newer → fires again
    #expect(notifier.posted == ["2.1.4", "2.1.5"])
  }

  @Test("rehydrated pending update fires the notification once on construction")
  func rehydratedPendingNotifiesOnce() {
    let defaults = ephemeralDefaults()
    // Persisted by a prior session, newer than the (test-bundle) current
    // version → rehydrate sets `.available` inside the service initializer,
    // before the coordinator's hook is wired.
    defaults.set("99.0.0", forKey: UpdateAvailabilityService.kPendingVersion)
    defaults.set("99.0.0", forKey: UpdateAvailabilityService.kPendingBuild)
    defaults.set(Date().timeIntervalSince1970, forKey: UpdateAvailabilityService.kPendingTimestamp)
    defaults.set(false, forKey: UpdateAvailabilityService.kPendingCritical)

    let notifier = FakeNotifier()
    let coordinator = UpdateCoordinator(
      updaterController: nil, defaults: defaults, notifier: notifier)

    #expect(coordinator.service.state == .available(availableUpdate("99.0.0")))
    #expect(notifier.posted == ["99.0.0"])
  }

  @Test("critical updates do not post a gentle notification")
  func criticalUpdatesDoNotNotify() {
    let notifier = FakeNotifier()
    let coordinator = makeCoordinator(notifier: notifier)

    coordinator.service.noteAvailable(availableUpdate("2.1.4", critical: true))

    #expect(notifier.posted.isEmpty)
  }

  // MARK: - Notification tap install guard (#1019 heart-path)

  @Test("notification tap installs when dictation is idle")
  func notificationTapInstallsWhenIdle() {
    let notifier = FakeNotifier()
    let coordinator = makeCoordinator(notifier: notifier)
    coordinator.dictationActiveProvider = { false }
    coordinator.service.noteAvailable(availableUpdate("2.1.4"))

    notifier.onInstallTapped?()

    #expect(coordinator.service.state == .resolving)
  }

  @Test("notification tap is a no-op while dictation is active")
  func notificationTapBlockedWhileDictating() {
    let notifier = FakeNotifier()
    let coordinator = makeCoordinator(notifier: notifier)
    coordinator.dictationActiveProvider = { true }
    coordinator.service.noteAvailable(availableUpdate("2.1.4"))

    notifier.onInstallTapped?()

    // State stays available — no install kicked off mid-dictation.
    #expect(coordinator.service.state == .available(availableUpdate("2.1.4")))
  }

  // MARK: - Menu install guard (#1019 heart-path)

  @Test("installFromMenu is a no-op while dictation is active")
  func menuInstallBlockedWhileDictating() {
    // Inject a fake notifier — `noteAvailable` fires the notification path, and
    // the real presenter would touch `UNUserNotificationCenter` in the test
    // bundle.
    let coordinator = makeCoordinator(notifier: FakeNotifier())
    coordinator.dictationActiveProvider = { true }
    coordinator.service.noteAvailable(availableUpdate("2.1.4"))

    coordinator.installFromMenu()

    #expect(coordinator.service.state == .available(availableUpdate("2.1.4")))
  }

  // MARK: - Eager notification tap-routing (#1029)

  @Test(
    "activateNotificationTapRouting forwards to the notifier on every call (the forwarder is a thin pass-through; idempotency lives in the presenter's delegate guard, not here)"
  )
  func activateTapRoutingForwards() {
    let notifier = FakeNotifier()
    let coordinator = makeCoordinator(notifier: notifier)

    coordinator.activateNotificationTapRouting()
    #expect(notifier.tapRoutingActivations == 1)

    // A second call forwards again — the coordinator does NOT dedupe; the real
    // presenter's `delegateInstalled` guard is what makes the underlying install
    // idempotent (Codex r1).
    coordinator.activateNotificationTapRouting()
    #expect(notifier.tapRoutingActivations == 2)
  }

  @Test("a notification tap routes to the guarded install when dictation is inactive")
  func notificationTapRoutesWhenIdle() {
    let notifier = FakeNotifier()
    let coordinator = makeCoordinator(notifier: notifier)
    coordinator.dictationActiveProvider = { false }
    coordinator.service.noteAvailable(availableUpdate("2.1.4"))

    notifier.onInstallTapped?()

    // Routed through the dictation guard → the install attempt is tagged from the
    // notification source (the guard did not block it).
    #expect(coordinator.lastInstallSource == "notification")
  }

  @Test(
    "a notification tap is a no-op when no update is available (stale-notification guard, #1029 Codex r2)"
  )
  func notificationTapIgnoredWhenNoUpdateAvailable() {
    let notifier = FakeNotifier()
    let coordinator = makeCoordinator(notifier: notifier)
    coordinator.dictationActiveProvider = { false }
    // No `noteAvailable` → state is not `.available` (a stale delivered
    // notification whose version is already installed). With the tap delegate
    // active on every launch, this path is now reachable; it must NOT kick off
    // a Sparkle check or churn the resolving state.

    notifier.onInstallTapped?()

    #expect(coordinator.lastInstallSource == nil)
    #expect(coordinator.service.state != .available(availableUpdate("2.1.4")))
  }
}
