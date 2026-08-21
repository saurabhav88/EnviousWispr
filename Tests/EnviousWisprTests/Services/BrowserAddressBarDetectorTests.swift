import Testing

@testable import EnviousWisprServices

// #2258: whether the focused element is a browser's URL/address bar. Product
// outcome — when this misses, the user gets a trailing space that blocks
// pressing Enter to navigate; when it misfires on an ordinary web field, the
// user silently loses a space they dictated.
@Suite("BrowserAddressBarDetector", .tags(.productOutcome))
struct BrowserAddressBarDetectorTests {

  @Test("Safari's fixed AXIdentifier matches")
  func safariIdentifierMatches() {
    #expect(
      BrowserAddressBarDetector.matches(
        bundleIdentifier: "com.apple.Safari",
        axIdentifier: "WEB_BROWSER_ADDRESS_AND_SEARCH_FIELD",
        axDOMClassList: nil))
  }

  @Test("Chrome's exact Chromium DOM class matches")
  func chromeDOMClassMatches() {
    #expect(
      BrowserAddressBarDetector.matches(
        bundleIdentifier: "com.google.Chrome",
        axIdentifier: nil,
        axDOMClassList: ["OmniboxViewViews"]))
  }

  @Test("Brave's vendor-subclassed DOM class matches via suffix")
  func braveVendorSubclassMatches() {
    #expect(
      BrowserAddressBarDetector.matches(
        bundleIdentifier: "com.brave.Browser",
        axIdentifier: nil,
        axDOMClassList: ["BraveOmniboxViewViews"]))
  }

  @Test("bundle identifier comparison is case-insensitive")
  func bundleIdentifierIsCaseInsensitive() {
    #expect(
      BrowserAddressBarDetector.matches(
        bundleIdentifier: "COM.GOOGLE.CHROME",
        axIdentifier: nil,
        axDOMClassList: ["OmniboxViewViews"]))
  }

  @Test("an unrecognized app never reaches the signature check, even with a matching signature")
  func unrecognizedBundleRefusesDespiteMatchingSignature() {
    // The veto: some unrelated third-party app coincidentally exposing an
    // identically-named view must not be trusted just because the string
    // matches. This is the case the two-factor design exists for.
    #expect(
      !BrowserAddressBarDetector.matches(
        bundleIdentifier: "com.example.SomeOtherApp",
        axIdentifier: "WEB_BROWSER_ADDRESS_AND_SEARCH_FIELD",
        axDOMClassList: ["OmniboxViewViews"]))
  }

  @Test("a recognized browser with no matching signature refuses — an ordinary web field")
  func recognizedBrowserWithoutSignatureRefuses() {
    // A Gmail compose box inside Chrome: same app, same AXRole family, but
    // its own DOM class list, not the omnibox's.
    #expect(
      !BrowserAddressBarDetector.matches(
        bundleIdentifier: "com.google.Chrome",
        axIdentifier: nil,
        axDOMClassList: ["gmail-compose-textarea", "editable"]))
  }

  @Test("all-nil inputs refuse")
  func allNilInputsRefuse() {
    #expect(
      !BrowserAddressBarDetector.matches(
        bundleIdentifier: nil, axIdentifier: nil, axDOMClassList: nil))
  }

  @Test("Firefox and Arc are not recognized — not measured, per #2258")
  func unmeasuredBrowsersAreNotRecognized() {
    #expect(!BrowserAddressBarDetector.recognizedBundleIdentifiers.contains("org.mozilla.firefox"))
    #expect(
      !BrowserAddressBarDetector.recognizedBundleIdentifiers.contains("company.thebrowser.browser"))
  }

  // MARK: - family(forBundleIdentifier:) — the cheap, no-AX-call half (Codex review r1)

  @Test("Safari's bundle resolves to the .safari family")
  func safariResolvesToSafariFamily() {
    #expect(BrowserAddressBarDetector.family(forBundleIdentifier: "com.apple.Safari") == .safari)
  }

  @Test(
    "Every Chromium bundle resolves to the .chromium family",
    arguments: ["com.google.Chrome", "com.brave.Browser", "com.microsoft.edgemac"])
  func chromiumBundlesResolveToChromiumFamily(_ bundleIdentifier: String) {
    #expect(BrowserAddressBarDetector.family(forBundleIdentifier: bundleIdentifier) == .chromium)
  }

  @Test("An unrecognized or nil bundle resolves to no family at all")
  func unrecognizedBundleResolvesToNoFamily() {
    #expect(
      BrowserAddressBarDetector.family(forBundleIdentifier: "com.example.SomeOtherApp") == nil)
    #expect(BrowserAddressBarDetector.family(forBundleIdentifier: nil) == nil)
  }

  @Test("A Safari-family match ignores an incidentally-supplied DOM class list")
  func safariFamilyIgnoresDOMClassList() {
    // Family gates which SIGNAL is even consulted, not merely which one is
    // checked first — Safari's own process should never expose Chromium's
    // internal view-class list, so a stray one must not be trusted.
    #expect(
      !BrowserAddressBarDetector.matches(
        bundleIdentifier: "com.apple.Safari",
        axIdentifier: nil,
        axDOMClassList: ["OmniboxViewViews"]))
  }

  @Test("A Chromium-family match ignores an incidentally-supplied AXIdentifier")
  func chromiumFamilyIgnoresAXIdentifier() {
    #expect(
      !BrowserAddressBarDetector.matches(
        bundleIdentifier: "com.google.Chrome",
        axIdentifier: "WEB_BROWSER_ADDRESS_AND_SEARCH_FIELD",
        axDOMClassList: nil))
  }
}
