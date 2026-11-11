import EnviousWisprAppKitTestSupport
import Foundation
import Testing

/// #4493: the crash-report probe behind the real-boundary "no new crash report" checks. When it
/// is wrong, a folder it could not read reads as "no crash", and a crashed helper passes.
@Suite("Helper crash-report probe (#4493)", .tags(.harnessContract))
struct HelperProcessProbeTests {
  static func folder(_ name: String) -> URL {
    TestTemporaryDirectory.url.appendingPathComponent("probe-\(name)-\(UUID().uuidString)")
  }

  @Test("a folder that does not exist holds no reports")
  func missingFolder() throws {
    #expect(try HelperProcessProbe.crashReports("llama-server", in: Self.folder("missing")).isEmpty)
  }

  @Test("only the named process's .ips files are reports")
  func listsOnlyMatchingReports() throws {
    let folder = Self.folder("listed")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    for name in ["llama-server-1.ips", "llama-server-2.txt", "other-1.ips"] {
      try Data().write(to: folder.appendingPathComponent(name))
    }
    #expect(try HelperProcessProbe.crashReports("llama-server", in: folder) == ["llama-server-1.ips"])
  }

  @Test("a path that cannot be listed is an error, not an empty answer")
  func unreadablePathThrows() throws {
    let file = Self.folder("file")
    try Data("x".utf8).write(to: file)
    defer { try? FileManager.default.removeItem(at: file) }
    #expect(throws: (any Error).self) { try HelperProcessProbe.crashReports("llama-server", in: file) }
  }
}
