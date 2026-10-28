import EnviousWisprCore
import EnviousWisprServices
import Foundation
import Testing

@testable import EnviousWisprAppKit
@testable import EnviousWisprPostProcessing
import EnviousWisprAppKitTestSupport

/// #3975 §3.3: deleting an auto-learned word, or removing a learned
/// sound-alike, is the user's "no" for that pair, counted exactly like one
/// Undo; the plain doors (Undo, imports, enrichment) record nothing. Wrong here
/// means a word the user deleted twice comes back, or one Undo blocks a pair.
/// Class: `.productOutcome`.
@MainActor
@Suite(.tags(.productOutcome)) struct CustomWordsUserRefusalTests {
  typealias T = TelemetryService.LearnFromEditsTelemetry

  private struct Fixture {
    let words: CustomWordsCoordinator
    let dir: URL
    var refusals: [(T.RefusalSource, T.UndoMemory)] { box.values }
    let box: Box
  }

  final class Box {
    var values: [(T.RefusalSource, T.UndoMemory)] = []
  }

  private func fixture() -> Fixture {
    let dir = TestTemporaryDirectory.url
      .appendingPathComponent("ew-user-refusal-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let words = CustomWordsCoordinator(
      manager: CustomWordsManager(fileURL: dir.appendingPathComponent("custom-words.json")))
    let box = Box()
    words.onLearnRefusedByUser = { box.values.append(($0, $1)) }
    return Fixture(words: words, dir: dir, box: box)
  }

  private func learnedWord() -> CustomWord {
    CustomWord(
      canonical: "Kwmala", aliases: ["kumala", "kamala", "kwamala"],
      learnedAliases: ["kumala", "kamala"])
  }

  private func key(_ alias: String, _ canonical: String = "Kwmala") -> String {
    CorrectionPairKey.make(original: alias, corrected: canonical)
  }

  @Test(
    "deleting a word gives each pair it learned one no (watching), beside the dictionary file; a typed sound-alike gets none"
  )
  func deleteRecordsOneNoPerLearnedPair() async throws {
    let f = fixture()
    let word = learnedWord()
    #expect(await f.words.add(word) == nil)
    #expect(await f.words.deleteByUser(shownAs: word) == nil)
    #expect(!f.words.customWords.contains { $0.id == word.id })
    #expect(f.words.learnMemory.entry(key("kumala"))?.userNos == 1)
    #expect(f.words.learnMemory.entry(key("kamala"))?.userNos == 1)
    #expect(f.words.learnMemory.entry(key("kwamala")) == nil, "typed by the user, not learned")
    #expect(f.refusals.map(\.0) == [.deleteWord, .deleteWord])
    #expect(f.refusals.map(\.1) == [.watching, .watching])
    #expect(
      FileManager.default.fileExists(
        atPath: f.dir.appendingPathComponent(LearnMemory.fileName).path))
  }

  @Test("a delete no and a later no of either kind block the pair (founder Gate 2: delete counts as one Undo)")
  func secondNoBlocks() async throws {
    let f = fixture()
    let first = learnedWord()
    await f.words.add(first)
    _ = await f.words.deleteByUser(shownAs: first)
    #expect(!f.words.learnMemory.isBlocked(key("kumala")))
    // Learned again, then the user's Undo-equivalent no (bulk delete) blocks it.
    let again = learnedWord()
    await f.words.add(again)
    await #expect(await f.words.deleteByUser(ids: [again.id]) == nil)
    #expect(f.words.learnMemory.isBlocked(key("kumala")))
    #expect(f.refusals.suffix(2).map(\.1) == [.blocked, .blocked])
  }

  @Test(
    "saving an edit that drops a learned sound-alike gives that pair one no; keeping it, or dropping a typed one, gives none"
  )
  func updateRecordsRemovedLearnedAliases() async throws {
    let f = fixture()
    let shown = learnedWord()
    await f.words.add(shown)
    var word = shown
    word.aliases = ["KAMALA"]  // keeps "kamala" (any case), drops learned "kumala" and typed "kwamala"
    word.learnedAliases = ["kamala"]
    await #expect(await f.words.updateByUser(base: shown, draft: word) == nil)
    #expect(f.words.learnMemory.entry(key("kumala"))?.userNos == 1)
    #expect(f.words.learnMemory.entry(key("kamala")) == nil)
    #expect(f.words.learnMemory.entry(key("kwamala")) == nil)
    #expect(f.refusals.map(\.0) == [.removeSoundAlike] && f.refusals.map(\.1) == [.watching])
  }

  @Test(
    "a delete or edit that fails (the dictionary is locked by another instance) records no no and sends no refusal row"
  )
  func failedRemovalRecordsNothing() async throws {
    let f = fixture()
    var word = learnedWord()
    #expect(await f.words.add(word) == nil)
    // Hold the dictionary's companion lock the way a second app instance would.
    let lockURL = f.dir.appendingPathComponent("custom-words.json").appendingPathExtension("lock")
    let openedFD = lockURL.path.withCString { open($0, O_RDWR | O_CREAT, 0o600) }
    let fd = try #require(openedFD >= 0 ? openedFD : nil)
    defer { close(fd) }
    try #require(flock(fd, LOCK_EX) == 0)
    defer { flock(fd, LOCK_UN) }

    #expect(await f.words.deleteByUser(shownAs: word) != nil)
    #expect(await f.words.deleteByUser(ids: [word.id]) != nil)
    let shown = word
    word.aliases = []
    word.learnedAliases = []
    #expect(await f.words.updateByUser(base: shown, draft: word) != nil)
    let live = try #require(f.words.customWords.first { $0.id == word.id })
    #expect(live.learnedAliases == ["kumala", "kamala"], "the word is unchanged")
    #expect(f.words.learnMemory.entry(key("kumala")) == nil)
    #expect(f.words.learnMemory.entry(key("kamala")) == nil)
    #expect(f.refusals.isEmpty)
  }

  @Test("the plain doors (Undo, import, enrichment, cleanup) record nothing")
  func plainDoorsRecordNothing() async throws {
    let f = fixture()
    var word = learnedWord()
    await f.words.add(word)
    let shown = try #require(f.words.customWords.first { $0.id == word.id })
    word.aliases = []
    word.learnedAliases = []
    await #expect(await f.words.update(word, expecting: shown) == nil)
    let other = learnedWord()
    await f.words.add(other)
    await #expect(await f.words.remove(id: other.id) == nil)
    let third = learnedWord()
    await f.words.add(third)
    await #expect(await f.words.removeBatch(ids: [third.id]) == nil)
    #expect(f.words.learnMemory.entry(key("kumala")) == nil)
    #expect(f.words.learnMemory.entry(key("kamala")) == nil)
    #expect(f.refusals.isEmpty)
  }
}
