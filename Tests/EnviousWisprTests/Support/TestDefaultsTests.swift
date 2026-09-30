import Foundation
import Testing

/// Binds `TestDefaults` (#2998): the registered suites' plists are the ones removed, nothing else is,
/// and no test file mints a named suite any other way.
@Suite("TestDefaults: test suites leave no plist behind (#2998)", .tags(.driftGuard))
struct TestDefaultsTests {
  private static func tempDirectory() throws -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("ew-2998-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  @Test("removing a suite's plist removes exactly that file and leaves other preferences alone")
  func removesOnlyNamedPlists() throws {
    let dir = try Self.tempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let files = ["ours-a.plist", "ours-b.plist", "com.apple.someone-elses.plist"]
    for file in files {
      try Data("x".utf8).write(to: dir.appendingPathComponent(file))
    }

    let removed = TestDefaults.removePlists(of: ["ours-a", "ours-b", "never-written"], in: dir)

    #expect(removed == 2, "a suite that never wrote a plist is not an error and not counted")
    let left = try FileManager.default.contentsOfDirectory(atPath: dir.path)
    #expect(left == ["com.apple.someone-elses.plist"])
  }

  @Test("a suite made through the helper is registered for removal at exit")
  func suitesAreRegistered() throws {
    let name = "ew-2998-registry-\(UUID().uuidString)"
    #expect(!TestDefaults.registeredSuiteNames.contains(name))
    let defaults = try #require(TestDefaults.suite(name))
    defaults.set(1, forKey: "k")
    #expect(TestDefaults.registeredSuiteNames.contains(name))
    #expect(defaults.integer(forKey: "k") == 1, "the suite still behaves as a normal suite")
  }

  @Test(
    "names that could delete somebody's preferences are refused, ordinary test names are not",
    arguments: [
      ("com.apple.finder", false), ("com.apple.", false), ("NSGlobalDomain", false),
      ("com.enviouswispr.app", false), ("com.enviouswispr.app.dev", false), (".GlobalPreferences", false),
      ("../victim", false), ("a/b", false), ("a..b", false), ("", false), ("has space", false),
      ("ew-2998-\(UUID().uuidString)", true), ("com.enviouswispr.tests.2123.absent.x", true),
      ("SM-2064-stuck-1", true), ("ew.settingsDefaultsTest.1", true),
    ])
  func unsafeNamesAreRefused(name: String, safe: Bool) {
    #expect(TestDefaults.isSafeSuiteName(name) == safe, "\(name)")
    if !safe {
      #expect(TestDefaults.suite(name) == nil, "an unsafe name must not make a suite")
      #expect(!TestDefaults.registeredSuiteNames.contains(name))
    }
  }

  @Test("a domain that already has a plist is never registered, so the exit hook cannot delete it")
  func preexistingPlistIsNeverOurs() throws {
    let dir = try Self.tempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let taken = "ew-2998-taken-\(UUID().uuidString)"
    let fresh = "ew-2998-fresh-\(UUID().uuidString)"
    try Data("someone's prefs".utf8).write(to: TestDefaults.plistURL(suite: taken, in: dir))

    #expect(TestDefaults.suite(taken, preferencesDirectory: dir) != nil, "still a working suite")
    #expect(TestDefaults.suite(fresh, preferencesDirectory: dir) != nil)

    #expect(!TestDefaults.registeredSuiteNames.contains(taken), "a pre-existing file is not ours")
    #expect(TestDefaults.registeredSuiteNames.contains(fresh), "a brand-new suite is")
  }

  @Test("cleanup itself refuses a name that escapes the preferences directory")
  func cleanupRefusesTraversal() throws {
    let parent = try Self.tempDirectory()
    defer { try? FileManager.default.removeItem(at: parent) }
    let prefs = parent.appendingPathComponent("prefs", isDirectory: true)
    try FileManager.default.createDirectory(at: prefs, withIntermediateDirectories: true)
    let victim = parent.appendingPathComponent("victim.plist")
    try Data("x".utf8).write(to: victim)

    let removed = TestDefaults.removePlists(of: ["../victim"], in: prefs)

    #expect(removed == 0)
    #expect(FileManager.default.fileExists(atPath: victim.path), "the file outside must survive")
  }

  /// True when `source` calls the raw suite initializer outside a comment line. Built in pieces so
  /// this file does not match its own pattern.
  private static func callsRawSuiteInitializer(_ source: String) -> Bool {
    let pattern = #"UserDefaults(\.init)?\s*\(\s*"# + "suiteName\\s*:"
    let code = source.split(separator: "\n", omittingEmptySubsequences: false)
      .filter { !$0.drop(while: { $0 == " " || $0 == "\t" }).hasPrefix("//") }
      .joined(separator: "\n")
    return code.range(of: pattern, options: .regularExpression) != nil
  }

  @Test(
    "the raw-initializer detector sees every spelling and ignores comments",
    arguments: [
      ("let d = UserDefaults(" + "suiteName: \"x\")!", true),
      ("let d = UserDefaults.init(" + "suiteName: \"x\")!", true),
      ("let d = UserDefaults(\n      " + "suiteName: \"x\")!", true),
      ("/// uses UserDefaults(" + "suiteName: \"x\") in prose", false),
      ("  // UserDefaults(" + "suiteName: \"x\")", false),
      ("let d = UserDefaults (" + "suiteName : \"x\")!", true),
      ("\t// UserDefaults(" + "suiteName: \"x\")", false),
      ("let d = TestDefaults.suite(\"x\")!", false),
    ])
  func detectorControl(source: String, expected: Bool) {
    #expect(Self.callsRawSuiteInitializer(source) == expected, "\(source)")
  }

  @Test("no test file creates a named suite except through TestDefaults")
  func noRawSuiteInitializers() throws {
    let testsRoot = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    // The only two files allowed to hold the raw call, by path (a same-named file elsewhere is not).
    let allowed: Set<String> = [
      "EnviousWisprTests/Support/TestDefaults.swift", "EnviousWisprASRTests/TestDefaults.swift",
    ]
    var holders: Set<String> = []
    var scanned = 0
    let files = try #require(
      FileManager.default.enumerator(at: testsRoot, includingPropertiesForKeys: nil))
    for case let url as URL in files where url.pathExtension == "swift" {
      scanned += 1
      if Self.callsRawSuiteInitializer(try String(contentsOf: url, encoding: .utf8)) {
        holders.insert(String(url.path.dropFirst(testsRoot.path.count + 1)))
      }
    }
    #expect(scanned > 100, "fixture: the scan must see the test sources (saw \(scanned))")
    // Positive control: the two helper copies DO contain it, so a scan that finds nothing is broken.
    #expect(allowed.isSubset(of: holders), "the detector must see both helper copies: \(holders.sorted())")
    holders.subtract(allowed)
    #expect(
      holders.isEmpty,
      "use TestDefaults.suite(_:) so the suite's plist is removed at exit: \(holders.sorted())")
  }
}
