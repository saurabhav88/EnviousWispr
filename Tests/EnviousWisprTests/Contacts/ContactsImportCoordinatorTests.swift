import EnviousWisprContacts
import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprAppKit
@testable import EnviousWisprPostProcessing

/// Test double for the on-device contacts source. `@unchecked Sendable` is the
/// established pattern for a test fixture (the coordinator calls it sequentially
/// behind `await`, so the call counters never race).
private final class FakeContactProvider: ContactNameProvider, @unchecked Sendable {
  var status: ContactsAuthorization
  var grantResult: Bool
  var candidates: [CandidateName]
  private(set) var fetchCount = 0
  private(set) var requestCount = 0

  init(
    status: ContactsAuthorization, grant: Bool = true, candidates: [CandidateName] = []
  ) {
    self.status = status
    self.grantResult = grant
    self.candidates = candidates
  }

  func authorizationStatus() -> ContactsAuthorization { status }
  func requestAccess() async -> Bool {
    requestCount += 1
    return grantResult
  }
  func fetchCandidateNames() async throws -> [CandidateName] {
    fetchCount += 1
    return candidates
  }
}

@MainActor
@Suite("ContactsImportCoordinator — orchestration (#636)")
struct ContactsImportCoordinatorTests {
  private static func tempDir() -> URL {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("EnviousWispr-test-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
  }

  private func make(
    provider: FakeContactProvider
  ) -> (ContactsImportCoordinator, ImportedContactsStateStore, CustomWordsCoordinator, URL) {
    let dir = Self.tempDir()
    let cwCoord = CustomWordsCoordinator(
      manager: CustomWordsManager(fileURL: dir.appendingPathComponent("custom-words.json")))
    let store = ImportedContactsStateStore(
      fileURL: dir.appendingPathComponent("imported-contacts-state.json"))
    let coord = ContactsImportCoordinator(
      provider: provider, customWords: cwCoord, stateStore: store)
    return (coord, store, cwCoord, dir)
  }

  private func cleanup(_ dir: URL) { try? FileManager.default.removeItem(at: dir) }

  private func contact(_ given: String, _ family: String, id: String) -> CandidateName {
    CandidateName(contactID: id, given: given, family: family)
  }

  @Test("Denied authorization sets .denied and writes nothing")
  func deniedNoWrite() async {
    let provider = FakeContactProvider(status: .denied)
    let (coord, store, _, dir) = make(provider: provider)
    defer { cleanup(dir) }
    await coord.prepareImport()
    #expect(coord.phase == .denied)
    #expect(provider.fetchCount == 0)
    #expect(coord.pendingPreview == nil)
    #expect(store.load().importedWordIDs.isEmpty)
  }

  @Test("notDetermined prompts; a refusal sets .denied")
  func notDeterminedRefused() async {
    let provider = FakeContactProvider(status: .notDetermined, grant: false)
    let (coord, _, _, dir) = make(provider: provider)
    defer { cleanup(dir) }
    await coord.prepareImport()
    #expect(provider.requestCount == 1)
    #expect(coord.phase == .denied)
    #expect(provider.fetchCount == 0)
  }

  @Test("Authorized import stages a preview; confirm writes words + log")
  func successFlow() async {
    let provider = FakeContactProvider(
      status: .authorized, candidates: [contact("Rajesh", "Ramachandran", id: "c1")])
    let (coord, store, cw, dir) = make(provider: provider)
    defer { cleanup(dir) }
    await coord.prepareImport()
    #expect(coord.pendingPreview?.newContactCount == 1)
    coord.confirmImport()
    #expect(coord.phase == .imported(count: 1))
    #expect(store.load().importedContactIDs == ["c1"])
    #expect(!store.load().importedWordIDs.isEmpty)
    #expect(cw.customWords.contains { $0.canonical == "Rajesh Ramachandran" })
    #expect(coord.importedCount == 1)
  }

  @Test("Log-save failure after addBatch surfaces .failed, not a false .imported")
  func logSaveFailureSurfaces() async {
    let dir = Self.tempDir()
    defer { cleanup(dir) }
    // Good custom-words manager (addBatch succeeds) but a log store at an
    // unwritable path so save() throws — the orphaned-words risk Codex flagged.
    let cwCoord = CustomWordsCoordinator(
      manager: CustomWordsManager(fileURL: dir.appendingPathComponent("custom-words.json")))
    let badStore = ImportedContactsStateStore(
      fileURL: URL(fileURLWithPath: "/dev/null/nope/imported-contacts-state.json"))
    let provider = FakeContactProvider(
      status: .authorized, candidates: [contact("Rajesh", "Ramachandran", id: "c1")])
    let coord = ContactsImportCoordinator(
      provider: provider, customWords: cwCoord, stateStore: badStore)
    await coord.prepareImport()
    coord.confirmImport()
    if case .failed = coord.phase {
    } else {
      Issue.record("expected .failed when the import log cannot save, got \(coord.phase)")
    }
    #expect(coord.importedCount == 0)
  }

  @Test("Re-importing an already-imported contact previews zero new")
  func reimportZeroNew() async {
    let provider = FakeContactProvider(
      status: .authorized, candidates: [contact("Rajesh", "Ramachandran", id: "c1")])
    let (coord, _, _, dir) = make(provider: provider)
    defer { cleanup(dir) }
    await coord.prepareImport()
    coord.confirmImport()
    await coord.prepareImport()
    #expect(coord.pendingPreview?.newContactCount == 0)
    #expect(coord.pendingPreview?.alreadyPresentCount == 1)
  }

  @Test("prepareImport is ignored while a preview is already pending")
  func reentrancyGuard() async {
    let provider = FakeContactProvider(
      status: .authorized, candidates: [contact("Rajesh", "Ramachandran", id: "c1")])
    let (coord, _, _, dir) = make(provider: provider)
    defer { cleanup(dir) }
    await coord.prepareImport()
    let fetchesAfterFirst = provider.fetchCount
    await coord.prepareImport()  // pendingPreview != nil → guarded
    #expect(provider.fetchCount == fetchesAfterFirst)
  }

  @Test("bulkRemoveImported removes the imported words and clears the log")
  func bulkRemove() async {
    let provider = FakeContactProvider(
      status: .authorized, candidates: [contact("Rajesh", "Ramachandran", id: "c1")])
    let (coord, store, cw, dir) = make(provider: provider)
    defer { cleanup(dir) }
    await coord.prepareImport()
    coord.confirmImport()
    #expect(coord.importedCount == 1)
    coord.bulkRemoveImported()
    #expect(coord.importedCount == 0)
    #expect(store.load().importedWordIDs.isEmpty)
    #expect(!cw.customWords.contains { $0.canonical == "Rajesh Ramachandran" })
  }

  @Test("syncNewContacts no-ops when not authorized (fetch never called)")
  func syncGateNotAuthorized() async {
    let provider = FakeContactProvider(status: .notDetermined)
    let (coord, store, _, dir) = make(provider: provider)
    defer { cleanup(dir) }
    await coord.syncNewContacts()
    #expect(provider.fetchCount == 0)
    #expect(store.load().importedWordIDs.isEmpty)
  }

  @Test("syncNewContacts is add-only: second run with the same contacts adds nothing")
  func syncAddOnly() async {
    let provider = FakeContactProvider(
      status: .authorized, candidates: [contact("Rajesh", "Ramachandran", id: "c1")])
    let (coord, store, _, dir) = make(provider: provider)
    defer { cleanup(dir) }
    await coord.syncNewContacts()
    #expect(store.load().importedContactIDs == ["c1"])
    let countAfterFirst = store.load().importedWordIDs.count
    await coord.syncNewContacts()
    #expect(store.load().importedWordIDs.count == countAfterFirst)
  }
}
