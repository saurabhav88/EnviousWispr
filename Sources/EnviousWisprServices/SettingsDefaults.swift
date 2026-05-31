import Foundation

/// Resolves the `UserDefaults` store that backs user preferences. Kept narrow
/// (Services-internal, not a Core-wide `UserDefaults` extension) so only the
/// settings layer can reach the shared suite — grounded review flagged a
/// Core-wide accessor as a footgun for future cache/TCC/debug code (#923).
///
/// Both builds resolve to the SAME store (`com.enviouswispr.app`):
/// - Release build: its own bundle id IS `sharedSuite`, so `.standard`.
/// - Dev build (`com.enviouswispr.app.dev`): redirects to the shared suite.
///
/// Non-sandboxed (verified: no `app-sandbox` entitlement), so opening another
/// domain by name reads/writes the shared CFPreferences plist at
/// `~/Library/Preferences/com.enviouswispr.app.plist`. Mirrors the prod/dev
/// bundle-id branch `KeychainManager` already uses. The explicit bundle-id
/// check sidesteps the documented `UserDefaults(suiteName:)`-returns-nil-on-
/// own-bundle-id quirk; nil falls back to `.standard` (per-build, no worse than
/// today) and the migration logs the degradation.
enum SettingsDefaults {
  static let sharedSuite = "com.enviouswispr.app"
  static let devBundleID = "com.enviouswispr.app.dev"

  static var store: UserDefaults {
    // ONLY the dev build redirects to the shared suite. Release (its own id IS
    // sharedSuite), the unit-test runner, and SwiftUI previews all use
    // `.standard` — so tests never touch the production `com.enviouswispr.app`
    // store, and release behavior is unchanged. Explicit dev-id gate (not a
    // fall-through) is what makes that safe.
    guard Bundle.main.bundleIdentifier == devBundleID else { return .standard }
    return UserDefaults(suiteName: sharedSuite) ?? .standard
  }
}
