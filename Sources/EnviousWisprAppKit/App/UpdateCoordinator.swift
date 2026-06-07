import EnviousWisprCore
import EnviousWisprServices
import Foundation
@preconcurrency import Sparkle
import SwiftUI

/// Issue #958: narrow test seam over the subset of `SPUUpdater` the proactive
/// check reads/calls. `SPUUpdater.init` is `NS_UNAVAILABLE` and real
/// construction touches defaults/appcast/signing, so `checkForUpdatesProactively`
/// depends on this protocol; the real `SPUUpdater` satisfies it via the
/// isolated conformance below, and `UpdateCoordinatorProactiveCheckTests`
/// injects a fake. All members are main-thread-only (Sparkle requirement), so
/// the protocol is `@MainActor`.
@MainActor
protocol ProactiveUpdaterProbe: AnyObject {
  var automaticallyChecksForUpdates: Bool { get }
  var lastUpdateCheckDate: Date? { get }
  var sessionInProgress: Bool { get }
  func checkForUpdatesInBackground()
}

/// Isolated conformance (per swift-concurrency-patterns isolated-conformance-first):
/// pins satisfaction to `@MainActor` without widening `SPUUpdater`'s contract.
@MainActor extension SPUUpdater: ProactiveUpdaterProbe {}

/// App-target coordinator for the in-app update banner (issue #343).
/// Owns the `UpdateAvailabilityService` and the `installAction` closure that
/// invokes Sparkle. Limb classification: keeps update-banner state in a
/// dedicated home rather than a shared state bag (epic #763).
@MainActor
final class UpdateCoordinator {
  let service: UpdateAvailabilityService

  /// Set by entry points (banner click, menu wrapper, default-modal delegate,
  /// install-on-quit delegate) so cross-launch correlation can attribute
  /// `update.install_completed` / `update.install_cancelled` to a source.
  var lastInstallSource: String?

  // Cross-launch correlation persistence keys.
  private static let kLastAttemptVersion = "com.enviouswispr.updateBanner.lastAttemptVersion"
  private static let kLastAttemptTimestamp = "com.enviouswispr.updateBanner.lastAttemptTimestamp"
  private static let kLastAttemptSource = "com.enviouswispr.updateBanner.lastAttemptSource"

  // In-memory dedup for `update.banner_shown` (per app launch, per version).
  private var bannerShownReportedVersions: Set<String> = []

  private weak var updaterController: SPUStandardUpdaterController?
  private let defaults: UserDefaults

  init(updaterController: SPUStandardUpdaterController?, defaults: UserDefaults = .standard) {
    self.updaterController = updaterController
    self.defaults = defaults
    self.service = UpdateAvailabilityService(
      installAction: { [weak updaterController] in
        updaterController?.checkForUpdates(nil)
      },
      defaults: defaults,
      currentBundleVersion: AppConstants.appVersion
    )
  }

  // MARK: - Proactive update checks (issue #958)

  /// Cooldown between proactive background checks, anchored on Sparkle's own
  /// `lastUpdateCheckDate`. 1h matches the scheduled cadence (`SUScheduledCheckInterval`),
  /// which is also Sparkle's enforced minimum interval.
  static let proactiveCheckCooldown: TimeInterval = 3600

  /// Issue #958: proactive, cooldown-gated background update check. Fires
  /// Sparkle's BACKGROUND driver (→ gentle banner via the user-driver delegate
  /// for non-critical updates), NOT the attended `checkForUpdates`. Called on
  /// launch (right after `startUpdater()`) and on app-foreground. Returns
  /// whether a check was actually triggered (for tests + telemetry).
  ///
  /// The `automaticallyChecksForUpdates` guard is a PRODUCT choice (respect a
  /// user who explicitly opted out), not a Sparkle requirement — the direct
  /// background call would run regardless. The cooldown is anchored on
  /// `lastUpdateCheckDate` so launch / foreground / scheduled checks coalesce
  /// (Sparkle also no-ops a background check while a session is in progress).
  @discardableResult
  func checkForUpdatesProactively(
    trigger: String,
    now: Date = Date(),
    probe: (any ProactiveUpdaterProbe)? = nil
  ) -> Bool {
    let resolved: (any ProactiveUpdaterProbe)? = probe ?? updaterController?.updater
    guard let updater = resolved else {
      reportProactive(trigger: trigger, fired: false, reason: "no_updater")
      return false
    }
    guard updater.automaticallyChecksForUpdates else {
      reportProactive(trigger: trigger, fired: false, reason: "auto_checks_off")
      return false
    }
    // Sparkle no-ops `checkForUpdatesInBackground` while a session is already in
    // progress (SPUUpdater.m:664-667 / SPUUpdater.h:130). Skip here so we never
    // claim `fired=true` for a call that would do nothing.
    guard !updater.sessionInProgress else {
      reportProactive(trigger: trigger, fired: false, reason: "session_in_progress")
      return false
    }
    let elapsed =
      updater.lastUpdateCheckDate.map { now.timeIntervalSince($0) } ?? .greatestFiniteMagnitude
    guard elapsed >= Self.proactiveCheckCooldown else {
      reportProactive(trigger: trigger, fired: false, reason: "cooldown")
      return false
    }
    reportProactive(trigger: trigger, fired: true, reason: "fired")
    updater.checkForUpdatesInBackground()
    return true
  }

  /// Emits telemetry on EVERY proactive-check return path (bounded `reason`:
  /// fired / cooldown / auto_checks_off / no_updater / session_in_progress) plus
  /// an `.info` breadcrumb in `~/Library/Logs/EnviousWispr/app.log` for field
  /// diagnosis + runtime UAT. `.info` (not `.debug`) so the line is not filtered
  /// out by the file-sink log level. The breadcrumb is an unstructured `Task`
  /// (AppLogger is an actor, this is a sync @MainActor method); a single
  /// fire-and-forget log emit cannot affect the update limb.
  private func reportProactive(trigger: String, fired: Bool, reason: String) {
    TelemetryService.shared.updateProactiveCheckTriggered(
      trigger: trigger, fired: fired, reason: reason)
    Task {
      await AppLogger.shared.log(
        "proactive check trigger=\(trigger) fired=\(fired) reason=\(reason)",
        level: .info, category: "Update")
    }
  }

  /// Issue #958: user-initiated attended check from the Settings "Check for
  /// Updates" row (§3D). Mirrors the menu wrapper
  /// (`SparkleUpdateController.openUpdateCheckFromMenu`) but tags the source
  /// `"settings"`. Shows Sparkle's own check UI ("Checking… / up to date /
  /// update available").
  func checkForUpdatesFromSettings() {
    lastInstallSource = "settings"
    updaterController?.checkForUpdates(nil)
  }

  // MARK: - Install-attempt persistence (cross-launch correlation)

  /// Persists "we just kicked off an install" so the next launch can decide
  /// whether to fire `update.install_completed` or `update.install_cancelled`.
  /// Independent of whether the click-time PostHog event survived relaunch.
  func recordInstallAttempt(version: String, source: String) {
    defaults.set(version, forKey: Self.kLastAttemptVersion)
    defaults.set(Date().timeIntervalSince1970, forKey: Self.kLastAttemptTimestamp)
    defaults.set(source, forKey: Self.kLastAttemptSource)
  }

  /// Called early in `applicationDidFinishLaunching`. Reads the lastAttempt
  /// keys, compares to current bundle, and tells the caller which event to
  /// fire (if any). Clears keys after.
  func evaluateLastInstallAttempt(currentBundleVersion: String) -> InstallAttemptOutcome {
    guard
      let attemptVersion = defaults.string(forKey: Self.kLastAttemptVersion),
      let attemptSource = defaults.string(forKey: Self.kLastAttemptSource)
    else {
      return .none
    }
    let attemptTs = defaults.double(forKey: Self.kLastAttemptTimestamp)
    let elapsed = Date().timeIntervalSince1970 - attemptTs

    defer {
      defaults.removeObject(forKey: Self.kLastAttemptVersion)
      defaults.removeObject(forKey: Self.kLastAttemptTimestamp)
      defaults.removeObject(forKey: Self.kLastAttemptSource)
    }

    // Bundle version compare via the service's helper.
    let cmp = service.compareVersions(currentBundleVersion, attemptVersion)
    if cmp == 0 {
      // Bundle matches the attempted version exactly → install completed.
      return .completed(version: attemptVersion, source: attemptSource)
    }
    if cmp > 0 {
      // Bundle is even newer than what we attempted (user did manual DMG install
      // or a chained update). Don't claim attribution.
      return .unattributable
    }
    // Bundle unchanged.
    if elapsed < 3600 {
      return .cancelled(version: attemptVersion, source: attemptSource)
    }
    return .stale  // user quit before Sparkle finished; not actionable
  }

  // MARK: - Banner-driven entry points (called from UpdateAvailableBanner)

  /// Banner `.onAppear`. Fires `update.banner_shown` once per (version, app launch).
  func handleBannerShown(version: String, isCritical: Bool, dismissedPreviously: Bool) {
    guard !bannerShownReportedVersions.contains(version) else { return }
    bannerShownReportedVersions.insert(version)
    let secondsSinceAvailable = Int(
      Date().timeIntervalSince1970
        - defaults.double(forKey: UpdateAvailabilityService.kPendingTimestamp)
    )
    TelemetryService.shared.updateBannerShown(
      version: version,
      isCritical: isCritical,
      dismissedPreviously: dismissedPreviously,
      secondsSinceAvailable: max(0, secondsSinceAvailable)
    )
  }

  /// Banner click. Tags source, persists install attempt, fires telemetry,
  /// flushes PostHog (so the event survives Sparkle's relaunch), then triggers
  /// the install via the service.
  func handleBannerClicked(version: String, isCritical: Bool, secondsVisible: Int) {
    lastInstallSource = "banner"
    recordInstallAttempt(version: version, source: "banner")
    TelemetryService.shared.updateBannerClicked(
      version: version,
      isCritical: isCritical,
      secondsVisible: secondsVisible
    )
    TelemetryService.shared.flushTelemetry()
    service.triggerInstall()
  }

  enum InstallAttemptOutcome: Equatable {
    case none
    case completed(version: String, source: String)
    case cancelled(version: String, source: String)
    case unattributable
    case stale
  }
}

// MARK: - SwiftUI Environment injection (issue #739)

/// Stable `@Observable` wrapper around the coordinator instance. We can't pass
/// the optional coordinator directly into SwiftUI's environment because
/// `appDelegate.updateCoordinator` is nil at the moment SwiftUI evaluates the
/// App body and captures the env value (delegate methods run after scene
/// construction). The holder is a stable instance whose `coordinator`
/// property goes from nil → non-nil once AppDelegate finishes init; the
/// `@Observable` macro guarantees SwiftUI re-evaluates dependent views when
/// the property changes.
@Observable
@MainActor
final class UpdateCoordinatorHolder {
  var coordinator: UpdateCoordinator?
  init() {}
}
