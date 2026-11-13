import EnviousWisprAppKitTestSupport
import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprAppKit
@testable import EnviousWisprStorage

/// History's commands for imported transcripts (#3147 PR3): relinking the original file only
/// over the link the caller saw, Transcribe again with replacing an import in place only while
/// nothing changed since the user confirmed, and late writes from an older transcription of the
/// same file being refused.
@MainActor
/// Class: `.productOutcome` — whether a relink, a re-transcription or a late background write
/// can overwrite the user's entry with the wrong text or the wrong file.
@Suite("Imported transcript commands (#3147 PR3)", .tags(.productOutcome))
struct ImportedTranscriptCommandsTests {

  private func makeCoordinator() -> TranscriptCoordinator {
    let dir = TestTemporaryDirectory.url
      .appendingPathComponent("ew-3147-imports-\(UUID().uuidString)", isDirectory: true)
    return TranscriptCoordinator(store: TranscriptStore(directory: dir))
  }

  private func importRow(fingerprint: String? = "v1:1:1:aa", attempt: UUID? = UUID())
    -> Transcript
  {
    Transcript(
      text: "old words", polishedText: "Old.", importedFileName: "talk.m4a",
      sourceBookmark: Data([1]), sourceFingerprint: fingerprint, importAttemptID: attempt)
  }

  @Test("relink writes only over the link the caller saw, and only with the stored fingerprint")
  func relinkIsCompareAndSet() async throws {
    let coordinator = makeCoordinator()
    let row = importRow()
    try await coordinator.saveAndShow(row)
    var stopped: [UUID] = []
    coordinator.onImportedContentWillChange = { stopped.append($0) }
    let seen = ImportedSourceReference(row)

    #expect(
      try await coordinator.setImportedSource(
        bookmark: Data([2]), fingerprint: "v1:9:9:bb", for: row.id, expected: seen,
        confirmedLegacy: true) == false, "a known fingerprint is never replaced")
    #expect(
      try await coordinator.setImportedSource(
        bookmark: Data([2]), fingerprint: "v1:1:1:aa", for: row.id, expected: seen,
        confirmedLegacy: false))
    #expect(coordinator.currentRow(id: row.id)?.sourceBookmark == Data([2]))
    #expect(stopped == [row.id])
    #expect(
      try await coordinator.setImportedSource(
        bookmark: Data([3]), fingerprint: "v1:1:1:aa", for: row.id, expected: seen,
        confirmedLegacy: false) == false, "the link changed since the caller looked")
  }

  @Test("a legacy row takes a link only with the user's confirmation")
  func legacyRelinkNeedsConfirmation() async throws {
    let coordinator = makeCoordinator()
    let row = Transcript(text: "raw", importedFileName: "old.wav")
    try await coordinator.saveAndShow(row)
    let seen = ImportedSourceReference(row)
    #expect(
      try await coordinator.setImportedSource(
        bookmark: Data([1]), fingerprint: "v1:1:1:aa", for: row.id, expected: seen,
        confirmedLegacy: false) == false)
    #expect(
      try await coordinator.setImportedSource(
        bookmark: Data([1]), fingerprint: "v1:1:1:aa", for: row.id, expected: seen,
        confirmedLegacy: true))
    #expect(coordinator.currentRow(id: row.id)?.sourceFingerprint == "v1:1:1:aa")
    let dictation = Transcript(text: "spoken")
    try await coordinator.saveAndShow(dictation)
    #expect(
      try await coordinator.setImportedSource(
        bookmark: Data([1]), fingerprint: nil, for: dictation.id,
        expected: ImportedSourceReference(dictation), confirmedLegacy: true) == false)
  }

  @Test("Transcribe again replaces the entry in place with a new attempt and stops its players")
  func replacementCommits() async throws {
    let coordinator = makeCoordinator()
    let row = importRow()
    try await coordinator.saveAndShow(row)
    var stopped: [UUID] = []
    coordinator.onImportedContentWillChange = { stopped.append($0) }

    let ticket = try #require(try await coordinator.beginImportedReplacement(for: row.id))
    let result = Transcript(text: "new words", backendType: .whisper)
    #expect(try await coordinator.commitImportedReplacement(result, ticket: ticket))
    let now = try #require(coordinator.currentRow(id: row.id))
    #expect(now.text == "new words")
    #expect(now.polishedText == nil)
    #expect(now.importAttemptID == ticket.attemptID)
    #expect(now.sourceBookmark == Data([1]))
    #expect(coordinator.visibleTranscripts.filter(\.isImported).count == 1, "no second row")
    #expect(stopped == [row.id])
    #expect(
      try await coordinator.commitImportedReplacement(result, ticket: ticket) == false,
      "a ticket is used once")
  }

  @Test("a replacement refuses after the row changed, a newer ticket, or deletion")
  func replacementRefusesStale() async throws {
    let coordinator = makeCoordinator()
    let row = importRow()
    try await coordinator.saveAndShow(row)
    let result = Transcript(text: "new words")

    let first = try #require(try await coordinator.beginImportedReplacement(for: row.id))
    // The stored row changes after the ticket (a cleanup landing new text).
    #expect(
      try await coordinator.updateExistingRow(
        row.withImportResult("Edited.", wasPolished: true, llmProvider: nil, llmModel: nil)))
    #expect(try await coordinator.commitImportedReplacement(result, ticket: first) == false)

    let older = try #require(try await coordinator.beginImportedReplacement(for: row.id))
    let newer = try #require(try await coordinator.beginImportedReplacement(for: row.id))
    #expect(try await coordinator.commitImportedReplacement(result, ticket: older) == false)

    _ = await coordinator.deleteHistoryItem(id: .transcript(row.id), kind: .textAndRecordings)
    #expect(try await coordinator.commitImportedReplacement(result, ticket: newer) == false)
    #expect(try await coordinator.beginImportedReplacement(for: row.id) == nil)
  }

  @Test("writes from an older transcription of the file are refused after a replacement")
  func lateWizardWritesAreRefused() async throws {
    let coordinator = makeCoordinator()
    let attempt = UUID()
    let row = importRow(attempt: attempt)
    try await coordinator.saveAndShow(row)

    // Same attempt: the wizard's own late writes still land.
    #expect(
      try await coordinator.mergeImportedSpeakerFields(
        id: row.id, expectedAttemptID: attempt, analysis: .single, turns: nil))
    #expect(try await coordinator.updateExistingRow(row))

    let ticket = try #require(try await coordinator.beginImportedReplacement(for: row.id))
    #expect(
      try await coordinator.commitImportedReplacement(
        Transcript(text: "old words"), ticket: ticket), "identical text is still a new attempt")

    #expect(
      try await coordinator.mergeImportedSpeakerFields(
        id: row.id, expectedAttemptID: attempt, analysis: .labeled(count: 2), turns: nil)
        == false)
    #expect(try await coordinator.updateExistingRow(row) == false)
    #expect(coordinator.currentRow(id: row.id)?.speakerAnalysis != .labeled(count: 2))
  }

  @Test("a Cancel while the replacement's check runs wins, at the start and at the commit")
  func cancelDuringDigestWins() async throws {
    let coordinator = makeCoordinator()
    let row = importRow()
    try await coordinator.saveAndShow(row)

    coordinator.rowDigestWillRunForTesting = { coordinator.invalidateImportedReplacement(for: row.id) }
    #expect(try await coordinator.beginImportedReplacement(for: row.id) == nil)

    coordinator.rowDigestWillRunForTesting = nil
    let ticket = try #require(try await coordinator.beginImportedReplacement(for: row.id))
    coordinator.rowDigestWillRunForTesting = { coordinator.invalidateImportedReplacement(for: row.id) }
    #expect(
      try await coordinator.commitImportedReplacement(Transcript(text: "new"), ticket: ticket)
        == false)
    #expect(coordinator.currentRow(id: row.id)?.text == "old words")
  }

  @Test("deleting an import stops its players")
  func deletionStopsPlayers() async throws {
    let coordinator = makeCoordinator()
    let row = importRow()
    try await coordinator.saveAndShow(row)
    var stopped: [UUID] = []
    coordinator.onImportedContentWillChange = { stopped.append($0) }
    #expect(
      await coordinator.deleteHistoryItem(id: .transcript(row.id), kind: .textAndRecordings)
        == .removed)
    #expect(stopped == [row.id])
  }

  @Test("an import's cleaned update keeps the link History holds now")
  func cleanedUpdateKeepsCurrentLink() async throws {
    let coordinator = makeCoordinator()
    let row = importRow()
    try await coordinator.saveAndShow(row)
    _ = try await coordinator.setImportedSource(
      bookmark: Data([7]), fingerprint: "v1:1:1:aa", for: row.id,
      expected: ImportedSourceReference(row), confirmedLegacy: false)
    // The wizard's copy still carries the link it imported with.
    #expect(try await coordinator.updateExistingRow(row))
    #expect(coordinator.currentRow(id: row.id)?.sourceBookmark == Data([7]))
  }
}
