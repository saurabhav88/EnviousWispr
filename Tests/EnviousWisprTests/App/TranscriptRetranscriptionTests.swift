import EnviousWisprAppKitTestSupport
import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprAppKit
@testable import EnviousWisprStorage

/// Class: `.productOutcome`: when these fail, Transcribe again with writes a second copy of a
/// file, loses the user's entry on a failed run, overwrites a change made during the run, or
/// shows two windows two different jobs.
@MainActor
@Suite("Transcribe again with (#3147 PR3)", .tags(.productOutcome), .timeLimit(.minutes(1)))
struct TranscriptRetranscriptionTests {

  @MainActor
  final class FakeSources: ImportedSourceAccessing {
    var stateNow: (UUID) -> ImportedSourceState
    private(set) var lookups = 0
    init(_ state: @escaping (UUID) -> ImportedSourceState) { stateNow = state }
    func revision(for rowID: UUID) -> Int { 0 }
    func state(for rowID: UUID) async -> ImportedSourceState {
      lookups += 1
      return stateNow(rowID)
    }
    func playbackSource(for rowID: UUID) async throws -> ImportedPlaybackSource? { nil }
    func relocate(rowID: UUID, to url: URL, userConfirmed: Bool) async throws
      -> ImportedRelocationOutcome
    { .stale }
  }

  /// A row's stored form, for "unchanged" (`Transcript` is not `Equatable`).
  private func stored(_ row: Transcript?) -> Data? {
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    return row.flatMap { try? encoder.encode($0) }
  }

  struct Fixture {
    let history: TranscriptCoordinator
    let rig: ImportedTranscriberRig
    let sources: FakeSources
    let owner: TranscriptRetranscription
    let row: Transcript
  }

  private func fixture() async throws -> Fixture {
    let dir = TestTemporaryDirectory.url
      .appendingPathComponent("ew-3147-retranscribe-\(UUID().uuidString)", isDirectory: true)
    let history = TranscriptCoordinator(store: TranscriptStore(directory: dir))
    let row = Transcript(
      text: "old words", polishedText: "Old words.", duration: 42, backendType: .parakeet,
      createdAt: Date(timeIntervalSince1970: 1_000), importedFileName: "talk.m4a",
      speakerAnalysis: .labeled(count: 1), speakerNames: ["s1": "Ana"],
      turns: [Turn(id: "t1", speakerId: "s1", startMs: 0, endMs: 900, originalTextRange: 0..<9)],
      sourceBookmark: Data([1]), sourceFingerprint: "v1:10:1000:aa", importAttemptID: UUID())
    try await history.saveAndShow(row)
    let resolved = ResolvedImportedSource(
      rowID: row.id, reference: ImportedSourceReference(row),
      url: URL(fileURLWithPath: "/tmp/talk.m4a"), identity: ImportedTranscriberRig.identity)
    let sources = FakeSources { _ in .available(resolved) }
    let rig = ImportedTranscriberRig()
    let owner = TranscriptRetranscription(
      history: history, sources: sources, transcriber: rig.makeTranscriber(),
      installedModels: { [unowned rig] in rig.installed })
    return Fixture(history: history, rig: rig, sources: sources, owner: owner, row: row)
  }

  @Test("success replaces the one row in place with the new words and a new attempt")
  func replacesInPlace() async throws {
    let f = try await fixture()
    #expect(f.owner.state(for: f.row.id) == .idle)
    #expect(f.rig.engines.loads.isEmpty, "nothing runs before the confirmed start")
    let outcome = await f.owner.startConfirmed(
      rowID: f.row.id, selection: ImportedTranscriberRig.whisperChoice)
    #expect(outcome == .replaced)
    #expect(f.owner.state(for: f.row.id) == .finished(.replaced))
    let now = try #require(f.history.currentRow(id: f.row.id))
    #expect(f.history.visibleTranscripts.count == 1, "no second row")
    #expect(now.text == "fresh words from the file")
    #expect(now.polishedText == "Polished 0: fresh words from the file")
    #expect(now.backendType == .whisper)
    #expect(now.turns == nil && now.speakerNames == nil, "old turns never index new words")
    #expect(now.createdAt == f.row.createdAt && now.importedFileName == "talk.m4a")
    #expect(now.duration == 42 && now.sourceBookmark == Data([1]))
    #expect(now.sourceFingerprint == f.row.sourceFingerprint)
    #expect(now.importAttemptID != nil && now.importAttemptID != f.row.importAttemptID)
  }

  @Test("a failed transcription or a missing original keeps the old row unchanged")
  func failureKeepsRow() async throws {
    let failed = try await fixture()
    failed.rig.engines.transcribeError = CocoaError(.fileReadCorruptFile)
    #expect(
      await failed.owner.startConfirmed(
        rowID: failed.row.id, selection: ImportedTranscriberRig.parakeetChoice) == .failed)
    #expect(stored(failed.history.currentRow(id: failed.row.id)) == stored(failed.row))
    #expect(failed.rig.engineIsFree)

    let missing = try await fixture()
    missing.sources.stateNow = { _ in .missing }
    #expect(
      await missing.owner.startConfirmed(
        rowID: missing.row.id, selection: ImportedTranscriberRig.parakeetChoice)
        == .sourceUnavailable)
    #expect(stored(missing.history.currentRow(id: missing.row.id)) == stored(missing.row))
    #expect(missing.rig.engines.loads.isEmpty)
  }

  @Test("a change to the row during the run, or its deletion, refuses the replacement")
  func changeDuringRunWins() async throws {
    let edited = try await fixture()
    // A cleanup written to the row while the new transcription runs (another writer's change).
    let renamed = edited.row.withImportResult(
      "Cleaned again meanwhile.", wasPolished: true, llmProvider: "egOne", llmModel: "eg-1")
    edited.rig.engines.onTranscribeEntered = { [history = edited.history] in
      _ = try? await history.updateExistingRow(renamed)
    }
    #expect(
      await edited.owner.startConfirmed(
        rowID: edited.row.id, selection: ImportedTranscriberRig.parakeetChoice) == .stale)
    #expect(edited.history.currentRow(id: edited.row.id)?.polishedText == "Cleaned again meanwhile.")
    #expect(edited.history.currentRow(id: edited.row.id)?.text == "old words")

    let deleted = try await fixture()
    deleted.rig.engines.onTranscribeEntered = { [history = deleted.history, id = deleted.row.id] in
      _ = await history.deleteHistoryItem(id: .transcript(id), kind: .textAndRecordings)
    }
    #expect(
      await deleted.owner.startConfirmed(
        rowID: deleted.row.id, selection: ImportedTranscriberRig.parakeetChoice) == .stale)
    #expect(deleted.history.currentRow(id: deleted.row.id) == nil, "the deletion stands")
    #expect(deleted.history.visibleTranscripts.isEmpty)
  }

  @Test("two windows share one job; Cancel drains, frees the engine once, keeps the old row")
  func sharedJobAndCancel() async throws {
    let f = try await fixture()
    f.rig.engines.holdsTranscribe = true
    let first = Task {
      await f.owner.startConfirmed(
        rowID: f.row.id, selection: ImportedTranscriberRig.parakeetChoice)
    }
    await f.rig.engines.waitUntilInsideTranscribe()
    #expect(f.owner.state(for: f.row.id) == .running(fraction: nil))
    // A second window's start for the same row joins nothing new.
    #expect(
      await f.owner.startConfirmed(
        rowID: f.row.id, selection: ImportedTranscriberRig.whisperChoice) == .busy)
    #expect(f.rig.engines.loads.count == 1)

    f.owner.cancel(rowID: f.row.id)
    #expect(f.owner.state(for: f.row.id) == .cancelling)
    #expect(f.rig.engineIsFree == false, "the engine stays claimed until the decode exits")
    f.rig.engines.releaseTranscribe()
    #expect(await first.value == .cancelled)
    #expect(f.owner.state(for: f.row.id) == .finished(.cancelled))
    #expect(f.rig.engines.unloads == 1 && f.rig.releases == 1 && f.rig.engineIsFree)
    #expect(stored(f.history.currentRow(id: f.row.id)) == stored(f.row))
    #expect(f.owner.isEngineHeld == false)
  }

  @Test("choices list the installed models and mark current only when the engine has one model")
  func choicesFromInstalledModels() async throws {
    let f = try await fixture()
    let ultra = ImportedASRChoice(
      id: "parakeet.ultra", title: "Parakeet Ultra",
      selection: ImportedTranscriberRig.parakeetChoice, isCurrent: true)
    let whisper = ImportedASRChoice(
      id: "whisper", title: "Whisper Large v3 Turbo",
      selection: ImportedTranscriberRig.whisperChoice, isCurrent: true)
    guard case .parakeet(let ultraSelection, _) = ImportedTranscriberRig.parakeetChoice else {
      return
    }
    let v3 = ImportedASRChoice(
      id: "parakeet.v3", title: "Parakeet v3",
      selection: .parakeet(
        ParakeetModelSelection(
          model: .v3, revision: nil, directory: URL(fileURLWithPath: "/tmp/v3"),
          cacheOnly: true, displayBytes: 1, repairable: false, generation: 2),
        identity: ASRModelIdentity(name: "parakeet-v3", revision: nil, variant: nil)),
      isCurrent: false)
    #expect(ultraSelection.model == .ultra)

    #expect(f.owner.choices(for: f.row.id).isEmpty, "nothing installed, nothing offered")
    f.rig.installed = [ultra, whisper]
    let one = f.owner.choices(for: f.row.id)
    #expect(one.map(\.id) == ["parakeet.ultra", "whisper"])
    #expect(one.map(\.isCurrent) == [true, false], "the row was made by Parakeet")
    f.rig.installed = [v3, ultra, whisper]
    #expect(
      f.owner.choices(for: f.row.id).map(\.isCurrent) == [false, false, false],
      "two Parakeet models: which one made the text is unknown")
    #expect(f.owner.choices(for: UUID()).isEmpty, "a row that is gone offers nothing")
    #expect(f.rig.engines.loads.isEmpty && f.rig.frozenBackends.isEmpty, "listing runs nothing")
  }

  @Test("a dictation holding the engine answers busy and leaves the row alone")
  func busyEngine() async throws {
    let f = try await fixture()
    guard case .granted(let dictation) = f.rig.lease.admit(.dictation) else {
      Issue.record("the dictation claim was refused")
      return
    }
    #expect(
      await f.owner.startConfirmed(
        rowID: f.row.id, selection: ImportedTranscriberRig.parakeetChoice) == .busy)
    #expect(stored(f.history.currentRow(id: f.row.id)) == stored(f.row))
    f.rig.lease.release(dictation)
  }
}
