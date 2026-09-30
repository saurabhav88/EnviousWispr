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

  @Test("no test file creates a named suite except through TestDefaults")
  func noRawSuiteInitializers() throws {
    let testsRoot = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    // Built in pieces so this file does not match its own pattern.
    let pattern = #"UserDefaults\(\s*"# + "suiteName:"
    var holders: Set<String> = []
    var scanned = 0
    let files = try #require(
      FileManager.default.enumerator(at: testsRoot, includingPropertiesForKeys: nil))
    for case let url as URL in files where url.pathExtension == "swift" {
      scanned += 1
      let text = try String(contentsOf: url, encoding: .utf8)
      if text.range(of: pattern, options: .regularExpression) != nil {
        holders.insert(url.lastPathComponent)
      }
    }
    #expect(scanned > 100, "fixture: the scan must see the test sources (saw \(scanned))")
    // Positive control: the two helper copies DO contain it, so a scan that finds nothing is broken.
    #expect(holders.contains("TestDefaults.swift"), "the detector must see the helper itself")
    holders.remove("TestDefaults.swift")
    #expect(
      holders.isEmpty,
      "use TestDefaults.suite(_:) so the suite's plist is removed at exit: \(holders.sorted())")
  }
}
