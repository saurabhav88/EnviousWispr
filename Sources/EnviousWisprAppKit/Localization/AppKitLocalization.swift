import Foundation

/// #3142: the one bundle every AppKit interface-string lookup names.
///
/// `EnviousWisprAppKit` is a static framework, so its resources (including
/// `Localizable.xcstrings`) ship in a companion bundle, not in `Bundle.main`.
/// SwiftUI `Text("literal")` and `String(localized:)` default to `Bundle.main`
/// and would silently render the English default, so lookups pass this bundle.
/// `#bundle` is not used: measured 2026-09-24 in the Tuist test build it resolved
/// to the containing binary's bundle and missed the catalog (plan S2).
enum AppKitLocalization {
  static var bundle: Bundle { .module }
}
