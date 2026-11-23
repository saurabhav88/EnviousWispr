import Foundation

/// The ONE owner of which preferences domain the build-shared settings live in (#923, #4596).
/// It decides routing only: keys, defaults, migrations and feature behaviour stay with their
/// owners. Kept narrow on purpose (#923 grounded review): only these populations belong in the
/// shared domain, and caches, TCC state and debug settings stay per-build on `.standard`:
/// - user settings (`SettingsManager`);
/// - model-delivery override flags (`DeliveryFlags`);
/// - local-polish paused-install projections (`LocalPolishRuntime`: `eg1.`, `eg1.mini.`,
///   `eg1.micro.`, `s1.` prefixes).
///
/// Routing by bundle identifier:
/// - Release (`com.enviouswispr.app`): its own domain IS `sharedSuite`, so `.standard`.
/// - Dev build (`com.enviouswispr.app.dev`): redirects to the shared suite, so both builds
///   read and write `~/Library/Preferences/com.enviouswispr.app.plist` (non-sandboxed).
/// - Anything else (unit-test runners, previews, a renamed measurement copy): its own
///   `.standard` domain, so no other bundle ever opens the production domain by name.
///
/// Apple prohibits passing the current app's own bundle identifier as a suite name; only the
/// exact dev identifier opens the suite, so Release never does. If opening the suite fails,
/// the dev build falls back to `.standard` as before. Mirrors the bundle allowlist
/// `KeychainManager` uses for secrets (a separate concern, left there).
package enum SettingsDefaults {
  private static let sharedSuite = "com.enviouswispr.app"
  package static let devBundleID = "com.enviouswispr.app.dev"

  /// The named suite a bundle must open, or nil when its own `.standard` domain is correct.
  /// Pure, so routing is testable without writing any preferences.
  package static func domainName(forBundle bundleIdentifier: String?) -> String? {
    bundleIdentifier == devBundleID ? sharedSuite : nil
  }

  package static var store: UserDefaults {
    guard let name = domainName(forBundle: Bundle.main.bundleIdentifier) else { return .standard }
    return UserDefaults(suiteName: name) ?? .standard
  }
}
