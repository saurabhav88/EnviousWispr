import EnviousWisprContacts
import Foundation
import Testing

/// #636 — the import log: opaque IDs only, absent-file → empty, union semantics.
@Suite("ImportedContactsStateStore — import log (#636)")
struct ImportedContactsStateStoreTests {
  private static func tempURL() -> URL {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("EnviousWispr-test-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.appendingPathComponent("imported-contacts-state.json")
  }

  private static func cleanup(_ url: URL) {
    try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
  }

  @Test("Absent file loads as empty state")
  func absentFileIsEmpty() {
    let url = Self.tempURL()
    defer { Self.cleanup(url) }
    let state = ImportedContactsStateStore(fileURL: url).load()
    #expect(state.importedContactIDs.isEmpty)
    #expect(state.importedWordIDs.isEmpty)
    #expect(state.lastImportedAt == nil)
  }

  @Test("Save then load round-trips the IDs and timestamp")
  func roundTrip() throws {
    let url = Self.tempURL()
    defer { Self.cleanup(url) }
    let store = ImportedContactsStateStore(fileURL: url)
    let w1 = UUID()
    let w2 = UUID()
    var state = ImportedContactsState.empty
    state.record(
      contactIDs: ["c1", "c2"], wordIDs: [w1, w2], at: Date(timeIntervalSince1970: 1000))
    try store.save(state)

    let reloaded = ImportedContactsStateStore(fileURL: url).load()
    #expect(reloaded.importedContactIDs == ["c1", "c2"])
    #expect(reloaded.importedWordIDs == [w1, w2])
    #expect(reloaded.lastImportedAt == Date(timeIntervalSince1970: 1000))
  }

  @Test("record() unions new IDs without duplicating, preserving order")
  func recordDedupes() {
    let w1 = UUID()
    let w2 = UUID()
    let w3 = UUID()
    var state = ImportedContactsState.empty
    state.record(contactIDs: ["c1"], wordIDs: [w1, w2], at: Date(timeIntervalSince1970: 1))
    state.record(contactIDs: ["c1", "c2"], wordIDs: [w2, w3], at: Date(timeIntervalSince1970: 2))
    #expect(state.importedContactIDs == ["c1", "c2"])
    #expect(state.importedWordIDs == [w1, w2, w3])
    #expect(state.lastImportedAt == Date(timeIntervalSince1970: 2))
  }

  @Test("Saving .empty clears prior IDs (the bulk-remove reset)")
  func saveEmptyClears() throws {
    let url = Self.tempURL()
    defer { Self.cleanup(url) }
    let store = ImportedContactsStateStore(fileURL: url)
    var state = ImportedContactsState.empty
    state.record(contactIDs: ["c1"], wordIDs: [UUID()], at: Date(timeIntervalSince1970: 5))
    try store.save(state)
    try store.save(.empty)
    let reloaded = store.load()
    #expect(reloaded.importedContactIDs.isEmpty)
    #expect(reloaded.importedWordIDs.isEmpty)
  }
}
