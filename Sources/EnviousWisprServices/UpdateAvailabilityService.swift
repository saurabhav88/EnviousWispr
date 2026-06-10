import Foundation
import Observation

/// Limb-tier service that owns "is there an update ready?" state for the in-app
/// update banner (issue #343). Pure Foundation/Observation — does NOT import
/// Sparkle. AppDelegate (app target) injects the `installAction` closure that
/// invokes Sparkle when the user clicks the banner.
@MainActor
@Observable
public final class UpdateAvailabilityService {
  // MARK: - Public types

  public struct AvailableUpdate: Sendable, Equatable {
    public let versionString: String  // CFBundleVersion (canonical compare key)
    public let displayVersion: String  // CFBundleShortVersionString (UI copy)
    public let isCriticalUpdate: Bool

    public init(
      versionString: String,
      displayVersion: String,
      isCriticalUpdate: Bool
    ) {
      self.versionString = versionString
      self.displayVersion = displayVersion
      self.isCriticalUpdate = isCriticalUpdate
    }
  }

  public enum UpdateState: Equatable {
    case none
    case available(AvailableUpdate)
    case resolving
  }

  // MARK: - Constants

  static let resolvingWatchdogDuration: TimeInterval = 5.0

  // Namespaced UserDefaults keys (issue #343).
  public static let kPendingVersion = "com.enviouswispr.updateBanner.pendingVersion"
  public static let kPendingBuild = "com.enviouswispr.updateBanner.pendingBuild"
  public static let kPendingTimestamp = "com.enviouswispr.updateBanner.pendingTimestamp"
  public static let kDismissedVersion = "com.enviouswispr.updateBanner.dismissedVersion"
  /// Issue #739: persist the critical-update flag so rehydrate on next launch
  /// can correctly leave the UX to Sparkle (banner is suppressed for critical
  /// updates per `shouldShowBanner`). Pre-#739 the flag was lost across
  /// launches and a critical update could surface as a gentle banner.
  public static let kPendingCritical = "com.enviouswispr.updateBanner.pendingCritical"

  // MARK: - Observable state

  public private(set) var state: UpdateState = .none
  public private(set) var dismissedForSession: Bool = false

  // MARK: - Internal storage (not observed)

  @ObservationIgnored private var resolvingWatchdog: Task<Void, Never>?
  @ObservationIgnored private let installAction: @MainActor () -> Void
  @ObservationIgnored private let defaults: UserDefaults
  @ObservationIgnored private let currentBundleVersion: String

  /// #1019: AppKit-facing change hook (the `@Observable` macro only notifies
  /// SwiftUI dependency tracking; AppKit consumers — the menu-bar icon, the
  /// once-per-version notification — get no callback from it). Mirrors the
  /// `SettingsManager.onChange` / `PermissionsService.onAccessibilityChange`
  /// single-slot pattern. Fired from every `state` mutation.
  @ObservationIgnored public var onAvailabilityChange: (() -> Void)?

  // MARK: - Init

  public init(
    installAction: @escaping @MainActor () -> Void,
    defaults: UserDefaults = .standard,
    currentBundleVersion: String
  ) {
    self.installAction = installAction
    self.defaults = defaults
    self.currentBundleVersion = currentBundleVersion
    rehydratePendingIfNewer()
  }

  // MARK: - Visibility predicate

  public var shouldShowBanner: Bool {
    guard case .available(let u) = state else { return false }
    if u.isCriticalUpdate { return false }  // critical → Sparkle owns UX
    // Issue #739: widget visibility is bundle-version-driven only. No
    // recording-hide, no grace timer, no flicker. dismissedForSession is
    // retained as defense-in-depth against legacy kDismissedVersion residue
    // (rehydratePendingIfNewer purges it on launch).
    return !dismissedForSession
  }

  // MARK: - Sparkle-driven mutations

  /// Called from `standardUserDriverWillHandleShowingUpdate` (or rehydrate on launch).
  public func noteAvailable(_ update: AvailableUpdate) {
    // Same-version re-fire is a no-op (preserves dismissal state).
    if case .available(let existing) = state, existing == update { return }

    // While `.resolving`, only react to a strictly-newer version.
    if case .resolving = state {
      if let inflight = persistedPending(),
        compareVersions(update.versionString, inflight.versionString) <= 0
      {
        return
      }
      resolvingWatchdog?.cancel()
      resolvingWatchdog = nil
    }

    state = .available(update)
    dismissedForSession = (defaults.string(forKey: Self.kDismissedVersion) == update.versionString)
    persist(update)
    onAvailabilityChange?()
  }

  /// Public API retained for tests; no in-app caller post-#739. Sparkle's
  /// cycle-finish callback no longer invokes this — widget state is cleared by
  /// `rehydratePendingIfNewer` when the bundle version catches up to pending.
  // periphery:ignore - test seam
  public func noteResolved(installedVersion: String?) {
    state = .none
    dismissedForSession = false
    resolvingWatchdog?.cancel()
    resolvingWatchdog = nil
    clearPersisted()
    onAvailabilityChange?()
  }

  // MARK: - User-driven mutations

  // periphery:ignore - test seam
  public func dismissForSession() {
    dismissedForSession = true
    if case .available(let u) = state {
      defaults.set(u.versionString, forKey: Self.kDismissedVersion)
    }
  }

  public func triggerInstall() {
    state = .resolving
    onAvailabilityChange?()
    installAction()
    // Watchdog: if no terminal signal arrives within 5s, restore .available so
    // the user can retry. Keeps the banner from getting stuck if Sparkle no-ops.
    resolvingWatchdog?.cancel()
    resolvingWatchdog = Task { [weak self] in
      try? await Task.sleep(for: .seconds(Self.resolvingWatchdogDuration))
      guard !Task.isCancelled else { return }
      await MainActor.run {
        guard let self else { return }
        if case .resolving = self.state, let pending = self.persistedPending() {
          self.state = .available(pending)
          self.onAvailabilityChange?()
        }
      }
    }
  }

  // MARK: - Persistence helpers

  func persist(_ update: AvailableUpdate) {
    defaults.set(update.versionString, forKey: Self.kPendingVersion)
    defaults.set(update.displayVersion, forKey: Self.kPendingBuild)
    defaults.set(Date().timeIntervalSince1970, forKey: Self.kPendingTimestamp)
    // Issue #739: persist the critical flag so Sparkle's heavy UX path is
    // preserved across launches; the gentle banner stays suppressed.
    defaults.set(update.isCriticalUpdate, forKey: Self.kPendingCritical)
  }

  func persistedPending() -> AvailableUpdate? {
    guard let v = defaults.string(forKey: Self.kPendingVersion) else { return nil }
    let display = defaults.string(forKey: Self.kPendingBuild) ?? v
    // Issue #739: rehydrate the critical flag. Defaults to false if the key
    // is absent (older builds, never-persisted updates) — keeps backward-compat.
    let isCritical = defaults.bool(forKey: Self.kPendingCritical)
    return AvailableUpdate(
      versionString: v,
      displayVersion: display,
      isCriticalUpdate: isCritical
    )
  }

  func clearPersisted() {
    defaults.removeObject(forKey: Self.kPendingVersion)
    defaults.removeObject(forKey: Self.kPendingBuild)
    defaults.removeObject(forKey: Self.kPendingTimestamp)
    defaults.removeObject(forKey: Self.kDismissedVersion)
    defaults.removeObject(forKey: Self.kPendingCritical)
  }

  func rehydratePendingIfNewer() {
    guard let pending = persistedPending() else { return }
    let cmp = compareVersions(pending.versionString, currentBundleVersion)
    if cmp > 0 {
      state = .available(pending)
      // Issue #739: post-#739 no in-app caller invokes dismissForSession, so
      // kDismissedVersion can only exist as residue from a pre-#739 buggy
      // didReceiveUserAttention callback. Purge it on rehydrate so the widget
      // is not silently suppressed by historical state.
      defaults.removeObject(forKey: Self.kDismissedVersion)
      dismissedForSession = false
      onAvailabilityChange?()
    } else {
      // Bundle has caught up to or surpassed pending — user installed by some path.
      clearPersisted()
    }
  }

  // MARK: - Version comparator

  /// Compares two CFBundleVersion strings (e.g. "2.4.0" vs "2.4.1").
  /// Production tags are enforced `^[0-9]+\.[0-9]+\.[0-9]+$` per release.yml,
  /// so a simple split-by-dot integer compare is sufficient.
  /// Returns: -1 if a < b, 0 if equal, +1 if a > b.
  public func compareVersions(_ a: String, _ b: String) -> Int {
    let aParts = a.split(separator: ".").map { Int($0) ?? 0 }
    let bParts = b.split(separator: ".").map { Int($0) ?? 0 }
    let count = max(aParts.count, bParts.count)
    for i in 0..<count {
      let av = i < aParts.count ? aParts[i] : 0
      let bv = i < bParts.count ? bParts[i] : 0
      if av < bv { return -1 }
      if av > bv { return 1 }
    }
    return 0
  }
}
