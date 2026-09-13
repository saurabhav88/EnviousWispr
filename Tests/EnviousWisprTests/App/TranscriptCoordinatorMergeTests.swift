import EnviousWisprCore
import EnviousWisprServices
import Foundation
import Testing

@testable import EnviousWisprAppKit
@testable import EnviousWisprStorage

/// `TranscriptCoordinator.mergeSpeakerFields` (#2810 addendum §3 E, phase 3 of #2807) — the
/// one write path the turn-cleanup pass and a future phase-4 rename share. Driven against a
/// REAL `TranscriptStore(directory:)` under a temp directory, no fakes: the contract that
/// matters is what actually lands on disk and in the coordinator's own in-memory list.
@MainActor
@Suite("TranscriptCoordinator.mergeSpeakerFields (#2810)", .tags(.productOutcome))
struct TranscriptCoordinatorMergeTests {

  private static func makeTempDir() -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("2810-merge-\(UUID().uuidString)", isDirectory: true)
  }

  private static func makeTranscript(id: UUID = UUID(), text: String = "hello") -> Transcript {
    Transcript(id: id, text: text, processingTime: 0.1, backendType: .parakeet, createdAt: Date())
  }

  private static func makeTurns(speaker: String = "A") -> [Turn] {
    [Turn(id: "0-5", speakerId: speaker, startMs: 0, endMs: 100, originalTextRange: 0..<5)]
  }

  private func row(_ coordinator: TranscriptCoordinator, _ id: UUID) -> Transcript? {
    coordinator.filteredTranscripts.first { $0.id == id }
  }

  private func freshlyLoaded(from dir: URL) async -> TranscriptCoordinator {
    let coordinator = TranscriptCoordinator(store: TranscriptStore(directory: dir))
    coordinator.load()
    await coordinator.waitForLoadForTesting()
    return coordinator
  }

  @Test("merging into an existing row persists to disk and to the in-memory list")
  func mergeSucceedsAgainstExistingRow() async throws {
    let dir = Self.makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = TranscriptStore(directory: dir)
    let coordinator = TranscriptCoordinator(store: store)
    let original = Self.makeTranscript()
    try coordinator.saveAndShow(original)

    let saved = try coordinator.mergeSpeakerFields(
      id: original.id, analysis: .labeled(count: 1), turns: Self.makeTurns())
    #expect(saved)
    #expect(row(coordinator, original.id)?.speakerAnalysis == .labeled(count: 1))

    // Round-trip through a FRESH coordinator loading from disk, proving this is a real
    // persisted write, not just an in-memory mutation.
    let reloaded = await freshlyLoaded(from: dir)
    let reloadedRow = row(reloaded, original.id)
    #expect(reloadedRow?.speakerAnalysis == .labeled(count: 1))
    #expect(reloadedRow?.turns?.first?.speakerId == "A")
  }

  @Test(
    "merging into a row deleted since the write was requested returns false and resurrects nothing")
  func mergeAfterDeletionReturnsFalse() async throws {
    let dir = Self.makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = TranscriptStore(directory: dir)
    let coordinator = TranscriptCoordinator(store: store)
    let original = Self.makeTranscript()
    try coordinator.saveAndShow(original)
    coordinator.delete(original)

    let saved = try coordinator.mergeSpeakerFields(
      id: original.id, analysis: .labeled(count: 1), turns: Self.makeTurns())
    #expect(saved == false)

    let reloaded = await freshlyLoaded(from: dir)
    #expect(row(reloaded, original.id) == nil, "a deleted row must never be resurrected")
  }

  @Test("a cleanup merge and an explicit rename compose: the rename survives a later cleanup pass")
  func cleanupMergeAndExplicitRenameCompose() throws {
    let dir = Self.makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = TranscriptStore(directory: dir)
    let coordinator = TranscriptCoordinator(store: store)
    let original = Self.makeTranscript()
    try coordinator.saveAndShow(original)

    // First cleanup pass: default name.
    _ = try coordinator.mergeSpeakerFields(
      id: original.id, analysis: .labeled(count: 1), turns: Self.makeTurns())
    #expect(row(coordinator, original.id)?.speakerNames == ["A": "Speaker 1"])

    // An explicit rename (phase 4, simulated here at the storage layer).
    _ = try coordinator.mergeSpeakerFields(
      id: original.id, analysis: .labeled(count: 1), turns: Self.makeTurns(),
      explicitRename: ("A", "Zach"))
    #expect(row(coordinator, original.id)?.speakerNames == ["A": "Zach"])

    // A LATER cleanup pass (e.g. a retry) over the SAME surviving speakerId must not
    // clobber the rename back to a freshly-computed default — this is the exact race the
    // addendum's "delayed cleanup vs. explicit rename" contract exists to prevent.
    _ = try coordinator.mergeSpeakerFields(
      id: original.id, analysis: .labeled(count: 1), turns: Self.makeTurns())
    #expect(row(coordinator, original.id)?.speakerNames == ["A": "Zach"])
  }

  @Test("a real store write failure throws and leaves the existing row completely unchanged")
  func mergeThrowsAndPreservesExistingRowOnRealStoreFailure() async throws {
    let dir = Self.makeTempDir()
    defer {
      try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
      try? FileManager.default.removeItem(at: dir)
    }
    let store = TranscriptStore(directory: dir)
    let coordinator = TranscriptCoordinator(store: store)
    let original = Self.makeTranscript()
    try coordinator.saveAndShow(original)

    // `.sortedKeys`: `JSONEncoder`'s default key order is UNSPECIFIED and varies between
    // separate `encode()` calls for equal values (confirmed by running this test through
    // the real Xcode gate: two encodes of the identical content produced different byte
    // orderings), so a byte-for-byte comparison across independent encodes needs a forced
    // deterministic order or it is comparing noise, not content (found by chunk review
    // round 3's own "byte-for-byte" ask surfacing a latent bug in the proof itself).
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    let fileURL = dir.appendingPathComponent("\(original.id.uuidString).json")
    let originalEncoded = try encoder.encode(original)
    let bytesBeforeFailure = try Data(contentsOf: fileURL)

    // Force a REAL write failure — strip write permission from the transcripts directory
    // itself, so the store's own temp-file-then-rename write throws, never a fake
    // simulating one (found by chunk review round 2).
    try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: dir.path)

    #expect(throws: (any Error).self) {
      try coordinator.mergeSpeakerFields(
        id: original.id, analysis: .labeled(count: 1), turns: Self.makeTurns())
    }

    // Restored before reading anything back — the directory's own listing needs it too.
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)

    // `updateExistingRow` calls `store.save` BEFORE mutating `transcripts`, so a failed
    // write must never half-apply. Proven BYTE-FOR-BYTE against the original's own encoding
    // — checking that two optional fields stayed `nil` would also pass if the row vanished
    // or were rebuilt from a bare default (found by chunk review round 3).
    let inMemoryRow = row(coordinator, original.id)
    #expect(inMemoryRow != nil, "the row must still exist in memory after a failed write")
    if let inMemoryRow {
      #expect(try encoder.encode(inMemoryRow) == originalEncoded)
    }

    // And the ON-DISK bytes are equally untouched — the literal file contents, not merely
    // the same decoded shape.
    let bytesAfterFailure = try Data(contentsOf: fileURL)
    #expect(
      bytesAfterFailure == bytesBeforeFailure, "the on-disk file changed despite the write throwing"
    )

    let reloaded = await freshlyLoaded(from: dir)
    let reloadedRow = row(reloaded, original.id)
    #expect(reloadedRow != nil, "a fresh reload must still find the row")
    if let reloadedRow {
      #expect(try encoder.encode(reloadedRow) == originalEncoded)
    }
  }

  @Test("a relaunch after an interrupted pass sees the row exactly as it was last durably written")
  func relaunchAfterInterruptedPassSeesLastDurableState() async throws {
    let dir = Self.makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = TranscriptStore(directory: dir)
    let coordinator = TranscriptCoordinator(store: store)
    let original = Self.makeTranscript()
    try coordinator.saveAndShow(original)
    // No merge call at all — simulates a turn-cleanup pass that never got to write because
    // the app quit mid-pass. The row must simply stay at its pre-#2810 shape: `nil` speaker
    // fields, never a half-written one, because `mergeSpeakerFields` makes exactly one
    // atomic write per call and this scenario never called it.
    let reloaded = await freshlyLoaded(from: dir)
    let reloadedRow = row(reloaded, original.id)
    #expect(reloadedRow?.speakerAnalysis == nil)
    #expect(reloadedRow?.turns == nil)
  }

  @Test("renameSpeaker reports saved on success and failed against a row with no turns (#2811)")
  func renameSpeakerTelemetryReportsSavedAndFailed() async throws {
    let dir = Self.makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = TranscriptStore(directory: dir)
    @MainActor final class TelemetryRecorder {
      private(set) var outcomes: [TelemetryService.FileImportRenameOutcome] = []
      func record(_ outcome: TelemetryService.FileImportRenameOutcome) { outcomes.append(outcome) }
    }
    let telemetry = TelemetryRecorder()
    let coordinator = TranscriptCoordinator(
      store: store, emitRenameTelemetry: { telemetry.record($0) })
    let labeled = Self.makeTranscript()
    try coordinator.saveAndShow(labeled)
    _ = try coordinator.mergeSpeakerFields(
      id: labeled.id, analysis: .labeled(count: 1), turns: Self.makeTurns())

    let failure = coordinator.renameSpeaker(id: labeled.id, speakerId: "A", name: "Zach")
    #expect(failure == nil)
    #expect(telemetry.outcomes == [.saved])

    let unlabeled = Self.makeTranscript()
    try coordinator.saveAndShow(unlabeled)
    let secondFailure = coordinator.renameSpeaker(id: unlabeled.id, speakerId: "A", name: "Zach")
    #expect(secondFailure != nil, "a row with no turns has nothing to rename against")
    #expect(telemetry.outcomes == [.saved, .failed])
  }
}
