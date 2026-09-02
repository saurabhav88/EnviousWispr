import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprPostProcessing

/// #628 — the store refusing to destroy data it cannot read.
///
/// `.productOutcome`, and it is the highest-stakes suite in the feature. Every case here was a
/// live defect found by review, not imagined: the first version treated an unreadable file as
/// an empty one, so the next save renamed a new empty store over snippets that still existed —
/// a user losing hand-typed data by opening Settings.
///
/// The shared shape worth keeping: a three-valued read collapsed into two. "No file" and
/// "cannot read the file" are different facts, and the second must never be actioned as the
/// first.
@Suite("Snippet store safety (#628)", .tags(.productOutcome))
struct SnippetsStoreSafetyTests {

  private func makeStore() -> (SnippetsManager, URL) {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("ew-snip-safety-\(UUID().uuidString)", isDirectory: true)
    let url = dir.appendingPathComponent("snippets.json")
    return (SnippetsManager(fileURL: url), url)
  }

  /// Make the file unreadable while leaving it present, which is exactly the state the first
  /// version could not distinguish from "no file yet".
  private func makeUnreadable(_ url: URL) throws {
    try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)
  }

  // MARK: - The data-loss case

  @Test("An unreadable file refuses every save rather than being overwritten")
  func unreadableFileRefusesMutation() throws {
    let (manager, url) = makeStore()
    try manager.upsert(Snippet(trigger: "my email", expansion: "sam@example.com"))
    let bytesBefore = try Data(contentsOf: url)
    try makeUnreadable(url)

    #expect(throws: SnippetStoreError.existingFileUnreadable) {
      try manager.upsert(Snippet(trigger: "another", expansion: "text"))
    }

    // The oracle is the FILE, not the return value: the whole defect was a save that succeeded
    // and left an empty store behind.
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    #expect(try Data(contentsOf: url) == bytesBefore)
  }

  @Test("An unreadable file is reported as unreadable, not as an empty list")
  func unreadableFileIsReported() throws {
    let (manager, url) = makeStore()
    try manager.upsert(Snippet(trigger: "my email", expansion: "sam@example.com"))
    try makeUnreadable(url)

    #expect(manager.unreadableExisting)
    // `load()` still returns something renderable — the screen has to draw — but the screen is
    // told not to believe it.
    #expect(manager.load().snippets.isEmpty)

    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
  }

  @Test("Deleting and changing the keyword are refused too, not just adding")
  func everyMutationIsRefused() throws {
    let (manager, url) = makeStore()
    let existing = Snippet(trigger: "my email", expansion: "sam@example.com")
    try manager.upsert(existing)
    try makeUnreadable(url)

    #expect(throws: SnippetStoreError.existingFileUnreadable) {
      try manager.remove(id: existing.id)
    }
    #expect(throws: SnippetStoreError.existingFileUnreadable) { try manager.setKeyword("shortcut") }

    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
  }

  /// A missing file is NOT the unreadable case, and conflating the two in the other direction
  /// would be just as wrong: a new user could never save anything.
  @Test("A store that has never been written still accepts its first snippet")
  func missingFileStillAcceptsWrites() throws {
    let (manager, _) = makeStore()

    #expect(manager.unreadableExisting == false)
    #expect(throws: Never.self) {
      try manager.upsert(Snippet(trigger: "my email", expansion: "sam@example.com"))
    }
  }

  // MARK: - Corruption that cannot be archived

  /// Corrupt bytes are the only copy of the user's snippets. If archiving them fails, treating
  /// the store as empty-and-writable lets the next save destroy the one recoverable version.
  ///
  /// Staged with the file's IMMUTABLE flag rather than a read-only directory. A read-only
  /// directory also blocks the lock file, so the mutation is refused one step earlier and this
  /// test would pass without the archive path ever running — green for the wrong reason, which
  /// is the failure mode a test of a safety property can least afford.
  @Test("Corrupt content that cannot be archived refuses writes instead of being replaced")
  func unarchivableCorruptionRefusesMutation() throws {
    let (manager, url) = makeStore()
    try Data("{ not json".utf8).write(to: url)
    try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: url.path)
    defer { try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: url.path) }

    #expect(throws: SnippetStoreError.existingFileUnreadable) {
      try manager.upsert(Snippet(trigger: "my email", expansion: "sam@example.com"))
    }
    #expect(try String(contentsOf: url, encoding: .utf8) == "{ not json")
  }

  /// The neighbouring case, asserted on the OUTCOME rather than on which refusal fired. When the
  /// directory itself is read-only the lock cannot be created, so the store refuses earlier and
  /// with a different code — and that is fine. What must hold either way is that nothing was
  /// written and the bytes are untouched.
  @Test("A read-only directory refuses the write and leaves the file alone")
  func readOnlyDirectoryRefusesMutation() throws {
    let (manager, url) = makeStore()
    try manager.upsert(Snippet(trigger: "my email", expansion: "sam@example.com"))
    let bytesBefore = try Data(contentsOf: url)
    let directory = url.deletingLastPathComponent()
    try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
    defer {
      try? FileManager.default.setAttributes(
        [.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }

    #expect(throws: (any Error).self) {
      try manager.upsert(Snippet(trigger: "another", expansion: "text"))
    }
    #expect(try Data(contentsOf: url) == bytesBefore)
  }

  // MARK: - Keyword validation

  /// A multi-word keyword passed `canFire` and could never match, so every snippet went quiet
  /// while the screen insisted the feature was on. The honest failure is refusing it.
  @Test("A multi-word keyword is refused rather than silently disabling every snippet")
  func multiWordKeywordIsRefused() throws {
    let (manager, _) = makeStore()

    #expect(throws: SnippetValidationError.keywordNotOneWord) {
      try manager.setKeyword("hey wispr")
    }
    #expect(manager.load().keyword == SnippetVocabulary.defaultKeyword)
  }

  @Test("A one-word keyword with stray spaces is accepted and stored trimmed")
  func paddedSingleWordKeywordIsAccepted() throws {
    let (manager, _) = makeStore()

    try manager.setKeyword("  shortcut  ")

    #expect(manager.load().keyword == "shortcut")
  }
}
