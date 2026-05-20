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
    let hasMainWindow = NSApp.windows.contains { $0.isVisible && $0.canBecomeMain }
    if !hasMainWindow { return true }  // no banner mount → Sparkle handles
    if update.isCriticalUpdate { return true }  // critical → Sparkle's full UX
    if immediateFocus { return true }  // Sparkle wants front-and-center
    return false  // we own the gentle UX via the banner
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
      buildString: update.versionString,
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
    TelemetryService.shared.flushTelemetry()
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
    TelemetryService.shared.flushTelemetry()
    // Returning false lets Sparkle's automatic install-on-quit proceed normally.
    return false
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
    TelemetryService.shared.updateSparkleCycleFinished(
      version: version,
      isCritical: isCritical,
      source: source,
      errorCode: errorCode
    )
    if error != nil {
      TelemetryService.shared.updateInstallFailed(
        version: version,
        isCritical: isCritical,
        source: source,
        errorCode: errorCode ?? "unknown"
      )
    }
    // Issue #739: do NOT call noteResolved here. Sparkle's "cycle finished"
    // fires on cancel/skip/error/install-on-quit-scheduled alike. Widget state
    // is cleared only when bundle version catches up (rehydratePendingIfNewer
    // on next launch). In-session, the existing 5s resolvingWatchdog in
    // triggerInstall restores .available if the user clicked the widget but
    // did not complete an install.
    updateCoordinator?.lastInstallSource = nil
  }
}
