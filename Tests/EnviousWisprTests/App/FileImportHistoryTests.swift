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
      // A save puts the row in History, whatever happened to it before.
      rowWasDeleted = false
    }

    /// Whether the user removed this import from History. The real coordinator answers by
    /// looking for the row and finding nothing, which is what `exists` stands for.
    var rowWasDeleted = false

    func exists(_ id: UUID) -> Bool { !rowWasDeleted }

    /// The cleaned write, which may only ever update. Returning false is a deletion, not a
    /// failure, so it records neither a write nor a refusal.
    func update(_ transcript: Transcript) throws -> Bool {
      if refuse {
        refusals += 1
        throw Refused()
      }
      guard !rowWasDeleted else { return false }
      writes.append(transcript)
      return true
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
    polisherStarts: Bool = true,
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
      prepareLocalPolish: { _ in polisherStarts },
      saveToHistory: { try spy.save($0) },
      updateHistoryRow: { try spy.update($0) },
      historyRowExists: { spy.exists($0) },
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

  /// A deletion the user made while the cleanup ran must stand.
  ///
  /// The two writes are minutes apart and History is reachable the whole time, so this is an
  /// ordinary thing to do: start a long import, go and tidy History, remove the row. The
  /// cleaned write then found no row, PUT ONE BACK, and rewrote its file. Found by the cloud
  /// review of PR #2786.
  ///
  /// The control is in the same test, because a rule that simply stopped writing would pass
  /// the first half and fail the second.
  @Test("an import deleted from History while it was cleaning does not come back")
  func adeletedImportStaysDeleted() async {
    let spy = HistorySpy()
    let c = Self.coordinator(spy: spy, onPart: { spy.rowWasDeleted = true })
    await run(c)

    #expect(spy.writes.count == 1, "the cleaned write recreated a row the user deleted")
    #expect(spy.writes.last?.polishedText == nil, "the row put back carries the cleaned text")
    #expect(c.historyRowWasDeleted)
    #expect(!c.isSavedToHistory)
    #expect(c.historySaveFailure == nil, "a deletion is not a failure and offers no retry")
    // The words are still on screen, which is what makes the deletion safe to respect.
    #expect(!c.documentText.isEmpty)
    #expect(c.historySaveNotice?.contains("You deleted this from History") == true)

    // A deletion AFTER the run is the same fact, asked live: the badge must not keep
    // reporting a write that once succeeded.
    let late = HistorySpy()
    let lateRun = Self.coordinator(spy: late)
    await run(lateRun)
    #expect(lateRun.isSavedToHistory)
    late.rowWasDeleted = true
    #expect(!lateRun.isSavedToHistory)
    #expect(lateRun.historyRowWasDeleted)

    // The control: the same run with nothing deleted writes twice and says it saved.
    let kept = HistorySpy()
    let keptRun = Self.coordinator(spy: kept)
    await run(keptRun)
    #expect(kept.writes.count == 2)
    #expect(!keptRun.historyRowWasDeleted)
    #expect(keptRun.isSavedToHistory)
  }

  /// After a deletion, Clean it again is a fresh request for this document and writes the
  /// row anew, so the notice must stop saying it is gone. Found by Codex: the raw re-save
  /// left the deletion fact standing.
  @Test("cleaning again after a deletion writes the row back and drops the deletion notice")
  func cleaningAgainAfterADeletionWritesTheRowBack() async {
    let spy = HistorySpy()
    // Deleted during the FIRST cleanup only: the hook fires again on the re-clean, when the
    // raw row has been written twice, and must not stage a second deletion there.
    let c = Self.coordinator(
      spy: spy, onPart: { if spy.writes.count == 1 { spy.rowWasDeleted = true } })
    await run(c)
    #expect(c.historyRowWasDeleted)

    // The user restores the row by asking for the work again; the raw re-save recreates it.
    c.rePolish()
    await settleUntil { c.state == .finished }

    #expect(!c.historyRowWasDeleted, "the notice still says the row is gone")
    #expect(spy.writes.count == 3, "raw, then raw again, then cleaned")
    #expect(c.isSavedToHistory)
    #expect(c.historySaveNotice == nil)
  }

  /// The saved badge answers about the words ON SCREEN (#2772).
  ///
  /// Staged with the raw write landed and the cleaned write refused, which leaves History
  /// holding the raw words under a document with cleaned parts. That is what a Stop after one
  /// part looks like too. With Show original words pressed the screen and Copy both carry
  /// the raw transcript, which IS saved, and the badge used to compare the cleaned document
  /// and say it was not. Found by the cloud review of PR #2786.
  @Test("with the original words showing, the badge reports whether THOSE are saved")
  func theBadgeFollowsTheToggle() async {
    let spy = HistorySpy()
    // The raw write has already landed when the first part runs; refusing from here on
    // leaves the cleaned write unsaved.
    let c = Self.coordinator(spy: spy, onPart: { spy.refuse = true })
    await run(c)
    #expect(spy.writes.count == 1)
    #expect(!c.parts.isEmpty, "the staging needs a cleaned part on screen")

    #expect(!c.isSavedToHistory, "the cleaned document was refused and still reads as saved")
    #expect(c.exportText == "One two three.")

    c.documentView = .original
    #expect(c.isSavedToHistory, "the raw words are on screen and in History")
    #expect(c.exportText == "um one two three")
    #expect(c.historySaveNotice == nil)

    c.documentView = .cleaned
    #expect(!c.isSavedToHistory)
  }

  /// A deletion followed by Stop never reaches the cleaned write, so a flag set there
  /// missed it and the badge said "Saved to History" over a row that was gone. Found by the
  /// cloud review of PR #2786. The badge now asks History itself.
  @Test("a row deleted and then stopped before cleanup finishes is not reported saved")
  func aDeletedThenStoppedImportIsNotReportedSaved() async {
    let spy = HistorySpy()
    let box = CoordinatorBox()
    let c = Self.coordinator(
      spy: spy,
      onPart: {
        spy.rowWasDeleted = true
        box.coordinator?.stop()
      })
    box.coordinator = c
    c.choose(url: Self.anyURL)
    await settleUntil { if case .ready = c.state { return true } else { return false } }
    c.start()
    await settleUntil { c.state == .stopped }

    #expect(spy.writes.count == 1)
    #expect(!c.isSavedToHistory, "the badge reports a row the user deleted")
    #expect(c.historyRowWasDeleted)
    #expect(c.historySaveNotice?.contains("You deleted this from History") == true)
    // With the original words showing, the answer is the same: those are gone too.
    c.documentView = .original
    #expect(!c.isSavedToHistory)
  }

  /// The Continue gate admits an installed bundled engine whatever its server is doing and
  /// leaves health to the run. The run then discarded the answer, so an engine that failed
  /// to start produced a whole document of raw words with no refusal anywhere. Found by the
  /// cloud review of PR #2786.
  @Test("a bundled polisher that does not start refuses the cleanup, after the words are safe")
  func aPolisherThatDoesNotStartRefusesTheCleanup() async {
    let spy = HistorySpy()
    let c = Self.coordinator(spy: spy, polisherStarts: false)
    c.choose(url: Self.anyURL)
    await settleUntil { if case .ready = c.state { return true } else { return false } }
    c.start()
    await settleUntil { if case .rejected = c.state { return true } else { return false } }

    #expect(c.state == .rejected(.polisherNotReady))
    #expect(c.step == .done, "the refusal renders beside the words, not on Upload")
    #expect(spy.writes.count == 1, "the raw words were not made durable before the refusal")
    #expect(c.parts.isEmpty, "the cleanup ran against an engine that never started")
    #expect(c.hasDocument)
    #expect(c.isSavedToHistory)
    #expect(!c.canRetry, "Try again would re-transcribe; only the cleanup needs redoing")
  }

  /// Lets a hook fired from inside the run reach the coordinator that owns it.
  @MainActor
  private final class CoordinatorBox {
    var coordinator: FileImportCoordinator?
  }

  /// The marked-up view (#2773) exports the CLEANED text, because marks have no plain-text
  /// form, and reports the cleanup's counts from the two texts the run holds.
  @Test("the marked-up view exports cleaned words and counts what the cleanup did")
  func theMarkedUpViewExportsCleanedAndCounts() async {
    let spy = HistorySpy()
    let c = Self.coordinator(spy: spy)
    await run(c)
    c.documentView = .markedUp
    #expect(!c.screenShowsRawWords)
    #expect(c.exportText == "One two three.")
    #expect(c.isSavedToHistory, "the cleaned document is what is saved and what exports")
    // Nothing until the comparison has been made off the main actor.
    #expect(c.markedUp == nil)
    await c.prepareMarkedUp()
    // "um one two three" → "One two three.": one word removed, nothing changed.
    #expect(c.markedUp?.removedWords == 1)
    #expect(c.markedUp?.changedWords == 0)
    #expect(c.markedUp?.segments.map(\.kind) == [.removed, .same, .same, .same])
    // A new file starts on Cleaned again, with no comparison carried over.
    c.startOver()
    #expect(c.documentView == .cleaned)
    #expect(c.markedUp == nil)
  }

  /// After a Stop, the passages the cleanup never reached are not "removed" (#2773). The
  /// comparison runs against the finished parts plus the untouched tail. Found by Codex; the
  /// first version of this test stopped from the FIRST part, which lands nothing, and
  /// guarded itself out. It now stops during the second, so one part is finished and at
  /// least one piece is still waiting.
  @Test("a stopped import compares against the untouched tail, not against nothing")
  func aStoppedImportDoesNotMarkTheTailRemoved() async throws {
    let spy = HistorySpy()
    let box = CoordinatorBox()
    let raw = Array(repeating: "alpha", count: 600).joined(separator: " ") + " four five six"
    let calls = CallCounter()
    let c = Self.coordinator(
      spy: spy, raw: raw, cleaned: "Alpha.",
      onPart: {
        calls.count += 1
        if calls.count == 2 { box.coordinator?.stop() }
      })
    box.coordinator = c
    c.choose(url: Self.anyURL)
    #expect(await settleUntil { if case .ready = c.state { return true } else { return false } })
    c.start()
    #expect(await settleUntil { c.state == .stopped })
    try #require(c.parts.count == 1)
    try #require(c.pendingPieces.count > 1)

    c.documentView = .markedUp
    await c.prepareMarkedUp()
    let result = try #require(c.markedUp)
    // EVERY word of every waiting passage is untouched, not only the distinctive one: the
    // first passage's alphas may be removed, the waiting passages' alphas may not.
    let firstPassageWords = c.pendingPieces[0].split(whereSeparator: \.isWhitespace).count
    #expect(result.removedWords == firstPassageWords - 1, "\(result.removedWords) removed")
    #expect(result.changedWords == 0)
    let waitingWords = c.pendingPieces.dropFirst().joined(separator: " ")
      .split(whereSeparator: \.isWhitespace).count
    #expect(result.segments.suffix(waitingWords).allSatisfy { $0.kind == .same })
    let tail = try #require(result.segments.first { $0.text == "four" })
    #expect(tail.kind == .same, "an unfinished passage was marked \(tail.kind)")
    // And the rendering rebuilds the transcript byte for byte across the passage cuts: the
    // splitter drops the whitespace between its pieces, and a version that concatenated them
    // rendered "alphaalpha" at every boundary. Codex, confirming round.
    #expect(result.segments.map { $0.text + $0.trailing }.joined() == raw)
  }

  @MainActor
  private final class CallCounter {
    var count = 0
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
      updateHistoryRow: { try spy.update($0) },
      historyRowExists: { spy.exists($0) },
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
