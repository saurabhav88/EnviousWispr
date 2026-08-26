import Foundation

/// Whether the focused element is a browser's URL/address bar, never merely
/// "is a text field inside a browser". #2258.
///
/// Two conditions, both required, in the same veto-first shape as
/// `TerminalSurface`: the owning app must be one of the handful of browsers
/// actually measured, and the element's OWN signature must match that
/// browser's address field. `AXRole`/`AXSubrole` alone cannot tell an address
/// bar from an ordinary field — both Chrome and Safari expose a bare
/// `AXTextField` with no subrole (measured live 2026-08-21) — so a browser not
/// in the allowlist never reaches the signature check at all, and an ordinary
/// web page text field inside a recognized browser (its `AXDOMClassList` is
/// whatever the page's own DOM renders, never the omnibox's) is refused by the
/// signature rather than by the app gate.
///
/// The app gate is deliberately checkable WITHOUT an accessibility call
/// (`family(forBundleIdentifier:)`, below), so a caller can reject an
/// unrecognized app before spending a cross-process AX round trip on it
/// (Codex review r1, #2258): every AX attribute read carries up to the
/// element's 0.5-second messaging timeout on failure, and this feature runs
/// on every smart-insertion paste, not only in a browser.
package enum BrowserAddressBarDetector {
  /// Which family of browser owns the focused element, and therefore which
  /// AX attribute is worth reading — never both, since each family exposes
  /// only its own signal. `nil` for anything not recognized at all.
  package enum Family: Sendable, Equatable {
    case safari
    case chromium
  }

  /// Safari/WebKit's fixed accessibility identifier for the field, measured
  /// 2026-08-21 live on Safari. AX identifiers are code constants, not
  /// translated strings.
  static let safariAddressBarIdentifier = "WEB_BROWSER_ADDRESS_AND_SEARCH_FIELD"

  private static let safariBundleIdentifiers: Set<String> = ["com.apple.safari"]

  /// Chromium's own view-class name for its address bar, measured 2026-08-21
  /// live on Chrome (`OmniboxViewViews`) and Brave (`BraveOmniboxViewViews`)
  /// via `AXDOMClassList`. A C++ class name from Chromium's shared views
  /// toolkit, not a translated string — unlike `AXDescription`
  /// ("Address and search bar" on both, measured identical), which IS a
  /// translated accessibility label and would silently disable this feature
  /// for every non-English system locale. Matched as a SUFFIX, not exact, so
  /// a vendor subclass (Brave's `Brave` prefix) still matches.
  static let chromiumOmniboxDOMClassSuffix = "OmniboxViewViews"

  /// Bundle identifiers measured, or confidently inferred, to expose the
  /// Chromium signature above.
  ///
  /// Chrome was measured directly. Brave was measured to confirm the
  /// signature generalizes to a vendor subclass rather than being
  /// Chrome-specific. Edge is included unmeasured: it is a Chromium fork
  /// with a strong track record of keeping upstream view-class names, and
  /// the suffix check already tolerates a renamed subclass — a false
  /// negative here costs nothing beyond today's behavior.
  ///
  /// Arc and Firefox are deliberately absent. Arc's address affordance is a
  /// materially different UI (a floating command bar, not a persistent
  /// field), and Firefox uses Gecko's accessibility layer, not Chromium's —
  /// neither is safe to assume from a Chromium measurement, and neither was
  /// installed on the measuring machine. Adding either needs its own live
  /// measurement, not an extension of this list by inference (#2258).
  private static let chromiumBundleIdentifiers: Set<String> = [
    "com.google.chrome",
    "com.brave.browser",
    "com.microsoft.edgemac",
  ]

  /// Every recognized bundle identifier, lowercased, across both families —
  /// for callers that only need "is this app worth asking at all", such as
  /// tests pinning what is deliberately absent.
  package static var recognizedBundleIdentifiers: Set<String> {
    safariBundleIdentifiers.union(chromiumBundleIdentifiers)
  }

  /// Which family owns `bundleIdentifier`, with NO accessibility call — the
  /// cheap half of the two-factor check, meant to run before any AX read.
  package static func family(forBundleIdentifier bundleIdentifier: String?) -> Family? {
    guard let bundleIdentifier else { return nil }
    let normalized = bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !normalized.isEmpty else { return nil }
    if safariBundleIdentifiers.contains(normalized) { return .safari }
    if chromiumBundleIdentifiers.contains(normalized) { return .chromium }
    return nil
  }

  /// - Parameters:
  ///   - bundleIdentifier: the bundle identifier of the app OWNING the
  ///     focused element — never the system's frontmost app, which can
  ///     differ from it (a focused element captured moments earlier, or a
  ///     system-wide read proxying to the wrong window).
  ///   - axIdentifier: `AXIdentifier` of the focused element, if readable.
  ///   - axDOMClassList: `AXDOMClassList` of the focused element, if the app
  ///     exposes it at all — Chromium browsers only; Safari and non-browser
  ///     apps report `nil`.
  package static func matches(
    bundleIdentifier: String?,
    axIdentifier: String?,
    axDOMClassList: [String]?
  ) -> Bool {
    switch family(forBundleIdentifier: bundleIdentifier) {
    case .safari:
      return axIdentifier == safariAddressBarIdentifier
    case .chromium:
      guard let axDOMClassList else { return false }
      return axDOMClassList.contains(where: { $0.hasSuffix(chromiumOmniboxDOMClassSuffix) })
    case nil:
      return false
    }
  }
}
