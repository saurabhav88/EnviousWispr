import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprPostProcessing

/// #1680 (PR-E1) — export writer. Every test writes to a real temp directory,
/// so atomicity and permissions are verified against the filesystem.
@Suite("CustomWordsExportWriter")
struct CustomWordsExportWriterTests {

  private func makeDirectory() -> URL {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("ew-export-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
  }

  private func document(_ canonicals: [String]) -> CustomWordsTransferDocument {
    CustomWordsTransferDocument(words: canonicals.map { CustomWord(canonical: $0) })
  }

  @Test("a new file is created with owner-only permissions")
  func writerCreatesNewFileWithMode0600() throws {
    let dir = makeDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let destination = dir.appendingPathComponent("words.json")

    try CustomWordsExportWriter.write(document(["Kubernetes"]), to: destination)

    let attributes = try FileManager.default.attributesOfItem(atPath: destination.path)
    let permissions = try #require(attributes[.posixPermissions] as? NSNumber)
    #expect(permissions.int16Value == 0o600)
  }

  @Test("an existing file is replaced atomically")
  func writerAtomicallyReplacesExistingFile() throws {
    let dir = makeDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let destination = dir.appendingPathComponent("words.json")
    try Data("previous contents".utf8).write(to: destination)

    try CustomWordsExportWriter.write(document(["Kubernetes"]), to: destination)

    let decoded = try CustomWordsTransferDocument(data: Data(contentsOf: destination))
    #expect(decoded.words.map(\.canonical) == ["Kubernetes"])
  }

  @Test("no temporary file is left behind after a successful write")
  func writerLeavesNoTemporaryFile() throws {
    let dir = makeDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }

    try CustomWordsExportWriter.write(
      document(["Kubernetes"]), to: dir.appendingPathComponent("words.json"))

    let leftovers = try FileManager.default
      .contentsOfDirectory(atPath: dir.path)
      .filter { $0.hasPrefix(".ew-export-") }
    #expect(leftovers.isEmpty)
  }

  @Test("an unwritable destination leaves any existing file intact")
  func writerLeavesExistingFileIntactOnFailure() throws {
    let dir = makeDirectory()
    defer {
      try? FileManager.default.setAttributes(
        [.posixPermissions: 0o700], ofItemAtPath: dir.path)
      try? FileManager.default.removeItem(at: dir)
    }
    let destination = dir.appendingPathComponent("words.json")
    let original = Data("previous contents".utf8)
    try original.write(to: destination)

    // Read+execute only: the temp file cannot be created in this directory.
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o500], ofItemAtPath: dir.path)

    #expect(throws: (any Error).self) {
      try CustomWordsExportWriter.write(document(["Kubernetes"]), to: destination)
    }

    try FileManager.default.setAttributes(
      [.posixPermissions: 0o700], ofItemAtPath: dir.path)
    #expect(try Data(contentsOf: destination) == original)
  }

  @Test("two exports to one destination leave a single complete document")
  func concurrentWritesLeaveOneCompleteDecodableDocument() async throws {
    let dir = makeDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let destination = dir.appendingPathComponent("words.json")

    // The reason the temp filename is unique rather than fixed: a shared temp
    // name would let these two interleave into one corrupt file.
    async let first: Void = Task.detached {
      try CustomWordsExportWriter.write(
        CustomWordsTransferDocument(words: [CustomWord(canonical: "Kubernetes")]),
        to: destination)
    }.value
    async let second: Void = Task.detached {
      try CustomWordsExportWriter.write(
        CustomWordsTransferDocument(words: [CustomWord(canonical: "Anthropic")]),
        to: destination)
    }.value
    _ = try await (first, second)

    // Which one wins is unspecified; that it is one complete document is not.
    let decoded = try CustomWordsTransferDocument(data: Data(contentsOf: destination))
    #expect(["Kubernetes", "Anthropic"].contains(try #require(decoded.words.first).canonical))
    #expect(decoded.words.count == 1)
  }
}
