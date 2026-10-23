import Foundation
import Testing

@testable import EnviousWisprCore
@testable import EnviousWisprStorage

/// #3972 R46, R53, R56: when these fail, a user's meeting notes are lost, a late save brings a
/// deleted meeting back, a summary written from old notes looks current, or an older build
/// rewrites a meeting it cannot read.
@Suite("Meeting notes and summary files", .tags(.productOutcome))
struct MeetingDocumentsStoreTests {
  private func makeMeeting() throws -> (MeetingStore, MeetingRecord) {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("MeetingDocumentsStoreTests-\(UUID().uuidString)", isDirectory: true)
    let store = MeetingStore(root: root)
    let record = MeetingRecord(engine: .parakeet, trackStatus: [.microphone: .captured])
    try store.create(record)
    return (store, record)
  }

  @Test("notes save and load back; Delete audio keeps them, Delete meeting removes them")
  func notesRoundTrip() throws {
    let (store, record) = try makeMeeting()
    let written = try store.saveNotes("Agenda: budget", revision: 1, meeting: record.id)
    #expect(written.notes?.revision == 1)
    let loaded = try store.loadDocuments(meeting: record.id)
    #expect(loaded.notes == "Agenda: budget")
    #expect(loaded.repaired == false)

    try store.deleteAudio(meeting: record.id)
    #expect(try store.loadDocuments(meeting: record.id).notes == "Agenda: budget")

    try store.deleteFolder(meeting: record.id)
    #expect(!FileManager.default.fileExists(atPath: store.notesURL(for: record.id).path))
  }

  @Test("a save never recreates a deleted or deleting meeting")
  func refusesGoneMeetings() throws {
    let (store, record) = try makeMeeting()
    var deleting = record
    deleting.deletionRequested = true
    try store.save(deleting)
    #expect(throws: MeetingStore.DocumentError.meetingDeleting) {
      _ = try store.saveNotes("late", revision: 1, meeting: record.id)
    }
    try store.deleteFolder(meeting: record.id)
    #expect(throws: MeetingStore.DocumentError.meetingMissing) {
      _ = try store.saveNotes("late", revision: 2, meeting: record.id)
    }
    #expect(!FileManager.default.fileExists(atPath: store.folder(for: record.id).path))
  }

  @Test("notes changed behind the manifest win, and make the summary out of date")
  func notesNewerThanManifest() throws {
    let (store, record) = try makeMeeting()
    _ = try store.saveNotes("first", revision: 1, meeting: record.id)
    let inputs = SummaryInputs(
      transcriptSHA256: "t", notesRevision: 1, speakerNamesSHA256: "s", promptVersion: 1,
      providerID: "openAI", configurationSHA256: "c")
    _ = try store.saveSummary("A summary", origin: .generated, inputs: inputs, meeting: record.id)
    // A crash after notes.md and before documents.json: only the file changed.
    try Data("second".utf8).write(to: store.notesURL(for: record.id))

    let loaded = try store.loadDocuments(meeting: record.id)
    #expect(loaded.notes == "second")
    #expect(loaded.repaired)
    #expect(loaded.manifest.notes?.revision == 2)
    #expect(loaded.manifest.summary?.inputs?.notesRevision == 1, "the summary is now stale")
    #expect(loaded.manifest.summary?.origin == .generated)
  }

  @Test("a summary changed behind the manifest counts as the user's own text")
  func summaryEditedOutside() throws {
    let (store, record) = try makeMeeting()
    _ = try store.saveSummary("Generated", origin: .generated, inputs: nil, meeting: record.id)
    try Data("Mine now".utf8).write(to: store.summaryURL(for: record.id))
    let loaded = try store.loadDocuments(meeting: record.id)
    #expect(loaded.summary == "Mine now")
    #expect(loaded.manifest.summary?.origin == .userEdited)
  }

  @Test("a notes save keeps a summary entry written after the caller's last read")
  func notesSaveKeepsSummary() throws {
    let (store, record) = try makeMeeting()
    _ = try store.saveSummary("Summary", origin: .generated, inputs: nil, meeting: record.id)
    _ = try store.saveNotes("notes", revision: 1, meeting: record.id)
    let loaded = try store.loadDocuments(meeting: record.id)
    #expect(loaded.summary == "Summary")
    #expect(loaded.manifest.summary?.origin == .generated)
    #expect(loaded.repaired == false)
  }

  @Test("empty notes remove notes.md; a newer documents.json is never rewritten")
  func emptyNotesAndNewerFormat() throws {
    let (store, record) = try makeMeeting()
    _ = try store.saveNotes("x", revision: 1, meeting: record.id)
    _ = try store.saveNotes("", revision: 2, meeting: record.id)
    #expect(!FileManager.default.fileExists(atPath: store.notesURL(for: record.id).path))
    #expect(try store.loadDocuments(meeting: record.id).repaired == false)

    let future = Data(#"{"formatVersion": 9}"#.utf8)
    try future.write(to: store.documentsURL(for: record.id))
    #expect(throws: MeetingStore.DocumentError.newerFormat) {
      _ = try store.loadDocuments(meeting: record.id)
    }
    #expect(throws: MeetingStore.DocumentError.newerFormat) {
      _ = try store.saveNotes("y", revision: 3, meeting: record.id)
    }
    #expect(try Data(contentsOf: store.documentsURL(for: record.id)) == future)
  }

  @Test("a notes-only meeting is written as format 2; a format-1 meeting stays format 1")
  func notesOnlyRaisesFormat() throws {
    // A record as format 1 wrote it: today's encoding with the old version number.
    let fresh = MeetingRecord(engine: .parakeet, trackStatus: [.microphone: .captured])
    var object = try #require(
      try JSONSerialization.jsonObject(with: MeetingStore.encoder.encode(fresh))
        as? [String: Any])
    object["formatVersion"] = 1
    let legacy = try JSONSerialization.data(withJSONObject: object)
    var record = try MeetingStore.decoder.decode(MeetingRecord.self, from: legacy)
    #expect(record.formatVersion == 1)
    record.markNotesOnly()
    #expect(record.state == .notesOnly)
    #expect(record.formatVersion == 2)
  }

  @Test("a manifest written before the configuration fingerprint still loads, and saves notes")
  func manifestWithoutConfigurationFingerprint() throws {
    let (store, record) = try makeMeeting()
    // documents.json as commit fa076081 wrote it: summary inputs with no configurationSHA256.
    let old = """
      {"formatVersion":1,"notes":{"revision":1,"sha256":"\(MeetingDocumentHash.sha256("n"))"},
       "summary":{"origin":"generated","sha256":"\(MeetingDocumentHash.sha256("S"))",
       "inputs":{"notesRevision":1,"promptVersion":1,"providerID":"openAI",
       "speakerNamesSHA256":"s","transcriptSHA256":"t"}}}
      """
    try Data("n".utf8).write(to: store.notesURL(for: record.id))
    try Data("S".utf8).write(to: store.summaryURL(for: record.id))
    try Data(old.utf8).write(to: store.documentsURL(for: record.id))

    let loaded = try store.loadDocuments(meeting: record.id)
    #expect(loaded.summary == "S")
    #expect(loaded.manifest.summary?.inputs?.configurationSHA256 == nil, "unknown, so out of date")
    _ = try store.saveNotes("n2", revision: 2, meeting: record.id)
    #expect(try store.loadDocuments(meeting: record.id).notes == "n2")
  }

  @Test("a draft saved after a failed read keeps the read's summary reconciliation")
  func draftSaveKeepsSummaryReconciliation() throws {
    let (store, record) = try makeMeeting()
    _ = try store.saveSummary("Generated", origin: .generated, inputs: nil, meeting: record.id)
    try Data("Edited outside".utf8).write(to: store.summaryURL(for: record.id))

    let saved = try store.saveDraftNotes("draft", edits: 2, meeting: record.id)
    #expect(saved.summary == "Edited outside")
    #expect(saved.manifest.summary?.origin == .userEdited)
    let reread = try store.loadDocuments(meeting: record.id)
    #expect(reread.manifest.summary?.origin == .userEdited)
    #expect(reread.repaired == false, "the draft save wrote the reconciled manifest")
    #expect(reread.notes == "draft")
    #expect(reread.manifest.notes?.revision == 2)
  }
}
