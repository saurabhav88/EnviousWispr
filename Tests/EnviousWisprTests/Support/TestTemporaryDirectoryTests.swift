import EnviousWisprAppKitTestSupport
import Foundation
import Testing

/// Test temp paths hang off one per-process root that is removed at exit, so a
/// test run no longer leaves folders in the system temporary directory, where
/// macOS keeps them for about three days (measured 2026-10-25: ~25 GB a day).
@Suite(.tags(.harnessContract))
struct TestTemporaryDirectoryTests {

  /// The only test code allowed to name the system temporary directory, each
  /// with the reason it must.
  private static let allowed: Set<String> = [
    // Asserts the production UAT fixture's own location, and removes it.
    "Tests/EnviousWisprTests/Services/FeedbackRefusalTelemetryTests.swift",
    // This file names the forbidden spellings.
    "Tests/EnviousWisprTests/Support/TestTemporaryDirectoryTests.swift",
  ]

  @Test("the root is this process's own folder under the system temporary directory")
  func rootIsPerProcess() {
    let root = TestTemporaryDirectory.url
    #expect(root.lastPathComponent == "EnviousWisprTests-\(getpid())")
    #expect(
      root.deletingLastPathComponent().standardizedFileURL
        == FileManager.default.temporaryDirectory.standardizedFileURL)
    #expect(FileManager.default.fileExists(atPath: root.path))
    #expect(TestTemporaryDirectory.path == root.path + "/")
  }

  @Test("test code reaches the temporary directory only through TestTemporaryDirectory")
  func noDirectSystemTemporaryDirectory() throws {
    let pattern = try Regex(#"\.temporaryDirectory\b|NSTemporaryDirectory\("#)
    var offenders: [String] = []
    for folder in ["Tests/EnviousWisprTests", "Tests/EnviousWisprDesktopEffectsTests"] {
      let base = RepoRoot.url.appending(path: folder)
      let enumerator = try #require(
        FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil))
      for case let url as URL in enumerator where url.pathExtension == "swift" {
        let relative = String(url.path.dropFirst(RepoRoot.url.path.count + 1))
        guard Self.allowed.contains(relative) == false else { continue }
        let lines = try String(contentsOf: url, encoding: .utf8).split(
          separator: "\n", omittingEmptySubsequences: false)
        for (index, line) in lines.enumerated() {
          let code = line.trimmingCharacters(in: .whitespaces)
          guard code.hasPrefix("//") == false, code.contains(pattern) else { continue }
          offenders.append("\(relative):\(index + 1)")
        }
      }
    }
    #expect(
      offenders.isEmpty,
      "use TestTemporaryDirectory.url / .path so the folder is removed when the test process exits: \(offenders)"
    )
  }
}
