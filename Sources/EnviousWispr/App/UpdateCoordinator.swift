import EnviousWisprCore
import EnviousWisprServices
import Foundation
import Sparkle
import SwiftUI

/// App-target coordinator for the in-app update banner (issue #343).
/// Owns the `UpdateAvailabilityService` and the `installAction` closure that
/// invokes Sparkle. Limb classification: keeps update-banner state OFF `AppState`
/// (whose 19-collaborator ceiling is enforced by `AppStateCeilingsTests`).
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
public final class UpdateCoordinatorHolder {
  var coordinator: UpdateCoordinator?
  public init() {}
}
