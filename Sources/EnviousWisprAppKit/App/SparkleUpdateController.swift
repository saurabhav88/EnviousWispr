import AppKit
import EnviousWisprCore
import EnviousWisprServices
import Foundation
@preconcurrency import Sparkle

/// PR-B.1 of #763 — App-owned home for the Sparkle integration. Replaces
/// the AppDelegate-owned `updaterController` + `updateCoordinator` storage
/// and the two Sparkle delegate extensions.
///
/// Lifecycle is driven by `AppDelegate.applicationWillFinishLaunching`, which
/// calls `startUpdater()` synchronously on the same call stack so the
/// `UpdateCoordinatorHolder` env-carrier (Issue #739) is published BEFORE
/// SwiftUI evaluates the App's first scene body. The invariant is identical
/// to the pre-PR-B.1 inline-AppDelegate code: writing
/// `holder.coordinator = updateCoordinator` synchronously inside
/// `applicationWillFinishLaunching`, before any scene body evaluates.
/// Packages the Sparkle updater-construction closure into a single
/// dependency slot. Mirrors the PR9 `RecordingLockedAccess` shape so the
/// architecture ceiling parser scores it as one collaborator instead of
/// flagging a multi-line closure-typed `let`.
struct SparkleUpdaterFactory: Sendable {
  let make:
    @MainActor (any SPUUpdaterDelegate, any SPUStandardUserDriverDelegate) ->
      SPUStandardUpdaterController?
}

@MainActor
final class SparkleUpdateController: NSObject {
  private let holder: UpdateCoordinatorHolder
  private(set) var updaterController: SPUStandardUpdaterController?
  private(set) var updateCoordinator: UpdateCoordinator?
  private let bundleVersionProvider: () -> String
  private let updaterFactory: SparkleUpdaterFactory

  /// Production factory. Constructed once; the closure builds a real
  /// `SPUStandardUpdaterController` with both delegates wired to the
  /// owning controller.
  static let defaultUpdaterFactory = SparkleUpdaterFactory { delegate, userDriver in
    SPUStandardUpdaterController(
      startingUpdater: true,
      updaterDelegate: delegate,
      userDriverDelegate: userDriver
    )
  }

  /// Test-only seam so `SparkleUpdateControllerTests` can verify the
  /// idempotency contract without crashing the debug test runner.
  /// Production default routes to `assertionFailure` — dev signal unchanged.
  static var assertionHandler: (String) -> Void = { message in
    assertionFailure(message)
  }

  init(
    holder: UpdateCoordinatorHolder,
    bundleVersionProvider: @escaping () -> String = { AppConstants.appVersion },
    updaterFactory: SparkleUpdaterFactory = SparkleUpdateController.defaultUpdaterFactory
  ) {
    self.holder = holder
    self.bundleVersionProvider = bundleVersionProvider
    self.updaterFactory = updaterFactory
    super.init()
  }

  /// Construct the Sparkle updater + the in-app update coordinator, publish
  /// the coordinator into the env-carrier, and run cross-launch correlation.
  /// Idempotent: second invocation is a debug `assertionFailure` and a
  /// release no-op so a future regression in launch sequencing cannot
  /// silently re-init Sparkle (which does not support multiple
  /// `SPUStandardUpdaterController` instances).
  func startUpdater() {
    // Idempotency: guard on `updateCoordinator` (not `updaterController`)
    // because the updater factory MAY return nil in tests, while the
    // coordinator is always constructed on the first successful call.
    guard updateCoordinator == nil else {
      Self.assertionHandler("SparkleUpdateController.startUpdater() invoked more than once")
      return
    }
    let controller = updaterFactory.make(self, self)
    updaterController = controller
    let coordinator = UpdateCoordinator(updaterController: controller)
    updateCoordinator = coordinator
    holder.coordinator = coordinator
    evaluateInstallAttemptOnLaunch()
  }

  /// Menu-gating read. AppDelegate's `populateMenu(_:)` uses this to decide
  /// whether to render the "Check for Updates" item.
  var hasUpdater: Bool {
    updaterController != nil
  }

  /// Menu action target. `@objc` because `NSMenuItem.action` binds to an
  /// Objective-C selector.
  @objc func openUpdateCheckFromMenu(_ sender: Any?) {
    updateCoordinator?.lastInstallSource = "menu"
    updaterController?.checkForUpdates(sender)
  }

  /// Issue #343 cross-launch correlation. Compares the current bundle version
  /// to a persisted "we just attempted to install" marker and fires
  /// `update.install_completed` / `update.install_cancelled` telemetry.
  private func evaluateInstallAttemptOnLaunch() {
    guard let coordinator = updateCoordinator else { return }
    let outcome = coordinator.evaluateLastInstallAttempt(
      currentBundleVersion: bundleVersionProvider()
    )
    switch outcome {
    case .completed(let version, let source):
      TelemetryService.shared.updateInstallCompleted(
        version: version, isCritical: false, source: source
      )
    case .cancelled(let version, let source):
      TelemetryService.shared.updateInstallCancelled(
        version: version, isCritical: false, source: source
      )
    case .none, .unattributable, .stale:
      break
    }
  }
}

// MARK: - SPUStandardUserDriverDelegate

extension SparkleUpdateController: @preconcurrency SPUStandardUserDriverDelegate {
  /// Issue #343: declares support for gentle scheduled update reminders.
  /// Sparkle logs an error if a background app does not declare this.
  /// (sparkle-project.org/documentation/gentle-reminders)
  var supportsGentleScheduledUpdateReminders: Bool { true }

  /// Bring app to front when Sparkle shows an update dialog (LSUIElement fix).
  func standardUserDriverWillShowModalAlert() {
    NSApp.setActivationPolicy(.regular)
    NSApp.activate()
  }

  /// Return to accessory mode when the entire update session ends.
  func standardUserDriverWillFinishUpdateSession() {
    NSApp.setActivationPolicy(.accessory)
  }

  /// Issue #343: pure yes/no decision per Sparkle's documented gentle-reminder
  /// pattern. NO side effects. All state mutation happens in
  /// `standardUserDriverWillHandleShowingUpdate`.
  /// Sparkle's contract: YES = Sparkle handles, NO = delegate handles.
  func standardUserDriverShouldHandleShowingScheduledUpdate(
    _ update: SUAppcastItem,
    andInImmediateFocus immediateFocus: Bool
  ) -> Bool {
    // #1019: the no-window non-critical case no longer hands off to Sparkle's
    // focus-stealing modal. Our menu-bar gold-wave cue + once-per-version
    // notification own that surface now (both land from `noteAvailable` in
    // `standardUserDriverWillHandleShowingUpdate` below). Critical or
    // immediate-focus updates still route to Sparkle's full UX.
    if update.isCriticalUpdate { return true }  // critical → Sparkle's full UX
    if immediateFocus { return true }  // Sparkle wants front-and-center
    return false  // we own the gentle UX (banner when windowed; menu-bar + notification otherwise)
  }

  /// Issue #343: side-effect callback that fires after the yes/no decision.
  /// Captures availability state into the service and (if Sparkle handles)
  /// tags the install source for telemetry attribution.
  /// Sparkle's contract: handleShowingUpdate == true → Sparkle handles,
  /// false → delegate (us) handles.
  func standardUserDriverWillHandleShowingUpdate(
    _ handleShowingUpdate: Bool,
    forUpdate update: SUAppcastItem,
    state: SPUUserUpdateState
  ) {
    let available = UpdateAvailabilityService.AvailableUpdate(
      versionString: update.versionString,
      displayVersion: update.displayVersionString,
      isCriticalUpdate: update.isCriticalUpdate
    )
    updateCoordinator?.service.noteAvailable(available)

    if handleShowingUpdate {
      // Sparkle owns UX. Tag source + fire diagnostic event.
      let reason: String = {
        if !NSApp.windows.contains(where: { $0.isVisible && $0.canBecomeMain }) {
          return "no_main_window"
        }
        if update.isCriticalUpdate { return "critical" }
        return "immediate_focus"
      }()
      updateCoordinator?.lastInstallSource = "sparkle_default"
      TelemetryService.shared.updateSparkleDefaultShown(
        version: update.versionString,
        isCritical: update.isCriticalUpdate,
        reason: reason
      )
    }
    // Else: banner owns UX; source set by `triggerInstall` when user clicks.
  }

  /// Issue #739: Sparkle fires this on alert focus AND user choice; it is NOT
  /// a dismissal signal. Widget visibility is governed solely by bundle
  /// version on disk. User engagement with the Sparkle alert does not hide
  /// the widget. Method retained as no-op so Sparkle's delegate conformance
  /// continues to register interest in the callback (needsToObserveUserAttention
  /// gates other Sparkle internals; see SPUStandardUserDriver.m:370).
  func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
  }
}

// MARK: - SPUUpdaterDelegate

extension SparkleUpdateController: SPUUpdaterDelegate {
  /// Issue #343: fires when the user has accepted an update and Sparkle is
  /// about to begin install. Persists the install attempt for cross-launch
  /// correlation, fires `update.install_started`, flushes telemetry so the
  /// event survives Sparkle's relaunch.
  func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) {
    let source = updateCoordinator?.lastInstallSource ?? "unknown"
    updateCoordinator?.recordInstallAttempt(version: item.versionString, source: source)
    TelemetryService.shared.updateInstallStarted(
      version: item.versionString,
      isCritical: item.isCriticalUpdate,
      source: source
    )
    TelemetryService.shared.flushTelemetry(reason: .updateInstall)
  }

  /// Issue #343: silent install-on-quit path. This is a separate Sparkle
  /// driver from `willInstallUpdate` — for automatically-downloaded updates
  /// that install when the user quits. Tag source explicitly so we can
  /// distinguish it from banner / menu / sparkle_default attribution.
  func updater(
    _ updater: SPUUpdater,
    willInstallUpdateOnQuit item: SUAppcastItem,
    immediateInstallationBlock immediateInstallHandler: @escaping () -> Void
  ) -> Bool {
    updateCoordinator?.lastInstallSource = "install_on_quit"
    updateCoordinator?.recordInstallAttempt(version: item.versionString, source: "install_on_quit")
    TelemetryService.shared.updateInstallStarted(
      version: item.versionString,
      isCritical: item.isCriticalUpdate,
      source: "install_on_quit"
    )
    TelemetryService.shared.flushTelemetry(reason: .updateInstall)
    // Returning false lets Sparkle's automatic install-on-quit proceed normally.
    return false
  }

  /// Issue #846: classifier for whether an error from `didFinishUpdateCycleFor`
  /// represents a real install failure (worth firing `update.install_failed`)
  /// or one of Sparkle's three benign terminal outcomes. Pure function — no
  /// instance state. Sparkle itself excludes these three codes from its own
  /// logging (`SPUUpdater.m:797-800`).
  ///
  /// Domain guard: a non-Sparkle error happening to carry one of the numeric
  /// codes (e.g. a CFNetwork error with code 1001) still emits. We only
  /// suppress when Sparkle's own domain emits one of its known benign codes.
  ///
  /// `internal` (not `private`) so `@testable import EnviousWispr` tests can
  /// call it without constructing a `SPUUpdater` (which Sparkle does not
  /// expose for tests per `SPUUpdater.h:62-69`).
  static func isReportableSparkleInstallFailure(_ error: NSError) -> Bool {
    guard error.domain == "SUSparkleErrorDomain" else { return true }
    return ![1001, 4007, 4008].contains(error.code)
  }

  /// Issue #1447: coarse cycle-failure stage, one case per Sparkle's own
  /// phase grouping in `SUErrors.h`. `validation` covers Sparkle's
  /// "Extraction phase errors" (unarchiving, signature, validation).
  enum SparkleFailureStage: String, CaseIterable {
    case appcast
    case download
    case validation
    case install
    case unknown
  }

  /// Issue #1447: maps Sparkle's numeric error-code ranges to a coarse
  /// cycle-failure stage. Codes below 1000 (configuration/API-misuse setup
  /// errors), 5000+ (API misuse), and any non-Sparkle domain map to
  /// `.unknown` rather than guessing a bucket — matches the domain guard
  /// already used by `isReportableSparkleInstallFailure`. A future Sparkle
  /// code landing inside an already-classified range inherits that range's
  /// stage (accepted scope limit, not a gap).
  static func failureStage(_ error: NSError?) -> SparkleFailureStage {
    guard let error, error.domain == "SUSparkleErrorDomain" else { return .unknown }
    switch error.code {
    case 1000...1999: return .appcast
    case 2000...2999: return .download
    case 3000...3999: return .validation
    case 4000...4999: return .install
    default: return .unknown
    }
  }

  /// Issue #1447: preserve the legacy `update.install_failed` event for
  /// foreign-domain errors, because their stage cannot be determined and
  /// `isReportableSparkleInstallFailure` already treats them as reportable
  /// today — suppressing them here would be a new, unproven-safe
  /// regression. Suppress only when Sparkle-domain evidence positively
  /// says the failure was NOT install-stage.
  static func shouldEmitLegacyInstallFailure(
    error: NSError, stage: SparkleFailureStage
  ) -> Bool {
    error.domain != "SUSparkleErrorDomain" || stage == .install
  }

  /// Issue #847 Phase 1: extract Sparkle's no-update reason from the error
  /// userInfo. Guarded — returns nil unless the error is a Sparkle SUNoUpdateError
  /// (code 1001 with the `SUSparkleErrorDomain` domain). Sparkle attaches
  /// `SPUNoUpdateFoundReasonKey: NSNumber(rawValue)` ONLY on that specific
  /// error path per `SPUBasicUpdateDriver.m:244-261`. Pure function, no
  /// instance state, testable directly.
  ///
  /// Returns a stable lowercase-snake string. Unknown raw values map to the
  /// fixed string `"unrecognized"` (bounded cardinality — no rawValue
  /// interpolation, addresses Gemini council finding about unbounded
  /// PostHog property cardinality).
  static func noUpdateReason(from error: NSError?) -> String? {
    guard let error else { return nil }
    guard error.domain == "SUSparkleErrorDomain", error.code == 1001 else { return nil }
    // SPUNoUpdateFoundReason is declared as NS_ENUM(OSStatus, ...) per
    // SUErrors.h:80, so rawValue: takes OSStatus (Int32). Read NSNumber
    // and convert with int32Value to match the bridged enum's signature.
    guard
      let raw = (error.userInfo[SPUNoUpdateFoundReasonKey as String] as? NSNumber)?.int32Value
    else { return nil }
    // Prefer the Swift-bridged enum case-switch; rawValue init is
    // failable so unknown future cases fall through to "unrecognized".
    guard let reason = SPUNoUpdateFoundReason(rawValue: raw) else { return "unrecognized" }
    switch reason {
    case .unknown: return "unknown"
    case .onLatestVersion: return "on_latest_version"
    case .onNewerThanLatestVersion: return "on_newer_than_latest_version"
    case .systemIsTooOld: return "system_is_too_old"
    case .systemIsTooNew: return "system_is_too_new"
    case .hardwareDoesNotSupportARM64: return "hardware_does_not_support_arm64"
    @unknown default: return "unrecognized"
    }
  }

  /// Issue #847 Phase 1: discriminator string for Sparkle's update-check
  /// classification. The founder workaround (manual menu click works when
  /// background check returns no update) makes this the load-bearing
  /// signal for Phase 2 root-cause analysis.
  ///
  /// `@unknown default` forces a compile warning if Sparkle adds new cases
  /// at the next major bump — early signal at build time.
  static func checkKindString(_ check: SPUUpdateCheck) -> String {
    switch check {
    case .updates: return "user_initiated"
    case .updatesInBackground: return "background"
    case .updateInformation: return "informational"
    @unknown default: return "unrecognized"
    }
  }

  // MARK: - Update stage split (#1178 Phase 9, B2)

  /// Download/verify(extract) stage breadcrumbs. These 4 `SPUUpdaterDelegate` hooks are
  /// optional (Sparkle calls them via `respondsToSelector`), so adding them is purely
  /// additive — no control-flow change. `item.versionString` is the CFBundleVersion
  /// compare key (Codex r2: NOT `displayVersionString`, which is UI text). Observation
  /// only; never blocks Sparkle.
  func updater(
    _ updater: SPUUpdater, willDownloadUpdate item: SUAppcastItem, with request: NSMutableURLRequest
  ) {
    TelemetryService.shared.updateDownloadStarted(
      version: item.versionString, isCritical: item.isCriticalUpdate)
  }
  func updater(_ updater: SPUUpdater, didDownloadUpdate item: SUAppcastItem) {
    TelemetryService.shared.updateDownloadCompleted(
      version: item.versionString, isCritical: item.isCriticalUpdate)
  }
  func updater(_ updater: SPUUpdater, willExtractUpdate item: SUAppcastItem) {
    TelemetryService.shared.updateVerifyStarted(
      version: item.versionString, isCritical: item.isCriticalUpdate)
  }
  func updater(_ updater: SPUUpdater, didExtractUpdate item: SUAppcastItem) {
    TelemetryService.shared.updateVerifyCompleted(
      version: item.versionString, isCritical: item.isCriticalUpdate)
  }

  /// Resolve the version-staleness bucket from plain fields (Codex r4: unit-testable
  /// without constructing `SUAppcastItem`/`SPUUpdater`, whose inits are unavailable).
  /// The latest is the pending `.available` version, else the latest item Sparkle
  /// attached to a no-update error; neither known → `on_latest` by policy (Codex r1).
  static func resolveStalenessBucket(
    current: String, availableVersion: String?, latestFromErrorVersion: String?
  ) -> String {
    guard let latest = availableVersion ?? latestFromErrorVersion else { return "on_latest" }
    return VersionStaleness.bucket(current: current, latest: latest)
  }

  /// Issue #343: terminal "the cycle ended" hook. Fires diagnostic event,
  /// resolves service state, clears install-source.
  func updater(
    _ updater: SPUUpdater,
    didFinishUpdateCycleFor updateCheck: SPUUpdateCheck,
    error: (any Error)?
  ) {
    let source = updateCoordinator?.lastInstallSource ?? "unknown"
    let pendingVersion: String? = {
      if case .available(let u) = updateCoordinator?.service.state ?? .none {
        return u.versionString
      }
      return nil
    }()
    let version = pendingVersion ?? "unknown"
    let isCritical: Bool = {
      if case .available(let u) = updateCoordinator?.service.state ?? .none {
        return u.isCriticalUpdate
      }
      return false
    }()
    let errorCode = (error as NSError?).map { "\($0.domain).\($0.code)" }
    // Issue #847 Phase 1: diagnostic enrichment. Extract Sparkle's
    // SPUNoUpdateFoundReasonKey (guarded to SUNoUpdateError + domain) and
    // map SPUUpdateCheck to a stable string. Pair with current app version
    // sourced from the existing bundleVersionProvider so Phase 2 can
    // pivot the fix on (current_app_version × check_kind × no_update_reason).
    let noUpdateReason = Self.noUpdateReason(from: error as NSError?)
    let checkKind = Self.checkKindString(updateCheck)
    let currentAppVersion = bundleVersionProvider()
    // #1178 (Phase 9, B3): how stale is this user? The latest version is whatever
    // Sparkle just resolved live — the pending `.available` update, else the latest
    // item Sparkle attaches to a no-update error (`SPULatestAppcastItemFoundKey`).
    // `pendingVersion == nil` is NOT proof of on-latest (Codex r1), so we check the
    // error too; nil-both → on_latest by policy. No cache, no cross-session persistence.
    let latestFromError =
      ((error as NSError?)?.userInfo[SPULatestAppcastItemFoundKey] as? SUAppcastItem)?
      .versionString
    let stalenessBucket = Self.resolveStalenessBucket(
      current: currentAppVersion, availableVersion: pendingVersion,
      latestFromErrorVersion: latestFromError)
    TelemetryService.shared.updateSparkleCycleFinished(
      version: version,
      isCritical: isCritical,
      source: source,
      errorCode: errorCode,
      noUpdateReason: noUpdateReason,
      checkKind: checkKind,
      currentAppVersion: currentAppVersion,
      versionStalenessBucket: stalenessBucket
    )
    // Issue #846: filter Sparkle's three benign terminal outcomes from
    // update.install_failed. Sparkle itself excludes them from its own logging
    // (SPUUpdater.m:797-800): SUNoUpdateError = 1001 (no update available),
    // SUInstallationCanceledError = 4007 (user cancelled authorization),
    // SUInstallationAuthorizeLaterError = 4008 (user chose install later).
    // All three reach this callback via SPUUpdater.m:810-812. Non-Sparkle
    // errors with the same numeric codes still emit (domain guard).
    //
    // Issue #1447: stage-classify every reportable abort into
    // update.cycle_failed, then narrow update.install_failed to fire only
    // when shouldEmitLegacyInstallFailure says the failure is genuinely
    // install-stage (or foreign-domain, where stage can't be proven and
    // legacy behavior is preserved rather than risking a false negative).
    if let nsError = error as NSError?, Self.isReportableSparkleInstallFailure(nsError) {
      let stage = Self.failureStage(nsError)
      let errorCodeString = "\(nsError.domain).\(nsError.code)"
      TelemetryService.shared.updateCycleFailed(
        version: version,
        isCritical: isCritical,
        source: source,
        errorCode: errorCodeString,
        stage: stage.rawValue,
        installIntentSeen: source != "unknown",
        checkKind: checkKind,
        currentAppVersion: currentAppVersion
      )
      if Self.shouldEmitLegacyInstallFailure(error: nsError, stage: stage) {
        TelemetryService.shared.updateInstallFailed(
          version: version,
          isCritical: isCritical,
          source: source,
          errorCode: errorCodeString,
          noUpdateReason: noUpdateReason,
          checkKind: checkKind,
          currentAppVersion: currentAppVersion
        )
      }
    }
    // Issue #739: do NOT call noteResolved here. Sparkle's "cycle finished"
    // fires on cancel/skip/error/install-on-quit-scheduled alike. Widget state
    // is cleared only when bundle version catches up (rehydratePendingIfNewer
    // on next launch). In-session, the existing 5s resolvingWatchdog in
    // triggerInstall restores .available if the user clicked the widget but
    // did not complete an install.
    updateCoordinator?.lastInstallSource = nil

    // #1019: feed the cycle OUTCOME to the proactive-check cooldown. A genuine
    // network/parse failure does NOT consume the event-driven cooldown (so the
    // next wake/network trigger re-checks); a benign Sparkle terminal code
    // (no-update / user-cancel / install-later) means the feed WAS reached and
    // the cooldown is earned.
    let reachedFeed: Bool = {
      guard let nsError = error as NSError? else { return true }
      if nsError.domain == "SUSparkleErrorDomain", [1001, 4007, 4008].contains(nsError.code) {
        return true
      }
      return false
    }()
    updateCoordinator?.recordUpdateCheckOutcome(success: reachedFeed)
  }
}
