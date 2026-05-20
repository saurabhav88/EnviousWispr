import EnviousWisprCore
import EnviousWisprServices
import Foundation
import Testing

@testable import EnviousWispr

/// PR-B.1 of #763 — unit tests for `SparkleUpdateController`.
///
/// All tests use a fake `updaterFactory` returning `nil` so the real
/// `SPUStandardUpdaterController` never instantiates inside the test
/// process. The real one writes to `UserDefaults`, fetches the appcast
/// feed, and runs signing checks at init — none of that should boot
/// during `swift test`.
@MainActor
@Suite("SparkleUpdateController", .serialized)
struct SparkleUpdateControllerTests {

  // MARK: - Env-capture: synchronous publish into the holder

  @Test("startUpdater publishes coordinator into holder synchronously")
  func startUpdaterPublishesCoordinatorIntoHolderSynchronously() {
    let holder = UpdateCoordinatorHolder()
    let controller = SparkleUpdateController(
      holder: holder,
      bundleVersionProvider: { "v-test-1.0" },
      updaterFactory: SparkleUpdaterFactory { _, _ in nil }
    )

    #expect(holder.coordinator == nil, "Precondition: holder starts empty.")

    controller.startUpdater()

    // The publish MUST be synchronous. Issue #739 env-capture invariant:
    // no await, no Task, no DispatchQueue hop between `startUpdater()` and
    // the assertion below. SwiftUI's first scene-body evaluation runs on
    // the same call stack right after `applicationWillFinishLaunching`.
    #expect(
      holder.coordinator != nil,
      "startUpdater() must publish UpdateCoordinator into the holder synchronously.")
  }

  // MARK: - Idempotency contract

  @Test("startUpdater is idempotent (second call preserves first coordinator)")
  func startUpdaterIsIdempotent() {
    // Sendable storage box so the @Sendable assertionHandler closure can
    // ferry the captured message back onto the MainActor.
    @MainActor final class AssertionBox { var message: String? }
    let box = AssertionBox()

    // Neutralize the production `assertionFailure` so debug test runs do
    // not crash on the intentional second-call regression.
    let originalHandler = SparkleUpdateController.assertionHandler
    SparkleUpdateController.assertionHandler = { @Sendable message in
      Task { @MainActor in box.message = message }
    }
    defer { SparkleUpdateController.assertionHandler = originalHandler }

    let holder = UpdateCoordinatorHolder()
    let controller = SparkleUpdateController(
      holder: holder,
      bundleVersionProvider: { "v-test-1.0" },
      updaterFactory: SparkleUpdaterFactory { _, _ in nil }
    )

    controller.startUpdater()
    let firstCoordinator = controller.updateCoordinator
    #expect(firstCoordinator != nil, "First startUpdater must construct a coordinator.")

    controller.startUpdater()
    #expect(
      controller.updateCoordinator === firstCoordinator,
      "Second startUpdater must NOT replace the existing coordinator.")
  }

  // MARK: - Bundle-version-aware install-attempt evaluation

  // The next two tests rely on the DEBUG-only `testEventHook` seam, so they
  // compile only in debug. CI also builds tests in release; gating preserves
  // both lanes.
  #if DEBUG

    /// Sendable storage box for the testEventHook closure. The hook is
    /// `@Sendable`; storage stays MainActor-isolated.
    @MainActor final class EventBox { var events: [CapturedTelemetryEvent] = [] }

    @Test("evaluateInstallAttemptOnLaunch uses provided bundleVersionProvider")
    func evaluateInstallAttemptOnLaunchUsesProvidedBundleVersion() async {
      // Prime UserDefaults.standard with a `completed`-shaped install attempt
      // marker. UpdateCoordinator owns the key names; we replicate them here
      // because UpdateCoordinator constructs its own UserDefaults reference
      // and we cannot inject a suite without expanding the controller's
      // public surface beyond the PR-B.1 ceiling budget.
      let attemptVersion = "v-test-pr-b1-attempt"
      let defaults = UserDefaults.standard
      let kVersion = "com.enviouswispr.updateBanner.lastAttemptVersion"
      let kTimestamp = "com.enviouswispr.updateBanner.lastAttemptTimestamp"
      let kSource = "com.enviouswispr.updateBanner.lastAttemptSource"
      let snapshotVersion = defaults.string(forKey: kVersion)
      let snapshotTimestamp = defaults.double(forKey: kTimestamp)
      let snapshotSource = defaults.string(forKey: kSource)
      defaults.set(attemptVersion, forKey: kVersion)
      defaults.set(Date().timeIntervalSince1970, forKey: kTimestamp)
      defaults.set("menu", forKey: kSource)
      defer {
        if let v = snapshotVersion {
          defaults.set(v, forKey: kVersion)
        } else {
          defaults.removeObject(forKey: kVersion)
        }
        if snapshotTimestamp == 0 {
          defaults.removeObject(forKey: kTimestamp)
        } else {
          defaults.set(snapshotTimestamp, forKey: kTimestamp)
        }
        if let s = snapshotSource {
          defaults.set(s, forKey: kSource)
        } else {
          defaults.removeObject(forKey: kSource)
        }
      }

      let box = EventBox()
      let originalHook = TelemetryService.shared.testEventHook
      TelemetryService.shared.testEventHook = { @Sendable event in
        Task { @MainActor in box.events.append(event) }
      }
      defer { TelemetryService.shared.testEventHook = originalHook }

      let holder = UpdateCoordinatorHolder()
      let controller = SparkleUpdateController(
        holder: holder,
        // Provider returns the SAME version as the persisted attempt.
        // `evaluateLastInstallAttempt` should resolve to `.completed` and
        // fire `update.install_completed`.
        bundleVersionProvider: { attemptVersion },
        updaterFactory: SparkleUpdaterFactory { _, _ in nil }
      )

      controller.startUpdater()

      // Let the Task hop deliver the captured event onto MainActor storage.
      await Task.yield()

      let captured = box.events
      #expect(
        captured.contains(where: { $0.name == "update.install_completed" }),
        """
        Expected `update.install_completed` to fire because the persisted attempt \
        version matches the bundleVersionProvider's return. Captured: \
        \(captured.map(\.name)).
        """
      )
      if let completed = captured.first(where: { $0.name == "update.install_completed" }) {
        #expect(completed.stringProps["version"] == attemptVersion)
        #expect(completed.stringProps["source"] == "menu")
      }
    }

    // MARK: - Telemetry call-site parity

    @Test("Sparkle telemetry methods fire testEventHook with expected names and keys")
    func sparkleTelemetryCallSiteParity() async {
      let box = EventBox()
      let originalHook = TelemetryService.shared.testEventHook
      TelemetryService.shared.testEventHook = { @Sendable event in
        Task { @MainActor in box.events.append(event) }
      }
      defer { TelemetryService.shared.testEventHook = originalHook }

      TelemetryService.shared.updateSparkleDefaultShown(
        version: "v1", isCritical: false, reason: "immediate_focus")
      TelemetryService.shared.updateInstallStarted(
        version: "v1", isCritical: true, source: "menu")
      TelemetryService.shared.updateSparkleCycleFinished(
        version: "v1", isCritical: false, source: "menu", errorCode: nil)
      TelemetryService.shared.updateInstallCompleted(
        version: "v1", isCritical: false, source: "menu")
      TelemetryService.shared.updateInstallCancelled(
        version: "v1", isCritical: false, source: "banner")
      TelemetryService.shared.updateInstallFailed(
        version: "v1", isCritical: false, source: "menu", errorCode: "NSURLErrorDomain.-1009")

      // Drain the Task hops scheduled by each test hook firing.
      await Task.yield()
      await Task.yield()

      let captured = box.events
      let expectedNames: Set<String> = [
        "update.sparkle_default_shown",
        "update.install_started",
        "update.sparkle_cycle_finished",
        "update.install_completed",
        "update.install_cancelled",
        "update.install_failed",
      ]
      let actualNames = Set(captured.map(\.name))
      #expect(
        actualNames.isSuperset(of: expectedNames),
        """
        Telemetry hook missed names. Expected superset of \(expectedNames), \
        got \(actualNames).
        """)

      // Per-event key parity with what `PostHogSDK.capture` sees in production.
      if let evt = captured.first(where: { $0.name == "update.sparkle_default_shown" }) {
        #expect(evt.stringProps.keys.sorted() == ["reason", "version"])
        #expect(evt.boolProps.keys.sorted() == ["is_critical"])
      }
      if let evt = captured.first(where: { $0.name == "update.install_started" }) {
        #expect(evt.stringProps.keys.sorted() == ["source", "version"])
        #expect(evt.boolProps.keys.sorted() == ["is_critical"])
      }
      if let evt = captured.first(where: { $0.name == "update.install_failed" }) {
        #expect(evt.stringProps.keys.sorted() == ["error_code", "source", "version"])
        #expect(evt.boolProps.keys.sorted() == ["is_critical"])
      }
    }

  #endif  // DEBUG
}
