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

  /// The writer takes bytes now, so encoding happens once, off the main actor,
  /// and the same bytes are measured and written.
  private func encoded(_ canonicals: [String]) throws -> Data {
    try document(canonicals).encoded()
  }

  @Test("a new file is created with owner-only permissions")
  func writerCreatesNewFileWithMode0600() async throws {
    let dir = makeDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let destination = dir.appendingPathComponent("words.json")

    try await CustomWordsExportWriter.write(try encoded(["Kubernetes"]), to: destination)

    let attributes = try FileManager.default.attributesOfItem(atPath: destination.path)
    let permissions = try #require(attributes[.posixPermissions] as? NSNumber)
    #expect(permissions.int16Value == 0o600)
  }

  @Test("an existing file is replaced atomically")
  func writerAtomicallyReplacesExistingFile() async throws {
    let dir = makeDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let destination = dir.appendingPathComponent("words.json")
    try Data("previous contents".utf8).write(to: destination)

    try await CustomWordsExportWriter.write(try encoded(["Kubernetes"]), to: destination)

    let decoded = try CustomWordsTransferDocument(data: Data(contentsOf: destination))
    #expect(decoded.words.map(\.canonical) == ["Kubernetes"])
  }

  @Test("overwriting a world-readable file still lands at owner-only")
  func writerOverwritingAWorldReadableFileEnforcesMode0600() async throws {
    // The bug this freezes (code review): `replaceItemAt` preserves the
    // DESTINATION's metadata by default, so overwriting an existing 0644 file
    // silently discarded the temp file's 0600 and left a backup full of
    // personal names world-readable. The new-file test could never catch it.
    let dir = makeDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let destination = dir.appendingPathComponent("words.json")
    try Data("previous contents".utf8).write(to: destination)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o644], ofItemAtPath: destination.path)

    try await CustomWordsExportWriter.write(try encoded(["Kubernetes"]), to: destination)

    let attributes = try FileManager.default.attributesOfItem(atPath: destination.path)
    let permissions = try #require(attributes[.posixPermissions] as? NSNumber)
    #expect(permissions.int16Value == 0o600)
  }

  @Test("no temporary file is left behind after a successful write")
  func writerLeavesNoTemporaryFile() async throws {
    let dir = makeDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }

    try await CustomWordsExportWriter.write(try encoded(["Kubernetes"]), to: dir.appendingPathComponent("words.json"))

    let leftovers = try FileManager.default
      .contentsOfDirectory(atPath: dir.path)
      .filter { $0.hasPrefix(".ew-export-") }
    #expect(leftovers.isEmpty)
  }

  @Test("an unwritable destination leaves any existing file intact")
  func writerLeavesExistingFileIntactOnFailure() async throws {
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

    await #expect(throws: (any Error).self) {
      try await CustomWordsExportWriter.write(try encoded(["Kubernetes"]), to: destination)
    }

    try FileManager.default.setAttributes(
      [.posixPermissions: 0o700], ofItemAtPath: dir.path)
    #expect(try Data(contentsOf: destination) == original)
  }

  @Test("a directory at the destination is never replaced or emptied")
  func writerRefusesToReplaceADirectory() async throws {
    // The bug this freezes (code review r2): the move-then-replace fallback
    // originally replaced on ANY move failure, so a directory sitting at the
    // destination path would be replaced by the export file and its contents
    // deleted — a destructive answer to an unrelated error.
    let dir = makeDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let destination = dir.appendingPathComponent("words.json", isDirectory: true)
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    let inhabitant = destination.appendingPathComponent("keep-me.txt")
    try Data("precious".utf8).write(to: inhabitant)

    await #expect(throws: (any Error).self) {
      try await CustomWordsExportWriter.write(try encoded(["Kubernetes"]), to: destination)
    }

    var isDirectory: ObjCBool = false
    #expect(
      FileManager.default.fileExists(atPath: destination.path, isDirectory: &isDirectory))
    #expect(isDirectory.boolValue)
    #expect(try Data(contentsOf: inhabitant) == Data("precious".utf8))
  }

  @Test("two exports to one destination leave a single complete document")
  func concurrentWritesLeaveOneCompleteDecodableDocument() async throws {
    let dir = makeDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let destination = dir.appendingPathComponent("words.json")

    // The reason the temp filename is unique rather than fixed: a shared temp
    // name would let these two interleave into one corrupt file.
    async let first: Void = Task.detached {
      try await CustomWordsExportWriter.write(
        try CustomWordsTransferDocument(words: [CustomWord(canonical: "Kubernetes")])
          .encoded(),
        to: destination)
    }.value
    async let second: Void = Task.detached {
      try await CustomWordsExportWriter.write(
        try CustomWordsTransferDocument(words: [CustomWord(canonical: "Anthropic")])
          .encoded(),
        to: destination)
    }.value
    _ = try await (first, second)

    // Which one wins is unspecified; that it is one complete document is not.
    let decoded = try CustomWordsTransferDocument(data: Data(contentsOf: destination))
    #expect(["Kubernetes", "Anthropic"].contains(try #require(decoded.words.first).canonical))
    #expect(decoded.words.count == 1)
  }

  @Test("exporting onto EnviousWispr's own words file is refused")
  func exportRefusesToOverwriteTheLiveWordsFile() async throws {
    // The worst possible outcome of an export: choosing the app's own storage
    // as the destination would atomically replace the live dictionary with the
    // transfer format, the next launch would find a file it cannot parse and
    // archive it as corrupt, and the user would have destroyed their words BY
    // EXPORTING THEM (code review r5).
    let live = try #require(CustomWordsManager.liveFileURL)

    await #expect(
      throws: CustomWordsExportWriter.ExportDestinationError.wouldOverwriteLiveWords
    ) {
      try await CustomWordsExportWriter.write(document(["Kubernetes"]), to: live)
    }
  }

  @Test("the refusal cannot be walked around with a relative path")
  func exportRefusalResolvesPathsBeforeComparing() async throws {
    let live = try #require(CustomWordsManager.liveFileURL)
    // Same file, spelled the long way round.
    let indirect = live
      .deletingLastPathComponent()
      .appendingPathComponent("..")
      .appendingPathComponent(live.deletingLastPathComponent().lastPathComponent)
      .appendingPathComponent(live.lastPathComponent)

    #expect(CustomWordsExportWriter.wouldOverwriteLiveWords(indirect))
  }

  @Test("an ordinary destination is still allowed")
  func exportAllowsAnOrdinaryDestination() throws {
    let dir = makeDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    #expect(
      !CustomWordsExportWriter.wouldOverwriteLiveWords(
        dir.appendingPathComponent("EnviousWispr Words.json")))
  }
}
