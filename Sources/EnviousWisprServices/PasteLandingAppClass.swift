import Foundation

/// How a paste destination exposes its text, as a closed class for analytics (#3106): one owner
/// for the decision the learn watcher made inline, now shared with the paste landing check.
///
/// Never which app it is: the answer is `browser`, `manual_accessibility` or `native`, the values of
/// `TelemetryService.LearnFromEditsTelemetry.AppClass`. `other` is not produced here; it stays the
/// watcher's sentinel for a take that never captured a target.
package enum PasteLandingAppClass {

  /// A recognised browser wins, even when it is also a manual-accessibility host (every Chromium
  /// browser is one); another manual-accessibility host is `manualAccessibility`; everything else
  /// is `native`. The browser authority is `BrowserAddressBarDetector.family`, never a copied list.
  package static func classify(bundleIdentifier: String?, isManualAccessibilityHost: Bool)
    -> TelemetryService.LearnFromEditsTelemetry.AppClass
  {
    if BrowserAddressBarDetector.family(forBundleIdentifier: bundleIdentifier) != nil {
      return .browser
    }
    return isManualAccessibilityHost ? .manualAccessibility : .native
  }
}
