import EnviousWisprCore
import EnviousWisprServices
import Foundation
@preconcurrency import Sparkle
import Testing

@testable import EnviousWisprAppKit

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

  // The tests below rely on the DEBUG-only `testEventHook` seam (and the
  // `EventBox` Sendable storage), so they compile only in debug. CI also
  // builds tests in release; gating preserves both lanes.
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
        version: "v1",
        isCritical: false,
        source: "menu",
        errorCode: nil,
        noUpdateReason: nil,
        checkKind: "background",
        currentAppVersion: "v-host",
        versionStalenessBucket: "on_latest"
      )
      TelemetryService.shared.updateInstallCompleted(
        version: "v1", isCritical: false, source: "menu")
      TelemetryService.shared.updateInstallCancelled(
        version: "v1", isCritical: false, source: "banner")
      TelemetryService.shared.updateInstallFailed(
        version: "v1",
        isCritical: false,
        source: "menu",
        errorCode: "NSURLErrorDomain.-1009",
        noUpdateReason: nil,
        checkKind: "background",
        currentAppVersion: "v-host"
      )

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
        #expect(
          evt.stringProps.keys.sorted() == [
            "check_kind", "current_app_version", "error_code", "source", "version",
          ])
        #expect(evt.boolProps.keys.sorted() == ["is_critical"])
      }
    }

    // MARK: - #846: isReportableSparkleInstallFailure classifier (Layer A)
    //
    // Pure-function tests on the new classifier helper. Direct delegate
    // testing of `didFinishUpdateCycleFor` is infeasible (SPUUpdater.init
    // is unavailable per Sparkle/SPUUpdater.h:62-69), so we test the
    // classifier as a function and trust the integration call site by
    // inspection. The three benign Sparkle codes come from Sparkle's own
    // logging filter at SPUUpdater.m:797-800.

    @Test("Sparkle code 1001 (SUNoUpdateError) is suppressed")
    func classifier_sparkle1001_isFalse() {
      let error = NSError(domain: "SUSparkleErrorDomain", code: 1001)
      #expect(SparkleUpdateController.isReportableSparkleInstallFailure(error) == false)
    }

    @Test("Sparkle code 4007 (SUInstallationCanceledError) is suppressed")
    func classifier_sparkle4007_isFalse() {
      let error = NSError(domain: "SUSparkleErrorDomain", code: 4007)
      #expect(SparkleUpdateController.isReportableSparkleInstallFailure(error) == false)
    }

    @Test("Sparkle code 4008 (SUInstallationAuthorizeLaterError) is suppressed")
    func classifier_sparkle4008_isFalse() {
      let error = NSError(domain: "SUSparkleErrorDomain", code: 4008)
      #expect(SparkleUpdateController.isReportableSparkleInstallFailure(error) == false)
    }

    @Test("Sparkle code 4005 (SUInstallationError) is reported")
    func classifier_sparkle4005_isTrue() {
      let error = NSError(domain: "SUSparkleErrorDomain", code: 4005)
      #expect(SparkleUpdateController.isReportableSparkleInstallFailure(error) == true)
    }

    @Test("Non-Sparkle domain with code 1001 is reported (domain guard)")
    func classifier_nonSparkleDomain1001_isTrue() {
      let error = NSError(domain: "NSURLErrorDomain", code: 1001)
      #expect(SparkleUpdateController.isReportableSparkleInstallFailure(error) == true)
    }

    // MARK: - #846: telemetry-hook smoke (Layer B)

    @Test("updateInstallFailed propagates error_code to testEventHook")
    func installFailedPropagatesErrorCodeToHook() async {
      let box = EventBox()
      let originalHook = TelemetryService.shared.testEventHook
      TelemetryService.shared.testEventHook = { @Sendable event in
        Task { @MainActor in box.events.append(event) }
      }
      defer { TelemetryService.shared.testEventHook = originalHook }

      TelemetryService.shared.updateInstallFailed(
        version: "v1",
        isCritical: false,
        source: "test",
        errorCode: "SUSparkleErrorDomain.4005",
        noUpdateReason: nil,
        checkKind: "background",
        currentAppVersion: "v-host"
      )

      await Task.yield()
      await Task.yield()

      let captured = box.events
      let evt = captured.first(where: { $0.name == "update.install_failed" })
      #expect(evt != nil, "update.install_failed event should be captured")
      #expect(evt?.stringProps["error_code"] == "SUSparkleErrorDomain.4005")
    }

    // MARK: - #847 Phase 1: noUpdateReason classifier (Layer A)
    //
    // Pure-function tests on the extraction helper. Sparkle attaches
    // SPUNoUpdateFoundReasonKey only to errors with the SUSparkleErrorDomain
    // domain AND code SUNoUpdateError (1001) per SPUBasicUpdateDriver.m:244-261.
    // The helper enforces that guard. Bridged enum init is failable so
    // unknown future raw values fall through to "unrecognized" (fixed string,
    // not interpolated — bounded PostHog cardinality).

    @Test("noUpdateReason: nil error returns nil")
    func noUpdateReason_nilError_returnsNil() {
      #expect(SparkleUpdateController.noUpdateReason(from: nil) == nil)
    }

    @Test("noUpdateReason: Sparkle 1001 with systemIsTooNew rawValue returns mapped string")
    func noUpdateReason_systemTooNew_returnsString() {
      let error = NSError(
        domain: "SUSparkleErrorDomain",
        code: 1001,
        userInfo: [SPUNoUpdateFoundReasonKey as String: NSNumber(value: Int32(4))]
      )
      #expect(SparkleUpdateController.noUpdateReason(from: error) == "system_is_too_new")
    }

    @Test("noUpdateReason: Sparkle 1001 with missing reason key returns nil")
    func noUpdateReason_missingReasonKey_returnsNil() {
      let error = NSError(domain: "SUSparkleErrorDomain", code: 1001)
      #expect(SparkleUpdateController.noUpdateReason(from: error) == nil)
    }

    @Test("noUpdateReason: non-Sparkle domain with reason key returns nil (domain guard)")
    func noUpdateReason_nonSparkleDomain_returnsNil() {
      let error = NSError(
        domain: "NSURLErrorDomain",
        code: 1001,
        userInfo: [SPUNoUpdateFoundReasonKey as String: NSNumber(value: Int32(4))]
      )
      #expect(SparkleUpdateController.noUpdateReason(from: error) == nil)
    }

    @Test("noUpdateReason: Sparkle non-1001 code with reason key returns nil (code guard)")
    func noUpdateReason_wrongCode_returnsNil() {
      let error = NSError(
        domain: "SUSparkleErrorDomain",
        code: 4005,
        userInfo: [SPUNoUpdateFoundReasonKey as String: NSNumber(value: Int32(4))]
      )
      #expect(SparkleUpdateController.noUpdateReason(from: error) == nil)
    }

    @Test("noUpdateReason: out-of-range rawValue returns fixed 'unrecognized' string")
    func noUpdateReason_unknownRawValue_returnsUnrecognized() {
      let error = NSError(
        domain: "SUSparkleErrorDomain",
        code: 1001,
        userInfo: [SPUNoUpdateFoundReasonKey as String: NSNumber(value: Int32(999))]
      )
      #expect(SparkleUpdateController.noUpdateReason(from: error) == "unrecognized")
    }

    @Test("checkKindString: maps all three documented SPUUpdateCheck cases")
    func checkKindString_mapsAllThreeCases() {
      #expect(SparkleUpdateController.checkKindString(.updates) == "user_initiated")
      #expect(SparkleUpdateController.checkKindString(.updatesInBackground) == "background")
      #expect(SparkleUpdateController.checkKindString(.updateInformation) == "informational")
    }

    // MARK: - #847 Phase 1: telemetry-hook propagation (Layer B)

    @Test("updateSparkleCycleFinished propagates all three new props to hook")
    func cycleFinished_propagatesAllThreeNewPropsToHook() async {
      let box = EventBox()
      let originalHook = TelemetryService.shared.testEventHook
      TelemetryService.shared.testEventHook = { @Sendable event in
        Task { @MainActor in box.events.append(event) }
      }
      defer { TelemetryService.shared.testEventHook = originalHook }

      TelemetryService.shared.updateSparkleCycleFinished(
        version: "v-pending",
        isCritical: false,
        source: "background",
        errorCode: "SUSparkleErrorDomain.1001",
        noUpdateReason: "on_latest_version",
        checkKind: "background",
        currentAppVersion: "v2.0.4",
        versionStalenessBucket: "on_latest"
      )

      await Task.yield()
      await Task.yield()

      let captured = box.events
      let evt = captured.first(where: { $0.name == "update.sparkle_cycle_finished" })
      #expect(evt != nil, "update.sparkle_cycle_finished event should be captured")
      #expect(evt?.stringProps["no_update_reason"] == "on_latest_version")
      #expect(evt?.stringProps["check_kind"] == "background")
      #expect(evt?.stringProps["current_app_version"] == "v2.0.4")
    }

    @Test("updateSparkleCycleFinished with nil noUpdateReason omits the property entirely")
    func cycleFinished_withNilNoUpdateReason_omitsProperty() async {
      let box = EventBox()
      let originalHook = TelemetryService.shared.testEventHook
      TelemetryService.shared.testEventHook = { @Sendable event in
        Task { @MainActor in box.events.append(event) }
      }
      defer { TelemetryService.shared.testEventHook = originalHook }

      TelemetryService.shared.updateSparkleCycleFinished(
        version: "v-pending",
        isCritical: false,
        source: "background",
        errorCode: nil,
        noUpdateReason: nil,
        checkKind: "user_initiated",
        currentAppVersion: "v2.0.4",
        versionStalenessBucket: "on_latest"
      )

      await Task.yield()
      await Task.yield()

      let captured = box.events
      let evt = captured.first(where: { $0.name == "update.sparkle_cycle_finished" })
      #expect(evt != nil)
      #expect(
        evt?.stringProps["no_update_reason"] == nil,
        "no_update_reason key MUST be absent (not the literal 'nil' string).")
      #expect(evt?.stringProps["check_kind"] == "user_initiated")
      #expect(evt?.stringProps["current_app_version"] == "v2.0.4")
    }

    @Test("updateInstallFailed propagates all three new props to hook")
    func installFailed_propagatesAllThreeNewPropsToHook() async {
      let box = EventBox()
      let originalHook = TelemetryService.shared.testEventHook
      TelemetryService.shared.testEventHook = { @Sendable event in
        Task { @MainActor in box.events.append(event) }
      }
      defer { TelemetryService.shared.testEventHook = originalHook }

      // Note: production callers will not pair install_failed with a
      // non-nil no_update_reason after #846 lands (1001 events stop
      // routing through install_failed). The test still passes a non-nil
      // value to prove the signature handles all three new props
      // independently of the call-site policy.
      TelemetryService.shared.updateInstallFailed(
        version: "v-pending",
        isCritical: false,
        source: "menu",
        errorCode: "SUSparkleErrorDomain.4005",
        noUpdateReason: "on_latest_version",
        checkKind: "user_initiated",
        currentAppVersion: "v2.0.4"
      )

      await Task.yield()
      await Task.yield()

      let captured = box.events
      let evt = captured.first(where: { $0.name == "update.install_failed" })
      #expect(evt != nil)
      #expect(evt?.stringProps["error_code"] == "SUSparkleErrorDomain.4005")
      #expect(evt?.stringProps["check_kind"] == "user_initiated")
      #expect(evt?.stringProps["current_app_version"] == "v2.0.4")
      #expect(evt?.stringProps["no_update_reason"] == "on_latest_version")
    }

    // MARK: - #1178 Phase 9 (B2 stage split + B3 staleness)

    @Test("resolveStalenessBucket prefers .available, falls back to the error item, else on_latest")
    func resolveStalenessBucketSources() {
      // .available wins
      #expect(
        SparkleUpdateController.resolveStalenessBucket(
          current: "2.0.0", availableVersion: "2.1.0", latestFromErrorVersion: "9.9.9")
          == "minor_behind")
      // no .available → fall back to the latest item Sparkle attached to a no-update error
      #expect(
        SparkleUpdateController.resolveStalenessBucket(
          current: "1.0.0", availableVersion: nil, latestFromErrorVersion: "2.0.0")
          == "major_behind")
      // neither known → on_latest by policy (the common clean no-update cycle)
      #expect(
        SparkleUpdateController.resolveStalenessBucket(
          current: "2.1.4", availableVersion: nil, latestFromErrorVersion: nil) == "on_latest")
    }

    @Test("the 4 download/verify stage events fire with version + is_critical")
    func stageEventsFire() async {
      let box = EventBox()
      let originalHook = TelemetryService.shared.testEventHook
      TelemetryService.shared.testEventHook = { @Sendable event in
        Task { @MainActor in box.events.append(event) }
      }
      defer { TelemetryService.shared.testEventHook = originalHook }

      TelemetryService.shared.updateDownloadStarted(version: "2.1.4", isCritical: true)
      TelemetryService.shared.updateDownloadCompleted(version: "2.1.4", isCritical: true)
      TelemetryService.shared.updateVerifyStarted(version: "2.1.4", isCritical: false)
      TelemetryService.shared.updateVerifyCompleted(version: "2.1.4", isCritical: false)

      await Task.yield()
      await Task.yield()

      let names = Set(box.events.map { $0.name })
      #expect(
        names.isSuperset(of: [
          "update.download_started", "update.download_completed",
          "update.verify_started", "update.verify_completed",
        ]))
      let dl = box.events.first { $0.name == "update.download_started" }
      #expect(dl?.stringProps["version"] == "2.1.4")
      #expect(dl?.boolProps["is_critical"] == true)
    }

    @Test("the cycle event carries version_staleness_bucket")
    func cycleCarriesStalenessBucket() async {
      let box = EventBox()
      let originalHook = TelemetryService.shared.testEventHook
      TelemetryService.shared.testEventHook = { @Sendable event in
        Task { @MainActor in box.events.append(event) }
      }
      defer { TelemetryService.shared.testEventHook = originalHook }

      TelemetryService.shared.updateSparkleCycleFinished(
        version: "2.1.4", isCritical: false, source: "background", errorCode: nil,
        noUpdateReason: nil, checkKind: "background", currentAppVersion: "2.0.0",
        versionStalenessBucket: "minor_behind")

      await Task.yield()
      await Task.yield()

      let evt = box.events.first { $0.name == "update.sparkle_cycle_finished" }
      #expect(evt?.stringProps["version_staleness_bucket"] == "minor_behind")
    }

  #endif  // DEBUG
}
