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

/// Test double for the on-device alias generator (#636 follow-up).
/// `@unchecked Sendable` mirrors `FakeContactProvider`: the coordinator calls it
/// sequentially behind `await`, so `calls` never races.
private final class FakeAliasSuggester: AliasSuggesting, @unchecked Sendable {
  let available: Bool
  let aliasesByWord: [String: [String]]
  private(set) var calls: [String] = []
  /// Priority received on each call, in order — #1701 characterization: the
  /// coordinator must pass `.background` on every call, never the default.
  private(set) var priorities: [AliasSuggestionPriority] = []

  init(available: Bool, aliasesByWord: [String: [String]] = [:]) {
    self.available = available
    self.aliasesByWord = aliasesByWord
  }

  var isAvailable: Bool { available }

  func suggestAliases(
    for word: String, category: WordCategory, priority: AliasSuggestionPriority
  ) async -> [String]? {
    calls.append(word)
    priorities.append(priority)
    return aliasesByWord[word]
  }

  /// Contacts import always pins `.person` and never takes this path; a
  /// minimal stub satisfies protocol conformance (#1701 Phase 3 review
  /// finding A).
  func suggestAliases(
    for word: String, priority: AliasSuggestionPriority
  ) async -> [String]? {
    aliasesByWord[word]
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
    provider: FakeContactProvider,
    suggester: (any AliasSuggesting)? = nil
  ) -> (ContactsImportCoordinator, ImportedContactsStateStore, CustomWordsCoordinator, URL) {
    let dir = Self.tempDir()
    let cwCoord = CustomWordsCoordinator(
      manager: CustomWordsManager(fileURL: dir.appendingPathComponent("custom-words.json")))
    let store = ImportedContactsStateStore(
      fileURL: dir.appendingPathComponent("imported-contacts-state.json"))
    let coord = ContactsImportCoordinator(
      provider: provider, customWords: cwCoord, stateStore: store, aliasSuggester: suggester)
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
    // Per-name: two separate tokens, never the combined "First Last".
    #expect(cw.customWords.contains { $0.canonical == "Rajesh" })
    #expect(cw.customWords.contains { $0.canonical == "Ramachandran" })
    #expect(!cw.customWords.contains { $0.canonical == "Rajesh Ramachandran" })
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
    #expect(!cw.customWords.contains { $0.canonical == "Rajesh" })
    #expect(!cw.customWords.contains { $0.canonical == "Ramachandran" })
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

  // MARK: - Alias enrichment (#636 follow-up)

  @Test("Enrichment fills aliases for imported names")
  func enrichmentHappy() async {
    let provider = FakeContactProvider(
      status: .authorized, candidates: [contact("Rajesh", "Vasquez", id: "c1")])
    let fake = FakeAliasSuggester(
      available: true,
      aliasesByWord: ["Rajesh": ["rah jesh", "raj esh"], "Vasquez": ["vaskez", "vah skez"]])
    let (coord, _, cw, dir) = make(provider: provider, suggester: fake)
    defer { cleanup(dir) }
    await coord.prepareImport()
    coord.confirmImport()
    await coord.awaitEnrichmentForTesting()
    #expect(cw.customWords.first { $0.canonical == "Rajesh" }?.aliases == ["rah jesh", "raj esh"])
    #expect(cw.customWords.first { $0.canonical == "Vasquez" }?.aliases == ["vaskez", "vah skez"])
  }

  @Test("Enrichment calls the shared suggester with background priority, never the default (#1701)")
  func enrichmentUsesBackgroundPriority() async {
    let provider = FakeContactProvider(
      status: .authorized, candidates: [contact("Rajesh", "Vasquez", id: "c1")])
    let fake = FakeAliasSuggester(
      available: true, aliasesByWord: ["Rajesh": ["r"], "Vasquez": ["v"]])
    let (coord, _, _, dir) = make(provider: provider, suggester: fake)
    defer { cleanup(dir) }
    await coord.prepareImport()
    coord.confirmImport()
    await coord.awaitEnrichmentForTesting()
    #expect(fake.calls.count == 2)
    #expect(fake.priorities == [.background, .background])
  }

  @Test("Enrichment clears its progress line on completion")
  func enrichmentClearsProgressOnCompletion() async {
    let provider = FakeContactProvider(
      status: .authorized, candidates: [contact("Rajesh", "Vasquez", id: "c1")])
    let fake = FakeAliasSuggester(
      available: true, aliasesByWord: ["Rajesh": ["r"], "Vasquez": ["v"]])
    let (coord, _, _, dir) = make(provider: provider, suggester: fake)
    defer { cleanup(dir) }
    await coord.prepareImport()
    coord.confirmImport()
    await coord.awaitEnrichmentForTesting()
    #expect(coord.enrichmentProgress == nil)
  }

  @Test("Enrichment is a clean no-op when the model is unavailable")
  func enrichmentUnavailable() async {
    let provider = FakeContactProvider(
      status: .authorized, candidates: [contact("Rajesh", "Vasquez", id: "c1")])
    let fake = FakeAliasSuggester(available: false)
    let (coord, _, cw, dir) = make(provider: provider, suggester: fake)
    defer { cleanup(dir) }
    await coord.prepareImport()
    coord.confirmImport()
    await coord.awaitEnrichmentForTesting()
    #expect(coord.enrichmentProgress == nil)
    #expect(cw.customWords.first { $0.canonical == "Rajesh" }?.aliases.isEmpty == true)
    #expect(fake.calls.isEmpty)  // the model was never queried
  }

  @Test("A generated alias that is itself a common word is dropped before persisting")
  func enrichmentDropsCommonWordAlias() async {
    let provider = FakeContactProvider(
      status: .authorized, candidates: [contact("Ramachandran", "", id: "c1")])
    // "will" and "may" are stoplisted common words; "ram uh" is a clean variant.
    let fake = FakeAliasSuggester(
      available: true, aliasesByWord: ["Ramachandran": ["will", "ram uh", "may"]])
    let (coord, _, cw, dir) = make(provider: provider, suggester: fake)
    defer { cleanup(dir) }
    await coord.prepareImport()
    coord.confirmImport()
    await coord.awaitEnrichmentForTesting()
    #expect(cw.customWords.first { $0.canonical == "Ramachandran" }?.aliases == ["ram uh"])
  }

  @Test("Re-scan enriches only import-logged empty-alias words, never one already aliased")
  func enrichmentRecoversLoggedEmptiesOnly() async throws {
    // No new contacts: this is the recovery path (mid-job-quit / model-was-off).
    let provider = FakeContactProvider(status: .authorized, candidates: [])
    let fake = FakeAliasSuggester(
      available: true, aliasesByWord: ["Empty": ["em tee"], "Filled": ["should not apply"]])
    let (coord, store, cw, dir) = make(provider: provider, suggester: fake)
    defer { cleanup(dir) }
    // Seed two logged person words: one empty, one already aliased.
    let empty = CustomWord(canonical: "Empty", category: .person, priority: 10)
    let filled = CustomWord(
      canonical: "Filled", aliases: ["preset"], category: .person, priority: 10)
    let ids = try #require(cw.addBatch([empty, filled]))
    var state = store.load()
    state.record(contactIDs: ["c0"], wordIDs: ids, at: Date())
    try? store.save(state)

    await coord.prepareImport()
    coord.confirmImport()  // 0 new → recovery enrichment over logged empties
    await coord.awaitEnrichmentForTesting()

    #expect(cw.customWords.first { $0.canonical == "Empty" }?.aliases == ["em tee"])
    #expect(cw.customWords.first { $0.canonical == "Filled" }?.aliases == ["preset"])
    #expect(fake.calls == ["Empty"])  // the already-aliased word is never queried
  }

  @Test("Legacy cleanup removes logged combined entries, keeps lone tokens")
  func legacyCleanupRemovesCombinedEntries() async throws {
    let provider = FakeContactProvider(
      status: .authorized, candidates: [contact("Rajesh", "Ramachandran", id: "c1")])
    let (coord, store, cw, dir) = make(provider: provider)
    defer { cleanup(dir) }
    // Simulate an earlier build: a combined entry + a lone entry, both logged.
    let combined = CustomWord(canonical: "Rajesh Ramachandran", category: .person, priority: 10)
    let lone = CustomWord(canonical: "Ramachandran", category: .person, priority: 10)
    let ids = try #require(cw.addBatch([combined, lone]))
    var state = store.load()
    state.record(contactIDs: ["c1"], wordIDs: ids, at: Date())
    try? store.save(state)

    await coord.prepareImport()
    coord.confirmImport()  // c1 already imported → 0 new → cleanup runs
    await coord.awaitEnrichmentForTesting()

    #expect(!cw.customWords.contains { $0.canonical == "Rajesh Ramachandran" })
    #expect(cw.customWords.contains { $0.canonical == "Ramachandran" })
    #expect(!store.load().importedWordIDs.contains(ids[0]))  // combined ID dropped from log
    #expect(store.load().importedWordIDs.contains(ids[1]))  // lone ID kept
  }

  @Test("syncNewContacts enriches the contacts it adds")
  func syncEnriches() async {
    let provider = FakeContactProvider(
      status: .authorized, candidates: [contact("Rajesh", "Vasquez", id: "c1")])
    let fake = FakeAliasSuggester(
      available: true, aliasesByWord: ["Rajesh": ["r1"], "Vasquez": ["v1"]])
    let (coord, _, cw, dir) = make(provider: provider, suggester: fake)
    defer { cleanup(dir) }
    await coord.syncNewContacts()
    await coord.awaitEnrichmentForTesting()
    #expect(cw.customWords.first { $0.canonical == "Rajesh" }?.aliases == ["r1"])
    #expect(cw.customWords.first { $0.canonical == "Vasquez" }?.aliases == ["v1"])
  }

  @Test("bulkRemoveImported cancels enrichment and clears its progress")
  func bulkRemoveCancelsEnrichment() async {
    let provider = FakeContactProvider(
      status: .authorized, candidates: [contact("Rajesh", "Vasquez", id: "c1")])
    let fake = FakeAliasSuggester(
      available: true, aliasesByWord: ["Rajesh": ["r"], "Vasquez": ["v"]])
    let (coord, store, _, dir) = make(provider: provider, suggester: fake)
    defer { cleanup(dir) }
    await coord.prepareImport()
    coord.confirmImport()  // starts enrichment (task queued)
    coord.bulkRemoveImported()  // synchronously cancels + clears before the task runs
    await coord.awaitEnrichmentForTesting()
    #expect(coord.enrichmentProgress == nil)
    #expect(coord.importedCount == 0)
    #expect(store.load().importedWordIDs.isEmpty)
  }

  @Test("Enrichment persists every word across the 25-flush boundary (>25)")
  func enrichmentFlushesAcrossChunkBoundary() async throws {
    // 30 logged empty-alias person words exercise the every-25 flush plus the
    // final flush; the trailing 5 must not be dropped. No new contacts: the
    // 0-new recovery path drives enrichment over the whole logged set.
    let provider = FakeContactProvider(status: .authorized, candidates: [])
    let names = (0..<30).map { "Coworker\($0)" }
    let aliasMap = Dictionary(uniqueKeysWithValues: names.map { ($0, ["v-\($0)"]) })
    let fake = FakeAliasSuggester(available: true, aliasesByWord: aliasMap)
    let (coord, store, cw, dir) = make(provider: provider, suggester: fake)
    defer { cleanup(dir) }
    let seeded = names.map { CustomWord(canonical: $0, category: .person, priority: 10) }
    let ids = try #require(cw.addBatch(seeded))
    var state = store.load()
    state.record(contactIDs: ["c0"], wordIDs: ids, at: Date())
    try? store.save(state)

    await coord.prepareImport()
    coord.confirmImport()  // 0 new → recovery enrichment over all 30 logged empties
    await coord.awaitEnrichmentForTesting()

    for name in names {
      #expect(cw.customWords.first { $0.canonical == name }?.aliases == ["v-\(name)"])
    }
    #expect(coord.enrichmentProgress == nil)
  }
}
