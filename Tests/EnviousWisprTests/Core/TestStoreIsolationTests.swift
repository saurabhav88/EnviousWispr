import EnviousWisprCore
import Foundation
import Testing

/// #4926: `scripts/xcode-test.sh` gives an ordinary run its own home folder, so no test reaches the
/// real History. Preferences ignore the home folder: the bundle id is their boundary.
@Suite("Test store isolation", .tags(.harnessContract))
struct TestStoreIsolationTests {
  @Test(.enabled(if: ProcessInfo.processInfo.environment["EW_REAL_BOUNDARY"] != "1"))
  func ordinaryRunUsesItsOwnHome() throws {
    func canonical(_ path: String) -> String {
      URL(fileURLWithPath: path).resolvingSymlinksInPath().standardized.path
    }
    let realHome = canonical(String(cString: try #require(getpwuid(getuid())).pointee.pw_dir))
    let isolated = canonical(
      try #require(ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"]))
    #expect(isolated != realHome)
    #expect(ProcessInfo.processInfo.environment["HOME"].map(canonical) == isolated)
    #expect(canonical(NSHomeDirectory()) == isolated)
    #expect(canonical(URL.applicationSupportDirectory.path).hasPrefix(isolated + "/"))
    let bundle = Bundle.main.bundleIdentifier
    #expect(bundle != "com.enviouswispr.app")
    #expect(SettingsDefaults.domainName(forBundle: bundle) == nil)
  }
}
