import Foundation
import Testing

/// Protects the instrument: nested moves and bad roots must not look clean.
@Suite("Settings source enumeration", .tags(.harnessContract))
struct SettingsSourceEnumerationTests {
  private func withRoot(_ body: (URL) throws -> Void) throws {
    // Deliberately use /tmp: its realpath differs on macOS, like #1675's checkout.
    let root = URL(fileURLWithPath: "/tmp/ew-settings-scan-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try body(root)
  }

  private func put(_ text: String, at path: String, root: URL) throws {
    let url = root.appending(path: SettingsSourceEnumeration.relativeDirectory + "/" + path)
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try text.write(to: url, atomically: true, encoding: .utf8)
  }

  @Test("Nested Swift files are subjects with canonical repo-relative paths")
  func nestedFilesAreDiscovered() throws {
    try withRoot { root in
      try put("let owner = ParakeetBackend.self", at: "Owner.swift", root: root)
      try put("Button {}.buttonStyle(.bordered)", at: "Tabs/Nested.swift", root: root)
      try put("not Swift", at: "Tabs/notes.txt", root: root)
      let files = try SettingsSourceEnumeration.sources(
        repoRoot: root, requiredFiles: ["Owner.swift", "Tabs/Nested.swift"])
      #expect(files.map(\.path) == [
        "Sources/EnviousWisprAppKit/Views/Settings/Owner.swift",
        "Sources/EnviousWisprAppKit/Views/Settings/Tabs/Nested.swift",
      ])
      #expect(files.map(\.text) == [
        "let owner = ParakeetBackend.self", "Button {}.buttonStyle(.bordered)",
      ])
    }
  }

  @Test("A missing repository or Settings root refuses the scan")
  func missingRootsRefuse() throws {
    try withRoot { root in
      #expect(throws: SettingsSourceEnumeration.Failure.missingRoot(
        root.appending(path: SettingsSourceEnumeration.relativeDirectory).path
          .replacingOccurrences(of: "/tmp/", with: "/private/tmp/"))) {
        try SettingsSourceEnumeration.sources(repoRoot: root, requiredFiles: [])
      }
      let missing = root.appending(path: "missing")
      #expect(throws: SettingsSourceEnumeration.Failure.missingRoot(missing.path)) {
        try SettingsSourceEnumeration.sources(repoRoot: missing, requiredFiles: [])
      }
    }
  }

  @Test("An unreadable root refuses instead of returning no subjects")
  func unreadableRootRefuses() throws {
    try withRoot { root in
      try put("let value = 1", at: "Visible.swift", root: root)
      let directory = root.appending(path: SettingsSourceEnumeration.relativeDirectory)
      try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: directory.path)
      defer {
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
      }
      try #require(FileManager.default.isReadableFile(atPath: directory.path) == false,
        "fixture must really deny reading; permission control unavailable")
      #expect(throws: SettingsSourceEnumeration.Failure.self) {
        try SettingsSourceEnumeration.sources(repoRoot: root, requiredFiles: [])
      }
    }
  }

  @Test("An unreadable nested directory refuses a partial scan")
  func unreadableNestedDirectoryRefuses() throws {
    try withRoot { root in
      try put("let value = 1", at: "Visible.swift", root: root)
      try put("let hidden = 2", at: "Nested/Hidden.swift", root: root)
      let directory = root.appending(path: SettingsSourceEnumeration.relativeDirectory + "/Nested")
      try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: directory.path)
      defer {
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
      }
      try #require(FileManager.default.isReadableFile(atPath: directory.path) == false)
      #expect(throws: SettingsSourceEnumeration.Failure.self) {
        try SettingsSourceEnumeration.sources(repoRoot: root, requiredFiles: ["Visible.swift"])
      }
    }
  }

  @Test("Empty sources and absent expected files refuse")
  func absentSubjectsRefuse() throws {
    try withRoot { root in
      try put("ignored", at: "notes.txt", root: root)
      #expect(throws: SettingsSourceEnumeration.Failure.noSubjects) {
        try SettingsSourceEnumeration.sources(repoRoot: root, requiredFiles: [])
      }
      try put("let value = 1", at: "Visible.swift", root: root)
      #expect(throws: SettingsSourceEnumeration.Failure.missingExpectedFiles(["Missing.swift"])) {
        try SettingsSourceEnumeration.sources(repoRoot: root, requiredFiles: ["Missing.swift"])
      }
    }
  }

  @Test("The real Settings population contains every expected file")
  func productionPopulation() throws {
    let files = try SettingsSourceEnumeration.sources()
    #expect(files.isEmpty == false)
    print("SETTINGS SOURCES \(files.count): \(files.map(\.path).joined(separator: ", "))")
  }
}
