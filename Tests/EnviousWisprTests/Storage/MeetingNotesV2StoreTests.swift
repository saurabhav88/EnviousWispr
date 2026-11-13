import EnviousWisprAppKitTestSupport
import Foundation
import Testing

@testable import EnviousWisprCore
@testable import EnviousWisprStorage

/// #3147 PR4 notes v2: when these fail, a user's meeting notes written by v2.6.0 are lost or
/// changed on upgrade, a crash leaves notes that disagree with what the summary reads, a summary
/// looks out of date for notes nobody changed, or an older build writes over newer notes.
@Suite("Meeting notes v2: notes.json, migration and repair", .tags(.productOutcome))
struct MeetingNotesV2StoreTests {
  private func makeMeeting() throws -> (MeetingStore, MeetingRecord) {
    let root = TestTemporaryDirectory.url
      .appendingPathComponent("MeetingNotesV2StoreTests-\(UUID().uuidString)", isDirectory: true)
    let store = MeetingStore(root: root)
    let record = MeetingRecord(engine: .parakeet, trackStatus: [.microphone: .captured])
    try store.create(record)
    return (store, record)
  }

  private func bytes(_ url: URL) throws -> Data { try Data(contentsOf: url) }

  private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

  private func manifestJSON(_ store: MeetingStore, _ id: UUID) throws -> [String: Any] {
    try #require(
      try JSONSerialization.jsonObject(with: bytes(store.documentsURL(for: id))) as? [String: Any])
  }

  private func task(_ text: String, done: Bool = false, at ms: Int? = nil) -> MeetingNoteBlock {
    MeetingNoteBlock(startedAtMs: ms, kind: .task, done: done, text: text)
  }

  /// notes.md and documents.json exactly as v2.6.0 wrote them (format 1, revision 3).
  private func writeLegacy(_ store: MeetingStore, _ id: UUID, notes: String, revision: Int = 3)
    throws
  {
    try Data(notes.utf8).write(to: store.notesURL(for: id))
    let manifest = """
      {"formatVersion":1,"notes":{"revision":\(revision),"sha256":"\(MeetingDocumentHash.sha256(notes))"}}
      """
    try Data(manifest.utf8).write(to: store.documentsURL(for: id))
  }

  // MARK: - Migration

  @Test("v2.6.0 notes migrate to one block per line, no times, same Markdown, same revision")
  func legacyMigration() throws {
    let (store, record) = try makeMeeting()
    let legacy = "Agenda\n\n- [ ] send deck\nCafé \u{1F600}\r\nlast line\n"
    try writeLegacy(store, record.id, notes: legacy)

    let loaded = try store.loadDocuments(meeting: record.id)
    #expect(
      loaded.notesDocument.blocks.map(\.text) == [
        "Agenda", "", "- [ ] send deck", "Café \u{1F600}\r", "last line", "",
      ])
    #expect(loaded.notesDocument.blocks.allSatisfy { $0.startedAtMs == nil && $0.kind == .text })
    #expect(loaded.notes == legacy, "the summary still reads the same notes")
    #expect(try bytes(store.notesURL(for: record.id)) == Data(legacy.utf8), "notes.md untouched")
    #expect(loaded.manifest.notes?.revision == 3, "migration is not a notes change")
    #expect(loaded.repaired)
    #expect(exists(store.notesDocumentURL(for: record.id)))
    #expect(try manifestJSON(store, record.id)["formatVersion"] as? Int == 2)

    // The ids are stable: the next read finds the same blocks and repairs nothing.
    let again = try store.loadDocuments(meeting: record.id)
    #expect(again.notesDocument == loaded.notesDocument)
    #expect(again.repaired == false)
    #expect(again.manifest.notes?.revision == 3)
  }

  @Test("a summary written from v2.6.0 notes stays current after the migration")
  func migrationKeepsSummaryCurrent() throws {
    let (store, record) = try makeMeeting()
    try writeLegacy(store, record.id, notes: "Ask Priya", revision: 4)
    let inputs = SummaryInputs(
      transcriptSHA256: "t", notesRevision: 4, speakerNamesSHA256: "s", promptVersion: 1,
      providerID: "openAI", configurationSHA256: "c")
    // The generated summary's checked write reads the notes revision the migration keeps.
    let outcome = try store.saveGeneratedSummary(
      "Summary", inputs: inputs, writtenInParts: false, approvedUserEdit: nil, meeting: record.id)
    guard case .saved = outcome else {
      Issue.record("a summary of unchanged migrated notes was refused: \(outcome)")
      return
    }
    let loaded = try store.loadDocuments(meeting: record.id)
    #expect(loaded.manifest.notes?.revision == 4)
    #expect(loaded.manifest.summary?.inputs?.notesRevision == loaded.manifest.notes?.revision)
  }

  @Test("v2.6.0 notes changed behind the manifest migrate and count as one change")
  func legacyChangedOutsideAdvancesOnce() throws {
    let (store, record) = try makeMeeting()
    try writeLegacy(store, record.id, notes: "old", revision: 2)
    try Data("edited outside".utf8).write(to: store.notesURL(for: record.id))
    let loaded = try store.loadDocuments(meeting: record.id)
    #expect(loaded.notes == "edited outside")
    #expect(loaded.manifest.notes?.revision == 3)
    #expect(try store.loadDocuments(meeting: record.id).manifest.notes?.revision == 3)
  }

  @Test("a meeting without notes writes no notes files on load")
  func noNotesNoFiles() throws {
    let (store, record) = try makeMeeting()
    let loaded = try store.loadDocuments(meeting: record.id)
    #expect(loaded.notes.isEmpty && loaded.notesDocument.blocks.isEmpty)
    #expect(loaded.repaired == false)
    #expect(!exists(store.notesDocumentURL(for: record.id)))
    #expect(!exists(store.documentsURL(for: record.id)))
  }

  // MARK: - Authority and projection

  @Test(
    "notes.json is the authority: blocks, kinds and times round-trip; notes.md is the projection")
  func jsonIsAuthority() throws {
    let (store, record) = try makeMeeting()
    let document = MeetingNotesDocument(blocks: [
      MeetingNoteBlock(startedAtMs: 1_000, text: "Budget"),
      task("send deck", done: true, at: 2_000),
      MeetingNoteBlock(
        startedAtMs: 3_000, kind: .quote, text: "we ship Friday", sourceSpeaker: "Priya",
        sourceMs: 2_500),
      MeetingNoteBlock(startedAtMs: 4_000, kind: .mark, text: "Moment marked"),
    ])
    let manifest = try store.saveNotes(document, revision: 1, meeting: record.id)
    let markdown = "Budget\n- [x] send deck\n> we ship Friday\nMoment marked"
    #expect(manifest.notes?.sha256 == MeetingDocumentHash.sha256(markdown))
    #expect(try String(contentsOf: store.notesURL(for: record.id), encoding: .utf8) == markdown)

    // Someone edits notes.md by hand: the blocks win and the projection is rewritten.
    try Data("hand edit".utf8).write(to: store.notesURL(for: record.id))
    let loaded = try store.loadDocuments(meeting: record.id)
    #expect(loaded.notesDocument == document)
    #expect(loaded.notes == markdown)
    #expect(try String(contentsOf: store.notesURL(for: record.id), encoding: .utf8) == markdown)
    #expect(loaded.manifest.notes?.revision == 1, "the notes did not change")
  }

  @Test("emptied notes keep notes.json, so the older Markdown never comes back")
  func emptiedNotesStayEmpty() throws {
    let (store, record) = try makeMeeting()
    try writeLegacy(store, record.id, notes: "Agenda")
    _ = try store.loadDocuments(meeting: record.id)
    _ = try store.saveNotes(MeetingNotesDocument(blocks: []), revision: 4, meeting: record.id)
    #expect(!exists(store.notesURL(for: record.id)))
    #expect(exists(store.notesDocumentURL(for: record.id)))
    let loaded = try store.loadDocuments(meeting: record.id)
    #expect(loaded.notes.isEmpty)
    #expect(loaded.repaired == false)
    #expect(loaded.manifest.notes?.revision == 4)
  }

  // MARK: - Interrupted saves

  /// A save of `document` at revision 2 over saved notes at revision 1, interrupted after
  /// `steps` of its writes (1: notes.json; 2: and notes.md). Returns the store and meeting.
  private func interruptedSave(after steps: Int) throws -> (
    MeetingStore, UUID, MeetingNotesDocument
  ) {
    let (store, record) = try makeMeeting()
    let first = MeetingNotesDocument(blocks: [MeetingNoteBlock(startedAtMs: 10, text: "one")])
    _ = try store.saveNotes(first, revision: 1, meeting: record.id)
    var second = first
    second.blocks.append(MeetingNoteBlock(startedAtMs: 20, text: "two"))
    try MeetingStore.encoder.encode(second).write(to: store.notesDocumentURL(for: record.id))
    if steps >= 2 {
      try Data(second.markdown.utf8).write(to: store.notesURL(for: record.id))
    }
    return (store, record.id, second)
  }

  @Test(
    "a save interrupted before notes.md or before the manifest is repaired on load, once",
    arguments: [1, 2])
  func interruptedSaveRepairs(steps: Int) throws {
    let (store, id, second) = try interruptedSave(after: steps)
    let loaded = try store.loadDocuments(meeting: id)
    #expect(loaded.notesDocument == second, "no block is lost")
    #expect(try String(contentsOf: store.notesURL(for: id), encoding: .utf8) == "one\ntwo")
    #expect(loaded.manifest.notes?.revision == 2, "the change counts")
    #expect(loaded.manifest.notes?.sha256 == MeetingDocumentHash.sha256("one\ntwo"))
    let again = try store.loadDocuments(meeting: id)
    #expect(again.repaired == false)
    #expect(again.manifest.notes?.revision == 2, "and counts once")
  }

  @Test("a legacy meeting's first save writes documents.json at format 2")
  func formatMarkedBeforeBlocks() throws {
    let (store, record) = try makeMeeting()
    // v2.6.0 notes with no documents.json at all (a crash in v2.6.0 before its manifest).
    try Data("legacy".utf8).write(to: store.notesURL(for: record.id))
    _ = try store.saveNotes(
      MeetingNotesDocument(blocks: [MeetingNoteBlock(text: "new")]), revision: 1,
      meeting: record.id)
    #expect(try manifestJSON(store, record.id)["formatVersion"] as? Int == 2)
    #expect(try store.loadDocuments(meeting: record.id).notes == "new")
  }

  // MARK: - Unreadable or newer notes.json

  @Test(
    "an unreadable or newer notes.json is kept: the read fails, and no save replaces it",
    arguments: [
      (#"{"version":2,"blocks":[{"id":"x"}]}"#, false),
      ("not json", false),
      (#"{"version":3,"blocks":[],"layout":"columns"}"#, true),
    ])
  func unreadableNotesAreKept(raw: String, newer: Bool) throws {
    let error: MeetingStore.DocumentError = newer ? .newerFormat : .notesUnreadable
    let (store, record) = try makeMeeting()
    try writeLegacy(store, record.id, notes: "older Markdown")
    let original = Data(raw.utf8)
    try original.write(to: store.notesDocumentURL(for: record.id))
    #expect(throws: error) { _ = try store.loadDocuments(meeting: record.id) }
    let draft = MeetingNotesDocument(blocks: [MeetingNoteBlock(text: "draft")])
    #expect(throws: error) { _ = try store.saveNotes(draft, revision: 9, meeting: record.id) }
    #expect(throws: error) { _ = try store.saveDraftNotes(draft, edits: 1, meeting: record.id) }
    #expect(throws: error) { _ = try store.saveNotes("plain", revision: 9, meeting: record.id) }
    #expect(try bytes(store.notesDocumentURL(for: record.id)) == original)
    #expect(try bytes(store.notesURL(for: record.id)) == Data("older Markdown".utf8))
  }

  @Test("a format-2 documents.json refuses a reader that only knows format 1")
  func olderBuildRefuses() throws {
    let (store, record) = try makeMeeting()
    _ = try store.saveNotes(
      MeetingNotesDocument(blocks: [MeetingNoteBlock(text: "x")]), revision: 1, meeting: record.id)
    let format = try #require(try manifestJSON(store, record.id)["formatVersion"] as? Int)
    #expect(format == MeetingDocumentsManifest.currentFormatVersion)
    // v2.6.0's check, verbatim: `formatVersion <= 1` or `.newerFormat`.
    #expect(format > 1, "v2.6.0 refuses to read or write this meeting's documents")
  }

  // MARK: - Plain Markdown save

  @Test("saving plain Markdown keeps the ids and times of unchanged lines")
  func plainSaveKeepsBlocks() throws {
    let (store, record) = try makeMeeting()
    let a = MeetingNoteBlock(startedAtMs: 100, text: "a")
    let b = MeetingNoteBlock(startedAtMs: 200, text: "b")
    _ = try store.saveNotes(MeetingNotesDocument(blocks: [a, b]), revision: 1, meeting: record.id)
    _ = try store.saveNotes("a\nb\nc", revision: 2, meeting: record.id)
    let blocks = try store.loadDocuments(meeting: record.id).notesDocument.blocks
    #expect(blocks.count == 3)
    #expect(Array(blocks.prefix(2)) == [a, b])
    #expect(blocks[2].text == "c" && blocks[2].startedAtMs == nil)
  }

  @Test("a draft save retried after its notes.json landed counts the change once")
  func draftRetryCountsOnce() throws {
    let (store, record) = try makeMeeting()
    _ = try store.saveNotes(
      MeetingNotesDocument(blocks: [MeetingNoteBlock(text: "A")]), revision: 7, meeting: record.id)
    let draft = MeetingNotesDocument(blocks: [MeetingNoteBlock(text: "B")])
    // The first attempt committed notes.json and failed before notes.md and the manifest.
    try MeetingStore.encoder.encode(draft).write(to: store.notesDocumentURL(for: record.id))
    let saved = try store.saveDraftNotes(draft, edits: 1, meeting: record.id)
    #expect(saved.manifest.notes?.revision == 8)
    #expect(saved.notes == "B")
  }
}

