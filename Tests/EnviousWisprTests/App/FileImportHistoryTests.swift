import EnviousWisprASR
import EnviousWisprCore
import EnviousWisprPipeline
import Foundation
import Testing

@testable import EnviousWisprAppKit

/// #2772 finding 11 — imports reach History, and the RAW words get there first.
///
/// Founder: "We had agreed when planning this feature that transcriptions would be saved to
/// history once done." The approved plan said so in three places and none of it shipped: on
/// merged main, `TranscriptStore.save(_:)` had exactly two callers and neither was the file
/// import.
///
/// **What fails when these fail is a person losing words.** Product coverage, not a drift
/// guard: a forty-minute cleanup runs after the audio has been released, so words that are
/// not durable before the cleanup starts have nothing left to be recovered from.
@MainActor
@Suite("File import reaches History (#2772)", .tags(.productOutcome))
struct FileImportHistoryTests {

  /// Records every write, and can be told to refuse. A real store cannot be made to fail on
  /// demand, and the failing path is the one the approved plan writes a rule about.
  @MainActor
  private final class HistorySpy {
    private(set) var writes: [Transcript] = []
    var refuse = false
    private(set) var refusals = 0

    struct Refused: Error {}

    func save(_ transcript: Transcript) throws {
      if refuse {
        refusals += 1
        throw Refused()
      }
      writes.append(transcript)
    }
  }

  private static let anyURL = URL(fileURLWithPath: "/tmp/marketing-sync.m4a")

  nonisolated private static func decoded() -> AudioFileDecoder.Decoded {
    AudioFileDecoder.Decoded(
      samples: Array(repeating: 0.1, count: 16_000), seconds: 61,
      byteCount: 279_000, codec: "AAC", sampleRate: 22_050, channelCount: 1)
  }

  private static func coordinator(
    spy: HistorySpy, raw: String = "um one two three", cleaned: String = "One two three.",
    onPart: (@MainActor () -> Void)? = nil
  ) -> FileImportCoordinator {
    FileImportCoordinator(
      decode: { _ in Self.decoded() },
      transcribe: { _ in (text: raw, language: "en") },
      engineAdmission: .live(lease: EngineLease(), as: .fileImport),
      beginRun: {
        FileImportCoordinator.RunConfiguration(
          polishIsCloud: false, localPolishProvider: nil, polishProvider: .egOne,
          ollamaModel: nil, polishModel: "eg-1", backendType: .parakeet)
      },
      saveToHistory: { try spy.save($0) },
      processPart: { _, _ in
        onPart?()
        return FileImportRunner.PartOutcome(
          text: cleaned, polishedText: cleaned, polishError: nil)
      })
  }

  /// Yields until the condition holds. No clock: the run is a real `Task` and its terminal is
  /// a STATE, so cooperative yielding is what advances it. Same shape and same limit as
  /// `FileImportCoordinatorTests.settleUntil`.
  @discardableResult
  private func settleUntil(limit: Int = 500, _ condition: @MainActor () -> Bool) async -> Bool {
    for _ in 0..<limit {
      if condition() { return true }
      await Task.yield()
    }
    return condition()
  }

  private func run(_ c: FileImportCoordinator) async {
    c.choose(url: Self.anyURL)
    await settleUntil { if case .ready = c.state { return true } else { return false } }
    c.start()
    await settleUntil { c.state == .finished }
  }

  /// The whole finding, in one row.
  @Test("a finished import is in History, named by the file it came from")
  func afinishedImportReachesHistory() async {
    let spy = HistorySpy()
    let c = Self.coordinator(spy: spy)
    await run(c)

    #expect(!spy.writes.isEmpty, "nothing was written to History")
    #expect(spy.writes.last?.importedFileName == "marketing-sync.m4a")
    #expect(spy.writes.last?.isImported == true)
    #expect(c.isSavedToHistory)
  }

  /// **The ordering IS the feature.** The raw words must be durable before the slow half
  /// starts, because by then the audio has been released and there is nothing left to redo
  /// the transcription from.
  @Test("the raw words are written BEFORE any cleaning happens")
  func rawWordsAreWrittenFirst() async {
    let spy = HistorySpy()
    // **Asked from INSIDE the cleaning**, not from the finished list. Reading the order
    // afterwards cannot tell a write that preceded the cleaning from one that merely
    // appeared earlier in the array, so the first version of this row would have passed
    // against a re-polish that saved nothing until the very end. Found by Codex.
    var rawWasDurableWhenCleaningStarted: Bool?
    let c = Self.coordinator(
      spy: spy,
      onPart: {
        if rawWasDurableWhenCleaningStarted == nil {
          rawWasDurableWhenCleaningStarted = spy.writes.contains {
            $0.text == "um one two three" && $0.polishedText == nil
          }
        }
      })
    await run(c)

    #expect(
      rawWasDurableWhenCleaningStarted == true,
      "cleaning began before the raw words were saved")
    #expect(spy.writes.count >= 2, "expected a raw write and a finished write")
    #expect(spy.writes.first?.text == "um one two three", "the first write is not the raw words")
    #expect(spy.writes.first?.polishedText == nil)
  }

  /// The same question about a RE-POLISH, which reaches the cleaning by a different door.
  /// A document whose first write was refused could otherwise lose everything to a second
  /// interrupted cleanup. Found by Codex.
  @Test("a re-polish also saves the raw words before cleaning")
  func arePolishSavesRawBeforeCleaning() async {
    let spy = HistorySpy()
    spy.refuse = true
    var rawWasDurableWhenCleaningStarted: Bool?
    let c = Self.coordinator(
      spy: spy,
      onPart: {
        if rawWasDurableWhenCleaningStarted == nil {
          rawWasDurableWhenCleaningStarted = spy.writes.contains { $0.polishedText == nil }
        }
      })
    await run(c)
    #expect(spy.writes.isEmpty)

    spy.refuse = false
    c.rePolish()
    await settleUntil { spy.writes.count >= 2 }

    #expect(
      rawWasDurableWhenCleaningStarted == true,
      "the re-polish began cleaning before the raw words were saved")
  }

  /// One recording, one row. The store names its file by id, so two ids would be two rows for
  /// one import and History would show the recording twice.
  @Test("both writes share one identity, so History holds one row")
  func bothWritesShareOneIdentity() async {
    let spy = HistorySpy()
    let c = Self.coordinator(spy: spy)
    await run(c)

    let ids = Set(spy.writes.map(\.id))
    #expect(ids.count == 1, "expected one History identity, found \(ids.count)")
    #expect(c.historyID == ids.first)
  }

  /// The promise the page makes on the screen that says "Original kept".
  @Test("the finished write never overwrites the original words")
  func theOriginalSurvivesTheUpdate() async {
    let spy = HistorySpy()
    let c = Self.coordinator(spy: spy)
    await run(c)

    #expect(
      spy.writes.last?.text == "um one two three",
      "the original words were replaced by the cleaned ones")
    #expect(spy.writes.last?.polishedText == "One two three.")
  }

  /// The approved plan's failure table, and the direction matters: cleaning into a document
  /// nobody can save is how a user loses words while watching a progress bar.
  @Test("a refused first write stops the run before any cleaning")
  func arefusedFirstWriteStopsTheRun() async {
    let spy = HistorySpy()
    spy.refuse = true
    let c = Self.coordinator(spy: spy)
    await run(c)

    #expect(spy.writes.isEmpty, "a write succeeded after the store refused")
    #expect(spy.refusals == 1, "the run retried a write it was told to stop on")
    #expect(c.parts.isEmpty, "the run cleaned parts after failing to save the words")
    #expect(!c.isSavedToHistory, "the screen would claim a save that did not happen")
    #expect(c.hasDocument, "the raw words must still be on screen to copy")
  }

  /// A re-polish of a document whose first write was refused has no row to update, so it must
  /// write one. Without this the cleaned words would have nowhere to land and the retry would
  /// look identical to the original failure.
  @Test("a re-polish with no saved row writes the raw words first")
  func arePolishWithoutARowWritesOneFirst() async {
    let spy = HistorySpy()
    spy.refuse = true
    let c = Self.coordinator(spy: spy)
    await run(c)
    #expect(spy.writes.isEmpty)

    spy.refuse = false
    c.rePolish()
    await settleUntil { spy.writes.count >= 2 }

    #expect(spy.writes.count >= 2, "the retry did not write the raw words before the cleaned ones")
    #expect(spy.writes.first?.polishedText == nil)
    #expect(c.isSavedToHistory)
  }

  /// Stopping after one cleaned part leaves a document that matches neither write. The badge
  /// claimed "Saved to History" over it, because both writes had reported success. Found by
  /// Codex.
  ///
  /// **Every assertion runs unconditionally.** The first version wrapped them in an `if` that
  /// checked the very situation it was meant to prove, so a run that never produced a partial
  /// document passed without testing anything. Codex named that; the input is now long enough
  /// to split into several parts and the Stop is fired from inside the second one, so the
  /// state is STAGED rather than hoped for.
  @Test("a part-cleaned document is not reported as saved")
  func apartialDocumentIsNotReportedAsSaved() async {
    let spy = HistorySpy()
    let raw = Array(repeating: "one two three four five.", count: 300).joined(separator: " ")

    var calls = 0
    var c: FileImportCoordinator!
    c = Self.coordinator(
      spy: spy, raw: raw,
      onPart: {
        calls += 1
        if calls == 2 { c.stop() }
      })

    c.choose(url: Self.anyURL)
    #expect(await settleUntil { if case .ready = c.state { return true } else { return false } })
    c.start()
    #expect(await settleUntil { c.state == .stopped })

    #expect(c.parts.count == 1, "the Stop did not land after exactly one cleaned part")
    #expect(spy.writes.count == 1, "only the raw write should have happened")
    #expect(c.documentText != spy.writes.last?.displayText)
    #expect(!c.isSavedToHistory, "the badge claimed a save for words that were not saved")
    #expect(c.historySaveNotice != nil, "the user was told nothing about the mismatch")
  }

  /// Two writes, one recording, one moment in time. Rebuilding the row per write took
  /// `Date()` each time, so the two disagreed about when the recording happened. Found by
  /// Codex.
  @Test("both writes describe the same recording, not the moment of the write")
  func bothWritesDescribeTheSameRecording() async {
    let spy = HistorySpy()
    let c = Self.coordinator(spy: spy)
    await run(c)

    #expect(spy.writes.count >= 2)
    #expect(
      spy.writes.first?.createdAt == spy.writes.last?.createdAt,
      "the two writes disagree about when the recording happened")
    #expect(spy.writes.first?.backendType == spy.writes.last?.backendType)
    #expect(spy.writes.first?.importedFileName == spy.writes.last?.importedFileName)
  }

  /// **A row must not claim an AI polish that did not happen.** Same defect as the Done
  /// header's credit, in the persisted copy: six readers treat a non-nil `polishedText` as
  /// evidence a polisher ran, from the History badge to the polish-success metric. Found by
  /// the cloud review of PR #2786.
  @Test("a document with no successful polish carries no AI evidence")
  func nopolishMeansNoAIEvidence() async {
    let spy = HistorySpy()
    let c = FileImportCoordinator(
      decode: { _ in Self.decoded() },
      transcribe: { _ in (text: "um one two three", language: "en") },
      engineAdmission: .live(lease: EngineLease(), as: .fileImport),
      beginRun: {
        FileImportCoordinator.RunConfiguration(
          polishIsCloud: false, localPolishProvider: nil, polishProvider: .egOne,
          ollamaModel: nil, polishModel: "eg-1", backendType: .parakeet)
      },
      saveToHistory: { try spy.save($0) },
      // Every part comes back with NO polished text, which is what a bypassed or entirely
      // failed polish produces.
      processPart: { part, _ in
        FileImportRunner.PartOutcome(text: part, polishedText: nil, polishError: "unavailable")
      })
    await run(c)

    let final = spy.writes.last
    #expect(final != nil)
    #expect(final?.polishedText == nil, "the row claims an AI polish that never ran")
    #expect(final?.llmProvider == nil, "the row credits an engine that did nothing")
    #expect(final?.llmModel == nil)
    // The derived document still survives: numbers, dates and saved words are real work.
    #expect(final?.processedText != nil, "the derived document was thrown away")
    #expect(final?.text == "um one two three", "the original words changed")
  }

  /// The other direction, so a rule that stripped evidence from every row would fail here.
  @Test("a successful polish still carries its provenance")
  func asuccessfulPolishKeepsItsProvenance() async {
    let spy = HistorySpy()
    let c = Self.coordinator(spy: spy)
    await run(c)

    #expect(spy.writes.last?.polishedText == "One two three.")
    #expect(spy.writes.last?.llmProvider == "egOne")
    #expect(spy.writes.last?.llmModel == "eg-1")
  }

  /// A different file is a different recording. Carrying the id forward would make the next
  /// import overwrite the last one's words, because the store keys on id.
  @Test("starting over takes a new identity")
  func startingOverTakesANewIdentity() async {
    let spy = HistorySpy()
    let c = Self.coordinator(spy: spy)
    await run(c)
    let first = c.historyID
    #expect(first != nil)

    c.startOver()
    #expect(c.historyID == nil, "the finished import's identity survived Start Over")

    await run(c)
    #expect(c.historyID != nil)
    #expect(c.historyID != first, "the second import would overwrite the first one's row")
  }
}
