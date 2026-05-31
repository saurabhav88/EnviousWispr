import EnviousWisprCore
import Foundation

/// One-time, effective-state migration that seeds the shared settings store
/// (`SettingsDefaults.store`) from the dev build's current state when the dev
/// build's identity was split off the release identity (#913 PR2/PR4 gave the
/// dev build `com.enviouswispr.app.dev`, splitting its `UserDefaults` away from
/// the release `com.enviouswispr.app`). #923 reunifies them.
///
/// Effective-state, not copy-present-keys: for each unified key, an explicit dev
/// value carries over (custom is custom); a key the dev store LACKS is CLEARED
/// from the shared store so the canonical default re-applies. Clearing is what
/// kills a stale shared value (e.g. an old F8 record-key) the dev build never set.
///
/// Sentinel lives in the DEV store, not the shared store, so wiping the release
/// store (`defaults delete com.enviouswispr.app`) cannot resurrect stale dev
/// values on the next dev launch.
public enum SettingsDefaultsMigration {
  /// Marker that this dev install has yielded its values to the shared store.
  /// Stored in the dev build's OWN store (`UserDefaults.standard`).
  static let devSentinelKey = "didYieldToSharedDefaults_v1"

  /// Single source of truth for which keys unify — owned by `SettingsManager`.
  static var unifiedKeys: [String] { SettingsManager.unifiedDefaultsKeys }

  /// Idempotent, release-safe. MUST run before any `SettingsManager` is built
  /// (it mutates the store `SettingsManager` will read). Defaults are injectable
  /// for tests; production uses the real stores.
  public static func migrateIfNeeded(
    bundleID: String? = Bundle.main.bundleIdentifier,
    devStore: UserDefaults = .standard,
    shared: UserDefaults? = nil
  ) {
    let shared = shared ?? SettingsDefaults.store
    // ONLY the dev build migrates — matches SettingsDefaults.store's dev-id gate.
    // Release/shipped (its store IS the shared store) and any other identity
    // (test runner, previews) are no-ops: nothing to migrate, no sentinel written.
    guard bundleID == SettingsDefaults.devBundleID else { return }
    // Once per dev install.
    guard !devStore.bool(forKey: devSentinelKey) else { return }

    var copied = 0
    var cleared = 0
    for key in unifiedKeys {
      if let value = devStore.object(forKey: key) {
        shared.set(value, forKey: key)  // explicit dev value wins
        copied += 1
      } else if shared.object(forKey: key) != nil {
        shared.removeObject(forKey: key)  // dev rode the default → clear stale shared
        cleared += 1
      }
    }
    devStore.set(true, forKey: devSentinelKey)

    // Privacy-safe: counts + action only, never values.
    let copiedCount = copied
    let clearedCount = cleared
    Task {
      await AppLogger.shared.log(
        "settings unify migration: copied \(copiedCount), cleared \(clearedCount)",
        level: .info,
        category: "Settings"
      )
    }
  }
}
