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

  /// #1019: persisted "we already fired the macOS notification for this version"
  /// marker, so the notification is once-per-version across relaunch.
  private static let kLastNotifiedVersion = "com.enviouswispr.updateBanner.lastNotifiedVersion"

  // In-memory dedup for `update.banner_shown` (per app launch, per version).
  private var bannerShownReportedVersions: Set<String> = []

  private weak var updaterController: SPUStandardUpdaterController?
  private let defaults: UserDefaults
  private let notifier: any UpdateNotifying

  /// #1019: refresh hook for the menu-bar surface. The menu-bar home sets this
  /// so the status-item icon flips to / from the "update waiting" cue the
  /// moment availability changes, even with no window or menu open.
  var onAvailabilityChange: (() -> Void)?

  /// #1019: reads whether dictation is currently active (recording / loading /
  /// transcribing / polishing) so the install affordances never relaunch the
  /// app mid-capture. Wired in `WisprBootstrapper` to `LiveRecordingState`.
  var dictationActiveProvider: (() -> Bool)?

  /// #1019: when the last update-check cycle FINISHED having reached the feed
  /// (update found, none found, or user-cancelled install). Nil until the first
  /// such outcome. A genuine network/parse failure does NOT update this, so the
  /// event-driven cooldown is not consumed and the next wake/network trigger
  /// re-checks.
  private(set) var lastCheckOutcomeAt: Date?

  init(
    updaterController: SPUStandardUpdaterController?,
    defaults: UserDefaults = .standard,
    notifier: (any UpdateNotifying)? = nil
  ) {
    self.updaterController = updaterController
    self.defaults = defaults
    self.notifier = notifier ?? UpdateNotificationPresenter()
    self.service = UpdateAvailabilityService(
      installAction: { [weak updaterController] in
        updaterController?.checkForUpdates(nil)
      },
      defaults: defaults,
      currentBundleVersion: AppConstants.appVersion
    )
    // #1019: react to every availability change — fire the once-per-version
    // notification and refresh the menu-bar icon.
    self.service.onAvailabilityChange = { [weak self] in
      self?.handleAvailabilityChanged()
    }
    // Route a notification tap through the active-dictation guard.
    self.notifier.onInstallTapped = { [weak self] in
      self?.handleNotificationInstallTapped()
    }
    // #1019 (Codex P1): `rehydratePendingIfNewer()` runs INSIDE the service
    // initializer above — before this hook is installed. So a persisted-pending
    // update newer than the current bundle would set `.available` with the hook
    // still nil and miss its once-per-version notification (and a later
    // same-version `noteAvailable` returns early). Replay the current
    // availability now that the hook is live; the per-version marker keeps this
    // idempotent across relaunch.
    if case .available = service.state {
      handleAvailabilityChanged()
    }
  }

  // MARK: - Proactive update checks (issue #958)

  /// Cooldown for the `launch` trigger, anchored on Sparkle's own
  /// `lastUpdateCheckDate`. 1h matches the scheduled cadence (`SUScheduledCheckInterval`),
  /// which is also Sparkle's enforced minimum interval. Launch coalesces with
  /// Sparkle's scheduled background checks across relaunch.
  static let proactiveCheckCooldown: TimeInterval = 3600

  /// #1019: cooldown for the event-driven triggers (`foreground`/`wake`/
  /// `network`). Anchored on `UpdateCoordinator`'s OWN outcome timestamp
  /// (`lastCheckOutcomeAt`), NOT Sparkle's `lastUpdateCheckDate` — Sparkle
  /// stamps its date when the driver *starts* (before the outcome is known), so
  /// it cannot distinguish a failed check from a successful one. 30 min gives an
  /// always-on user near-current freshness on wake/reconnect without hammering
  /// the feed; Sparkle's hourly scheduled check remains the floor.
  static let foregroundCheckCooldown: TimeInterval = 1800

  /// Triggers gated on the local outcome-aware cooldown (vs `launch`, which
  /// stays on Sparkle's check-date).
  private static let outcomeAwareTriggers: Set<String> = ["foreground", "wake", "network"]

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
    // #1019: event-driven triggers gate on the local outcome-aware timestamp;
    // `launch` keeps Sparkle's check-date anchor (coalesces with scheduled
    // background checks across relaunch).
    let elapsed: TimeInterval
    let cooldown: TimeInterval
    if Self.outcomeAwareTriggers.contains(trigger) {
      elapsed = lastCheckOutcomeAt.map { now.timeIntervalSince($0) } ?? .greatestFiniteMagnitude
      cooldown = Self.foregroundCheckCooldown
    } else {
      elapsed =
        updater.lastUpdateCheckDate.map { now.timeIntervalSince($0) } ?? .greatestFiniteMagnitude
      cooldown = Self.proactiveCheckCooldown
    }
    guard elapsed >= cooldown else {
      reportProactive(trigger: trigger, fired: false, reason: "cooldown")
      return false
    }
    reportProactive(trigger: trigger, fired: true, reason: "fired")
    updater.checkForUpdatesInBackground()
    return true
  }

  /// #1019: records the outcome of an update-check cycle (called from
  /// `SparkleUpdateController.didFinishUpdateCycleFor`). `success` means the
  /// cycle reached the feed — update found, none found, or user-cancelled
  /// install — vs a genuine network/parse failure. Only a successful outcome
  /// consumes the event-driven cooldown; a failure leaves `lastCheckOutcomeAt`
  /// untouched so the next wake/network trigger re-checks instead of waiting
  /// out a cooldown that was never earned.
  func recordUpdateCheckOutcome(success: Bool, at date: Date = Date()) {
    guard success else { return }
    lastCheckOutcomeAt = date
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

  // MARK: - Availability surfaces (#1019)

  /// Fired on every `UpdateAvailabilityService.state` mutation. Fires the
  /// once-per-version macOS notification (non-critical only) and re-publishes
  /// to the menu-bar icon-refresh hook.
  private func handleAvailabilityChanged() {
    fireUpdateNotificationIfNeeded()
    onAvailabilityChange?()
  }

  /// Posts exactly one macOS notification per newly-available non-critical
  /// version. Critical updates route to Sparkle's own UX, so they get no gentle
  /// notification. The per-version marker persists across relaunch so a
  /// rehydrated pending state does not re-fire.
  private func fireUpdateNotificationIfNeeded() {
    guard case .available(let update) = service.state, !update.isCriticalUpdate else { return }
    guard defaults.string(forKey: Self.kLastNotifiedVersion) != update.versionString else { return }
    defaults.set(update.versionString, forKey: Self.kLastNotifiedVersion)
    notifier.post(displayVersion: update.displayVersion)
  }

  /// #1029: install the notification tap delegate eagerly at launch, decoupled
  /// from posting. Called once from `WisprBootstrapper.applicationWillFinishLaunching`
  /// (NOT from `init`, which runs in unit tests and must keep the notifier inert).
  /// Without this, a relaunch where the pending update matches the last-notified
  /// version returns from `fireUpdateNotificationIfNeeded` before `post`, leaving
  /// the delegate uninstalled — so a tap on the already-delivered notification (or
  /// a cold launch from it) would route nowhere.
  func activateNotificationTapRouting() {
    notifier.activateTapRouting()
  }

  /// Install entry from the menu-bar "update ready" item. Guarded on active
  /// dictation (defense-in-depth — the item is also disabled in that state).
  func installFromMenu() {
    triggerGuardedInstall(source: "menu_update_item")
  }

  /// Install entry from a notification tap. Guarded on active dictation so a
  /// tap mid-dictation never relaunches the app and destroys in-flight work;
  /// the user can tap again once dictation ends.
  private func handleNotificationInstallTapped() {
    triggerGuardedInstall(source: "notification")
  }

  private func triggerGuardedInstall(source: String) {
    guard !(dictationActiveProvider?() ?? false) else { return }
    // #1029: only install when an update is actually available. With the tap
    // delegate now active on every launch, a tap on a STALE delivered
    // notification (its version already installed, pending state cleared by
    // rehydrate) must not start a spurious Sparkle check — `triggerInstall()`
    // flips the surface to `.resolving` and, with nothing persisted, the
    // watchdog cannot restore it, wedging the menu-bar cue. Menu/banner
    // affordances render only while `.available`, so this is a no-op for them.
    guard case .available(let update) = service.state else { return }
    lastInstallSource = source
    recordInstallAttempt(version: update.versionString, source: source)
    service.triggerInstall()
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
