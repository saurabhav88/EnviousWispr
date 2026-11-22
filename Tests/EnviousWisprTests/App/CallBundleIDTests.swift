import Foundation
import Testing

@testable import EnviousWisprAppKit
@testable import EnviousWisprServices

/// #4840: when these fail, a call in one browser is looked for in another browser's window, so
/// it is never noticed. Dia's helpers carry Arc's helper bundle id; only the app folder they live
/// in tells the two apart. Paths are the ones Core Audio reported on a Mac running both.
@Suite("Call app name from the helper's app folder", .tags(.productOutcome))
struct CallBundleIDTests {
  private static let installed: [String: String] = [
    "/Applications/Dia.app": "company.thebrowser.dia",
    "/Applications/Arc.app": "company.thebrowser.browser",
    "/Applications/Google Chrome.app": "com.google.Chrome",
    "/Applications/zoom.us.app": "us.zoom.xos",
    "/Applications/Some Other App.app": "com.example.other",
  ]

  private static func name(_ bundle: String, _ path: String?) -> String? {
    CallSourceDiscovery.callBundleID(
      bundle: bundle, executablePath: path, bundleIDAt: { installed[$0] })
  }

  private static func browser(_ bundle: String, _ path: String?) -> CallAppCatalog.Rule? {
    name(bundle, path).flatMap(CallAppCatalog.rule(forBundleID:))
  }

  private static let aperitif =
    "Contents/Frameworks/ArcCore.framework/Versions/A/Helpers/Browser Helper (Aperitif).app/"
    + "Contents/MacOS/Browser Helper (Aperitif)"

  @Test("A Dia helper reporting Arc's helper id is Dia")
  func diaHelperIsDia() {
    #expect(
      Self.browser("company.thebrowser.browser.helper", "/Applications/Dia.app/" + Self.aperitif)
        == .browser(.dia))
  }

  @Test("An Arc helper is still Arc")
  func arcHelperIsArc() {
    #expect(
      Self.browser("company.thebrowser.browser.helper", "/Applications/Arc.app/" + Self.aperitif)
        == .browser(.arc))
  }

  @Test("A Chrome helper inside Chrome stays Chrome")
  func chromeHelperIsChrome() {
    let path =
      "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/"
      + "Versions/131.0.6778.86/Helpers/Google Chrome Helper.app/Contents/MacOS/Google Chrome Helper"
    #expect(Self.browser("com.google.Chrome.helper", path) == .browser(.chrome))
  }

  @Test("A process outside any app folder keeps its own id (Safari's WebKit audio process)")
  func outsideAnyAppKeepsOwnID() {
    let path =
      "/System/Library/Frameworks/WebKit.framework/Versions/A/XPCServices/"
      + "com.apple.WebKit.GPU.xpc/Contents/MacOS/com.apple.WebKit.GPU"
    #expect(Self.name("com.apple.WebKit.GPU", path) == "com.apple.webkit.gpu")
    #expect(Self.name("com.apple.WebKit.GPU", nil) == "com.apple.webkit.gpu")
  }

  @Test("A known helper inside an app the catalog does not know keeps its own id")
  func unknownOwnerKeepsOwnID() {
    #expect(
      Self.browser(
        "company.thebrowser.browser.helper", "/Applications/Some Other App.app/" + Self.aperitif)
        == .browser(.arc))
  }

  @Test("A helper with no id of its own takes its app's id")
  func namelessHelperTakesAppID() {
    let path = "/Applications/zoom.us.app/Contents/Frameworks/cpthost.app/Contents/MacOS/cpthost"
    #expect(Self.name("", path) == "us.zoom.xos")
  }

  @Test("A process no app in the catalog owns is not a call app")
  func unknownIsNotCallApp() {
    let path = "/Applications/Some Other App.app/Contents/MacOS/Some Other App"
    #expect(Self.name("com.example.other", path) == nil)
  }
}
