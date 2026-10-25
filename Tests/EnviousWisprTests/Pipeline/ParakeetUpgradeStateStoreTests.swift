import Foundation
import Testing

@testable import EnviousWisprPipeline
import EnviousWisprAppKitTestSupport

/// #3546: the persisted Parakeet upgrade budget. If it breaks, an Ultra target
/// can retry forever (dictation stuck failing) or lose the record that it
/// already failed, so the protections in plan §3.4 rows X and T never engage.
@Suite("Parakeet upgrade state store", .tags(.productOutcome))
struct ParakeetUpgradeStateStoreTests {
  private static let key = "parakeet-parakeet-ultra-coreml-95eaa59a-int8"

  private func makeDirectory() throws -> URL {
    let url = TestTemporaryDirectory.url
      .appendingPathComponent("ew-upgrade-store-\(UUID().uuidString)", isDirectory: true)
      .appendingPathComponent("ModelDelivery", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  @Test("missing files read as a fresh target")
  func missingFilesAreFresh() throws {
    let store = ParakeetUpgradeStateStore(
      metadataDirectory: try makeDirectory(), targetCacheKey: Self.key)
    #expect(store.read() == .state(.fresh))
  }

  @Test("every field survives a write and a fresh read, under its own named file")
  func roundTrip() throws {
    let directory = try makeDirectory()
    let store = ParakeetUpgradeStateStore(metadataDirectory: directory, targetCacheKey: Self.key)
    let written = ParakeetUpgradeState(
      attempts: 2, refetchSpent: true, exhausted: true, declined: true)
    try store.write(written)
    let reopened = ParakeetUpgradeStateStore(metadataDirectory: directory, targetCacheKey: Self.key)
    #expect(reopened.read() == .state(written))
    let names = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
    #expect(
      names == [
        "parakeet-upgrade-attempts-\(Self.key)", "parakeet-upgrade-declined-\(Self.key)",
        "parakeet-upgrade-exhausted-\(Self.key)", "parakeet-upgrade-refetchSpent-\(Self.key)",
      ])
    #expect(
      try String(
        contentsOf: directory.appendingPathComponent("parakeet-upgrade-attempts-\(Self.key)"),
        encoding: .utf8) == "2")
  }

  @Test("writing a fresh state removes every file")
  func resetRemovesFiles() throws {
    let directory = try makeDirectory()
    let store = ParakeetUpgradeStateStore(metadataDirectory: directory, targetCacheKey: Self.key)
    try store.write(
      ParakeetUpgradeState(attempts: 1, refetchSpent: true, exhausted: false, declined: true))
    try store.write(.fresh)
    #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    #expect(store.read() == .state(.fresh))
  }

  @Test("a different target keeps its own budget")
  func targetsAreIndependent() throws {
    let directory = try makeDirectory()
    let old = ParakeetUpgradeStateStore(metadataDirectory: directory, targetCacheKey: Self.key)
    try old.write(
      ParakeetUpgradeState(attempts: 2, refetchSpent: true, exhausted: true, declined: false))
    let newer = ParakeetUpgradeStateStore(
      metadataDirectory: directory, targetCacheKey: Self.key + "-next")
    #expect(newer.read() == .state(.fresh))
  }

  @Test(arguments: ["", "two", "-1", "1.5"])
  func corruptAttemptsReadAsUnreadable(contents: String) throws {
    let directory = try makeDirectory()
    try Data(contents.utf8).write(
      to: directory.appendingPathComponent("parakeet-upgrade-attempts-\(Self.key)"))
    let store = ParakeetUpgradeStateStore(metadataDirectory: directory, targetCacheKey: Self.key)
    #expect(store.read() == .unreadable(reason: "attempts:corrupt"))
  }

  @Test("a directory where a flag file belongs reads as unreadable")
  func directoryInPlaceOfFlag() throws {
    let directory = try makeDirectory()
    try FileManager.default.createDirectory(
      at: directory.appendingPathComponent("parakeet-upgrade-exhausted-\(Self.key)"),
      withIntermediateDirectories: true)
    let store = ParakeetUpgradeStateStore(metadataDirectory: directory, targetCacheKey: Self.key)
    #expect(store.read() == .unreadable(reason: "exhausted:not_a_file"))
  }

  @Test("a write that fails names the field and is never silent")
  func writeFailureNamesTheField() throws {
    struct DiskFull: Error {}
    let store = ParakeetUpgradeStateStore(
      metadataDirectory: try makeDirectory(), targetCacheKey: Self.key,
      writeData: { _, _ in throw DiskFull() })
    #expect(throws: ParakeetUpgradeStoreWriteError(field: "attempts")) {
      try store.write(
        ParakeetUpgradeState(attempts: 1, refetchSpent: false, exhausted: false, declined: false))
    }
    #expect(throws: ParakeetUpgradeStoreWriteError(field: "probe")) {
      try store.probeWritable()
    }
  }

  @Test("the writability probe leaves nothing behind")
  func probeLeavesNothing() throws {
    let directory = try makeDirectory()
    let store = ParakeetUpgradeStateStore(metadataDirectory: directory, targetCacheKey: Self.key)
    try store.probeWritable()
    #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
  }

  @Test("a state file reached through a link out of the metadata directory is refused")
  func escapingLinkIsRefused() throws {
    let directory = try makeDirectory()
    let outside = try makeDirectory()
    let target = outside.appendingPathComponent("elsewhere")
    try Data("1".utf8).write(to: target)
    try FileManager.default.createSymbolicLink(
      at: directory.appendingPathComponent("parakeet-upgrade-attempts-\(Self.key)"),
      withDestinationURL: target)
    let store = ParakeetUpgradeStateStore(metadataDirectory: directory, targetCacheKey: Self.key)
    #expect(store.read() == .unreadable(reason: "attempts:outside_metadata"))
    #expect(throws: ParakeetUpgradeStoreWriteError(field: "attempts")) {
      try store.write(
        ParakeetUpgradeState(attempts: 1, refetchSpent: false, exhausted: false, declined: false))
    }
    #expect(try String(contentsOf: target, encoding: .utf8) == "1")
  }

  @Test("an attempts file that cannot be read is unreadable, never a fresh budget")
  func unreadableAttemptsBlock() throws {
    let directory = try makeDirectory()
    let file = directory.appendingPathComponent("parakeet-upgrade-attempts-\(Self.key)")
    try Data("1".utf8).write(to: file)
    try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: file.path)
    defer {
      try? FileManager.default.setAttributes(
        [.posixPermissions: 0o644], ofItemAtPath: file.path)
    }
    let store = ParakeetUpgradeStateStore(metadataDirectory: directory, targetCacheKey: Self.key)
    #expect(store.read() == .unreadable(reason: "attempts:unreadable"))
  }

  @Test("a state directory that cannot be looked into is unreadable, never a fresh budget")
  func failedLookupBlocks() throws {
    let directory = try makeDirectory()
    try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: directory.path)
    defer {
      try? FileManager.default.setAttributes(
        [.posixPermissions: 0o755], ofItemAtPath: directory.path)
    }
    let store = ParakeetUpgradeStateStore(metadataDirectory: directory, targetCacheKey: Self.key)
    #expect(store.read() == .unreadable(reason: "attempts:lookup_\(EACCES)"))
  }

  @Test("a dangling link where a state file belongs is unreadable")
  func danglingLinkIsUnreadable() throws {
    let directory = try makeDirectory()
    try FileManager.default.createSymbolicLink(
      at: directory.appendingPathComponent("parakeet-upgrade-exhausted-\(Self.key)"),
      withDestinationURL: directory.appendingPathComponent("missing"))
    let store = ParakeetUpgradeStateStore(metadataDirectory: directory, targetCacheKey: Self.key)
    #expect(store.read() == .unreadable(reason: "exhausted:not_a_file"))
  }
}
