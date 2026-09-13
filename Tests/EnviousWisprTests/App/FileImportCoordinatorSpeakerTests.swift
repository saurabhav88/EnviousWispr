import EnviousWisprASR
import EnviousWisprCore
import EnviousWisprPipeline
import EnviousWisprServices
import Foundation
import Testing

@testable import EnviousWisprAppKit

/// #2809 — the dormant, phase-2 speaker step wired into the file-import coordinator.
///
/// **When this fails, every successful import waits on this invisible step before its
/// words can be cleaned up, or a stopped speaker worker keeps running in the background
/// after the user has moved on, or a refused raw save still runs an analysis on words
/// nobody kept, or the speaker step silently analyzes an empty buffer because the
/// coordinator's own array was already released.** Product coverage.
@Suite(.tags(.productOutcome))
@MainActor
struct FileImportCoordinatorSpeakerTests {

  /// A one-shot "entered" signal plus a manual release, so a test can prove a fake speaker
  /// step is actually RUNNING (not skipped) before acting on it.
  private actor Gate {
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
    private var entered = false

    func markEntered() {
      entered = true
      for waiter in enteredWaiters { waiter.resume() }
      enteredWaiters = []
    }

    func waitUntilEntered() async {
      if entered { return }
      await withCheckedContinuation { enteredWaiters.append($0) }
    }
  }

  /// A gate a test controls from outside: a call can wait to be told to proceed, and the
  /// test can wait to know a call has arrived. Used to prove ORDERING between the speaker
  /// step and the document cleanup (#2851: either may land first).
  private actor ManualGate {
    private var openWaiters: [CheckedContinuation<Void, Never>] = []
    private var isOpen = false
    private var arrivalWaiters: [CheckedContinuation<Void, Never>] = []
    private var hasArrived = false

    func markArrived() {
      hasArrived = true
      for waiter in arrivalWaiters { waiter.resume() }
      arrivalWaiters = []
    }

    func waitUntilArrived() async {
      if hasArrived { return }
      await withCheckedContinuation { arrivalWaiters.append($0) }
    }

    func arrivedSoFar() -> Bool { hasArrived }

    func open() {
      isOpen = true
      for waiter in openWaiters { waiter.resume() }
      openWaiters = []
    }

    func waitUntilOpen() async {
      if isOpen { return }
      await withCheckedContinuation { openWaiters.append($0) }
    }
  }

  private actor CallRecorder {
    private(set) var callCount = 0
    private(set) var lastSampleCount: Int?
    private(set) var lastDurationSeconds: TimeInterval?

    func record(sampleCount: Int, durationSeconds: TimeInterval) {
      callCount += 1
      lastSampleCount = sampleCount
      lastDurationSeconds = durationSeconds
    }
  }

  nonisolated private static func decoded(seconds: Double) -> AudioFileDecoder.Decoded {
    AudioFileDecoder.Decoded(
      samples: Array(repeating: 0.1, count: Int(seconds * 16_000)),
      seconds: seconds, byteCount: Int64(seconds * 32_000), codec: "AAC",
      sampleRate: 44_100, channelCount: 1)
  }

  private static let anyURL = URL(fileURLWithPath: "/tmp/recording.m4a")

  /// #2854: a deadline-bounded wait on the condition, never a yield count.
  /// Owner: `FileImportSettle.swift`.
  private func settleUntil(_ condition: @MainActor () async -> Bool) async -> Bool {
    await settleUntilObserved(condition)
  }

  private func makeCoordinator(
    lease: EngineLease,
    seconds: Double = 1.0,
    transcribedText: String = "one two three",
    wordTimings: [ASRWordTiming]? = nil,
    wordTimingCoverage: ASRWordTimingCoverage? = nil,
    speakerLabeler: @escaping @MainActor ([Float], TimeInterval) async -> SpeakerAnalysis,
    saveToHistory: @escaping @MainActor (Transcript) throws -> Void = { _ in },
    updateHistoryRow: @escaping @MainActor (Transcript) throws -> Bool = { _ in true },
    mergeSpeakerFields: @escaping @MainActor (UUID, TranscriptSpeakerAnalysis, [Turn]?) throws ->
      Bool = { _, _, _ in true },
    writeExplicitRename: @escaping @MainActor (
      UUID, TranscriptSpeakerAnalysis, [Turn]?, (speakerId: String, name: String)
    ) throws -> Bool = { _, _, _, _ in false },
    currentHistoryRow: @escaping @MainActor (UUID) -> Transcript? = { _ in nil },
    emitSpeakerTelemetry: @escaping @MainActor (
      SpeakerAnalysis, TimeInterval, Int, ASRWordTimingCoverage?
    ) -> Void = { _, _, _, _ in },
    emitTurnTelemetry: @escaping @MainActor (
      TelemetryService.FileImportTurnsOutcome, Int?, Int
    ) -> Void = { _, _, _ in },
    emitRenameTelemetry: @escaping @MainActor (TelemetryService.FileImportRenameOutcome) -> Void = {
      _ in
    },
    emitSpeakerRetryTelemetry: @escaping @MainActor (
      TelemetryService.FileImportSpeakerRetryOutcome
    ) -> Void = { _ in },
    emitTurnsDisplayedTelemetry: @escaping @MainActor () -> Void = {},
    prepareLocalPolish: @escaping @MainActor (FileImportCoordinator.RunConfiguration) async ->
      Bool = { _ in true },
    processPart: @escaping @MainActor (String, String?) async throws ->
      FileImportRunner
      .PartOutcome = { part, _ in
        FileImportRunner.PartOutcome(text: part, polishedText: part, polishError: nil)
      }
  ) -> FileImportCoordinator {
    FileImportCoordinator(
      decode: { _ in Self.decoded(seconds: seconds) },
      transcribe: { _ in
        ASRResult(
          text: transcribedText, language: "en", duration: 0, processingTime: 0,
          backendType: .parakeet, wordTimings: wordTimings, wordTimingCoverage: wordTimingCoverage)
      },
      speakerLabeler: speakerLabeler,
      emitSpeakerTelemetry: emitSpeakerTelemetry,
      emitTurnTelemetry: emitTurnTelemetry,
      emitRenameTelemetry: emitRenameTelemetry,
      emitSpeakerRetryTelemetry: emitSpeakerRetryTelemetry,
      emitTurnsDisplayedTelemetry: emitTurnsDisplayedTelemetry,
      engineAdmission: .live(lease: lease, as: .fileImport),
      beginRun: {
        FileImportCoordinator.RunConfiguration(
          polishIsCloud: false, localPolishProvider: nil, polishProvider: .egOne,
          ollamaModel: nil, polishModel: "eg-1", backendType: .parakeet)
      },
      prepareLocalPolish: prepareLocalPolish,
      saveToHistory: saveToHistory,
      updateHistoryRow: updateHistoryRow,
      mergeSpeakerFields: mergeSpeakerFields,
      writeExplicitRename: writeExplicitRename,
      currentHistoryRow: currentHistoryRow,
      historyRowExists: { _ in true },
      processPart: processPart)
  }

  @Test("the speaker step never runs when the raw save is refused, and neither does cleanup/polish")
  func speakerStepNeverRunsWhenRawSaveRefused() async {
    let recorder = CallRecorder()
    let cleanupRecorder = CallRecorder()
    struct SaveError: Error {}
    let coordinator = makeCoordinator(
      lease: EngineLease(),
      speakerLabeler: { samples, duration in
        await recorder.record(sampleCount: samples.count, durationSeconds: duration)
        return .single(segments: [])
      },
      saveToHistory: { _ in throw SaveError() },
      processPart: { part, _ in
        await cleanupRecorder.record(sampleCount: 0, durationSeconds: 0)
        return FileImportRunner.PartOutcome(text: part, polishedText: part, polishError: nil)
      })

    coordinator.choose(url: Self.anyURL)
    _ = await settleUntil {
      if case .ready = coordinator.state { return true } else { return false }
    }
    coordinator.start()
    _ = await settleUntil { coordinator.step == .done }

    #expect(
      await recorder.callCount == 0, "the speaker step ran despite the raw save being refused")
    #expect(
      await cleanupRecorder.callCount == 0,
      "cleanup/polish ran despite the raw save being refused")
    #expect(coordinator.historySaveFailure != nil)
    #expect(coordinator.speakerAnalysis == nil)
  }

  @Test("the speaker step analyzes the real captured buffer, not an emptied one")
  func speakerStepReceivesTheRealBuffer() async {
    let recorder = CallRecorder()
    let coordinator = makeCoordinator(
      lease: EngineLease(), seconds: 2.0,
      speakerLabeler: { samples, duration in
        await recorder.record(sampleCount: samples.count, durationSeconds: duration)
        return .single(segments: [])
      })

    coordinator.choose(url: Self.anyURL)
    _ = await settleUntil {
      if case .ready = coordinator.state { return true } else { return false }
    }
    coordinator.start()
    _ = await settleUntil { coordinator.state == .finished }
    // The speaker step runs detached from polish (#2809, cloud review) — `.finished`
    // means polish is done, not that this ALSO fast-but-still-concurrent step has
    // run yet. Wait on the step's own completion signal, not the run's.
    _ = await settleUntil { await recorder.callCount == 1 }

    #expect(await recorder.callCount == 1)
    // 2.0s at 16kHz = 32,000 samples. Zero would mean the coordinator's OWN
    // `decodedSamples` (already cleared by `releaseDecodedAudio()`) was passed instead of
    // the run's own captured array.
    #expect(await recorder.lastSampleCount == 32_000)
    #expect(await recorder.lastDurationSeconds == 2.0)
  }

  @Test("choosing a new file clears the previous file's speaker analysis")
  func choosingANewFileClearsThePreviousSpeakerAnalysis() async {
    let coordinator = makeCoordinator(
      lease: EngineLease(), seconds: 2.0,
      speakerLabeler: { _, _ in .labeled(count: 2, segments: []) })

    coordinator.choose(url: Self.anyURL)
    _ = await settleUntil {
      if case .ready = coordinator.state { return true } else { return false }
    }
    coordinator.start()
    _ = await settleUntil { coordinator.state == .finished }
    // The speaker step runs detached from polish (#2809, cloud review) — `.finished`
    // means polish is done, not that this ALSO fast-but-still-concurrent step has
    // written `speakerAnalysis` yet.
    _ = await settleUntil { coordinator.speakerAnalysis != nil }
    #expect(coordinator.speakerAnalysis == .labeled(count: 2, segments: []))

    // A second file must not read as though the first file's speaker analysis was
    // about it — found by second-pass review.
    coordinator.choose(url: Self.anyURL)
    #expect(coordinator.speakerAnalysis == nil)
  }

  @Test("polish finishes without waiting for the speaker step to finish first")
  func polishDoesNotWaitOnTheSpeakerStep() async {
    let gate = Gate()
    let coordinator = makeCoordinator(
      lease: EngineLease(),
      speakerLabeler: { _, _ in
        await gate.markEntered()
        // Outlives the assertion window below by a wide margin; this test's whole
        // point is that nothing here waits for it.
        try? await Task.sleep(nanoseconds: 30_000_000_000)  // settle: never reached in-window
        return .single(segments: [])
      })

    coordinator.choose(url: Self.anyURL)
    _ = await settleUntil {
      if case .ready = coordinator.state { return true } else { return false }
    }
    coordinator.start()
    await gate.waitUntilEntered()

    // The speaker worker is confirmed in flight (sleeping 30s), and polish still
    // reaches `.finished` almost immediately — the exact defect the cloud review
    // found: awaiting the speaker step inline before polish added its own 20s+
    // deadline to every import's cleanup for a dormant, invisible limb.
    let finished = await settleUntil { coordinator.state == .finished }
    #expect(finished, "polish waited on the speaker step instead of running concurrently")
  }

  @Test("Stop cancels the speaker worker directly, without the engine claim waiting on it")
  func stopCancelsTheSpeakerWorkerWithoutWaitingForIt() async {
    let speakerGate = Gate()
    let polishGate = Gate()
    final class ExitFlag: @unchecked Sendable { var exited = false }
    let speakerExited = ExitFlag()
    let coordinator = makeCoordinator(
      lease: EngineLease(),
      speakerLabeler: { _, _ in
        await speakerGate.markEntered()
        defer { speakerExited.exited = true }
        do {
          try await Task.sleep(nanoseconds: 30_000_000_000)  // settle: cancelled by Stop first
          return .single(segments: [])
        } catch {
          return .failed(.cancelled)
        }
      },
      processPart: { part, _ in
        await polishGate.markEntered()
        // Keeps the MAIN run genuinely in flight so `isEngineHeld` means something
        // real here, independent of the (also in-flight) speaker worker above.
        try await Task.sleep(nanoseconds: 30_000_000_000)  // settle: cancelled by Stop first
        return FileImportRunner.PartOutcome(text: part, polishedText: part, polishError: nil)
      })

    coordinator.choose(url: Self.anyURL)
    _ = await settleUntil {
      if case .ready = coordinator.state { return true } else { return false }
    }
    coordinator.start()
    await speakerGate.waitUntilEntered()
    await polishGate.waitUntilEntered()

    // Both the speaker worker AND the main run are genuinely in flight: the claim
    // must still be held.
    #expect(coordinator.isEngineHeld)

    coordinator.stop()

    let released = await settleUntil { coordinator.isEngineHeld == false }
    #expect(released, "the engine claim was never released after Stop")
    // Detached from the main run (found by cloud review: awaiting the speaker
    // worker inline before polish blocked every successful import's cleanup on
    // this dormant, invisible step) — `stop()` must cancel it directly, or it
    // keeps running for its own deadline after the user has moved on.
    let workerExited = await settleUntil { speakerExited.exited }
    #expect(workerExited, "the speaker worker kept running after Stop")
    // Stop bumped `generation` before the worker unwound, so the outcome is guarded away —
    // exactly like `engineReportedLanguage`/`rawTranscript` elsewhere in this run: nothing
    // is attributed to a run nobody is watching, even though the worker itself did return
    // `.failed(.cancelled)` internally.
    #expect(coordinator.speakerAnalysis == nil)
  }

  @Test("the speaker outcome is passed to telemetry with the file's own duration and coverage")
  func telemetryReceivesTheRealShape() async {
    actor TelemetryCapture {
      private(set) var outcome: SpeakerAnalysis?
      private(set) var durationSeconds: TimeInterval?
      private(set) var analysisMs: Int?
      private(set) var wordTimingCoverage: ASRWordTimingCoverage?
      func record(
        _ outcome: SpeakerAnalysis, _ durationSeconds: TimeInterval, _ analysisMs: Int,
        _ wordTimingCoverage: ASRWordTimingCoverage?
      ) {
        self.outcome = outcome
        self.durationSeconds = durationSeconds
        self.analysisMs = analysisMs
        self.wordTimingCoverage = wordTimingCoverage
      }
    }
    let capture = TelemetryCapture()
    let coverage = ASRWordTimingCoverage(timed: 5, total: 10)
    let segments = [
      SpeakerSegment(speakerId: "0", startMs: 0, endMs: 500, quality: 1),
      SpeakerSegment(speakerId: "1", startMs: 500, endMs: 1000, quality: 1),
    ]
    let coordinator = makeCoordinator(
      lease: EngineLease(), seconds: 3.0, wordTimingCoverage: coverage,
      speakerLabeler: { _, _ in .labeled(count: 2, segments: segments) },
      emitSpeakerTelemetry: { outcome, durationSeconds, analysisMs, wordTimingCoverage in
        Task { await capture.record(outcome, durationSeconds, analysisMs, wordTimingCoverage) }
      })

    coordinator.choose(url: Self.anyURL)
    _ = await settleUntil {
      if case .ready = coordinator.state { return true } else { return false }
    }
    coordinator.start()
    _ = await settleUntil { coordinator.state == .finished }
    _ = await settleUntil { await capture.outcome != nil }

    #expect(await capture.outcome == .labeled(count: 2, segments: segments))
    #expect(await capture.durationSeconds == 3.0)
    #expect(await capture.analysisMs != nil)
    #expect(await capture.wordTimingCoverage == coverage)
  }

  // MARK: - Retry identity digest (#2809 addendum §2.5, no caller in phase 2)

  @Test("the PCM digest is deterministic and distinguishes different audio")
  func pcmDigestIsDeterministicAndDistinguishing() {
    let samplesA: [Float] = [0.1, 0.2, 0.3, 0.4]
    let samplesB: [Float] = [0.1, 0.2, 0.3, 0.5]
    let digestA1 = FileImportCoordinator.pcmDigestHex(samplesA)
    let digestA2 = FileImportCoordinator.pcmDigestHex(samplesA)
    let digestB = FileImportCoordinator.pcmDigestHex(samplesB)

    #expect(digestA1 == digestA2)
    #expect(digestA1 != digestB)
    #expect(digestA1.count == 64, "SHA-256 hex should be 64 characters")
  }

  @Test("an empty buffer still produces a stable digest, not a crash")
  func pcmDigestHandlesEmptyBuffer() {
    #expect(FileImportCoordinator.pcmDigestHex([]) == FileImportCoordinator.pcmDigestHex([]))
  }

  // MARK: - Turn storage (#2810 phase 3)

  private static func twoSpeakerWordTimings() -> [ASRWordTiming] {
    // "hello there friend": "hello" (0..<5) speaker A; "there friend" (6..<18) speaker B.
    [
      ASRWordTiming(word: "hello", range: 0..<5, startMs: 0, endMs: 200),
      ASRWordTiming(word: "there", range: 6..<11, startMs: 5000, endMs: 5200),
      ASRWordTiming(word: "friend", range: 12..<18, startMs: 5200, endMs: 5400),
    ]
  }

  private static let twoSpeakerSegments = [
    SpeakerSegment(speakerId: "A", startMs: 0, endMs: 200, quality: 1),
    SpeakerSegment(speakerId: "B", startMs: 5000, endMs: 5400, quality: 1),
  ]

  @Test("a labeled outcome with real word timings persists turns via mergeSpeakerFields")
  func labeledOutcomeWithWordTimingsPersistsTurns() async {
    @MainActor final class MergeRecorder {
      private(set) var analysis: TranscriptSpeakerAnalysis?
      private(set) var turns: [Turn]?
      func record(_ analysis: TranscriptSpeakerAnalysis, _ turns: [Turn]?) {
        self.analysis = analysis
        self.turns = turns
      }
    }
    let recorder = MergeRecorder()
    let coordinator = makeCoordinator(
      lease: EngineLease(),
      transcribedText: "hello there friend",
      wordTimings: Self.twoSpeakerWordTimings(),
      speakerLabeler: { _, _ in .labeled(count: 2, segments: Self.twoSpeakerSegments) },
      mergeSpeakerFields: { _, analysis, turns in
        recorder.record(analysis, turns)
        return true
      })

    coordinator.choose(url: Self.anyURL)
    _ = await settleUntil {
      if case .ready = coordinator.state { return true } else { return false }
    }
    coordinator.start()
    _ = await settleUntil { coordinator.state == .finished }

    let mergedTurns = await settleUntil { recorder.turns != nil }
    #expect(mergedTurns, "mergeSpeakerFields should have been called with a non-nil turns array")
    #expect(recorder.analysis == .labeled(count: 2))
    let turns = recorder.turns
    #expect(turns?.count == 2)
    #expect(turns?.map(\.speakerId) == ["A", "B"])
  }

  @Test(
    "nil word timings on a labeled outcome merge as a noWordTimings failure, never assembling turns"
  )
  func nilWordTimingsMergeAsFailure() async {
    @MainActor final class MergeRecorder {
      private(set) var analysis: TranscriptSpeakerAnalysis?
      func record(_ analysis: TranscriptSpeakerAnalysis) { self.analysis = analysis }
    }
    let recorder = MergeRecorder()
    let coordinator = makeCoordinator(
      lease: EngineLease(),
      wordTimings: nil,
      speakerLabeler: { _, _ in .labeled(count: 2, segments: Self.twoSpeakerSegments) },
      mergeSpeakerFields: { _, analysis, turns in
        recorder.record(analysis)
        #expect(turns == nil)
        return true
      })

    coordinator.choose(url: Self.anyURL)
    _ = await settleUntil {
      if case .ready = coordinator.state { return true } else { return false }
    }
    coordinator.start()
    _ = await settleUntil { coordinator.state == .finished }

    let recorded = await settleUntil { recorder.analysis != nil }
    #expect(recorded)
    #expect(recorder.analysis == .failed(.noWordTimings))
  }

  @Test(
    "word timings that never bind to any segment (a space-free script) merge as a failure, never a self-contradictory labeled-but-all-unknown row"
  )
  func allUnknownTurnsMergeAsFailureNotContradictoryLabeled() async {
    @MainActor final class MergeRecorder {
      private(set) var analysis: TranscriptSpeakerAnalysis?
      func record(_ analysis: TranscriptSpeakerAnalysis) { self.analysis = analysis }
    }
    let recorder = MergeRecorder()
    let coordinator = makeCoordinator(
      lease: EngineLease(),
      transcribedText: "hello there friend",
      // Mimics exactly what `WordTimingRangeMapper` produces for a space-free script: one
      // untimed entry spanning the whole transcript, since there is no whitespace to
      // tokenize on and no engine word can bind to the single resulting text run.
      wordTimings: [
        ASRWordTiming(word: "hello there friend", range: 0..<19, startMs: nil, endMs: nil)
      ],
      speakerLabeler: { _, _ in .labeled(count: 2, segments: Self.twoSpeakerSegments) },
      mergeSpeakerFields: { _, analysis, turns in
        recorder.record(analysis)
        #expect(
          turns == nil, "a contradictory labeled-with-all-unknown-turns row must never be stored")
        return true
      })

    coordinator.choose(url: Self.anyURL)
    _ = await settleUntil {
      if case .ready = coordinator.state { return true } else { return false }
    }
    coordinator.start()
    _ = await settleUntil { coordinator.state == .finished }

    let recorded = await settleUntil { recorder.analysis != nil }
    #expect(recorded)
    #expect(recorder.analysis == .failed(.noWordTimings))
  }

  @Test(
    "a write failure on the silent (already-reported) path still reports saveFailed, never disappearing"
  )
  func silentPathReportsSaveFailedWhenMergeThrows() async {
    struct WriteError: Error {}
    @MainActor final class TelemetryRecorder {
      private(set) var outcomes: [TelemetryService.FileImportTurnsOutcome] = []
      func record(_ outcome: TelemetryService.FileImportTurnsOutcome) { outcomes.append(outcome) }
    }
    let telemetry = TelemetryRecorder()
    let coordinator = makeCoordinator(
      lease: EngineLease(),
      // A non-.single, non-.labeled outcome: `emitSpeakerTelemetry` already reports it, so
      // `runTurnStorage` passes `outcome: nil` into `mergeAndReport` — the branch found by
      // chunk review round 2 to have silently dropped a write failure.
      speakerLabeler: { _, _ in .failed(.modelsUnavailable) },
      mergeSpeakerFields: { _, _, _ in throw WriteError() },
      emitTurnTelemetry: { outcome, _, _ in telemetry.record(outcome) })

    coordinator.choose(url: Self.anyURL)
    _ = await settleUntil {
      if case .ready = coordinator.state { return true } else { return false }
    }
    coordinator.start()
    _ = await settleUntil { coordinator.state == .finished }

    let reported = await settleUntil { telemetry.outcomes.contains(.saveFailed) }
    #expect(reported, "a thrown merge on the silent path must still report saveFailed")
  }

  @Test(
    "a row deleted before the write on the silent (already-reported) path still reports rowDeleted"
  )
  func silentPathReportsRowDeletedWhenMergeReturnsFalse() async {
    @MainActor final class TelemetryRecorder {
      private(set) var outcomes: [TelemetryService.FileImportTurnsOutcome] = []
      func record(_ outcome: TelemetryService.FileImportTurnsOutcome) { outcomes.append(outcome) }
    }
    let telemetry = TelemetryRecorder()
    let coordinator = makeCoordinator(
      lease: EngineLease(),
      speakerLabeler: { _, _ in .failed(.modelsUnavailable) },
      mergeSpeakerFields: { _, _, _ in false },
      emitTurnTelemetry: { outcome, _, _ in telemetry.record(outcome) })

    coordinator.choose(url: Self.anyURL)
    _ = await settleUntil {
      if case .ready = coordinator.state { return true } else { return false }
    }
    coordinator.start()
    _ = await settleUntil { coordinator.state == .finished }

    let reported = await settleUntil { telemetry.outcomes.contains(.rowDeleted) }
    #expect(reported, "a merge returning false on the silent path must still report rowDeleted")
  }

  @Test(
    "re-polishing (Clean it again) after turn storage has already run preserves the persisted speaker fields, never resetting them to nil"
  )
  func rePolishPreservesAlreadyPersistedSpeakerFields() async {
    @MainActor final class UpdateRecorder {
      private(set) var rows: [Transcript] = []
      func record(_ row: Transcript) { rows.append(row) }
    }
    @MainActor final class TelemetryRecorder {
      private(set) var outcomes: [TelemetryService.FileImportTurnsOutcome] = []
      func record(_ outcome: TelemetryService.FileImportTurnsOutcome) { outcomes.append(outcome) }
    }
    let recorder = UpdateRecorder()
    let telemetry = TelemetryRecorder()
    let store = FakeHistoryStore()
    // Store-backed: since #2851 the stored event is the alignment's, and the alignment
    // reads the live row, so a coordinator with no `currentHistoryRow` never aligns.
    let coordinator = makeCoordinator(
      lease: EngineLease(),
      transcribedText: "hello there friend",
      wordTimings: Self.twoSpeakerWordTimings(),
      speakerLabeler: { _, _ in .labeled(count: 2, segments: Self.twoSpeakerSegments) },
      saveToHistory: { store.save($0) },
      updateHistoryRow: { row in
        recorder.record(row)
        return store.update(row)
      },
      mergeSpeakerFields: { store.mergeSpeakerFields($0, $1, $2) },
      currentHistoryRow: { store.current($0) },
      emitTurnTelemetry: { outcome, _, _ in telemetry.record(outcome) })

    coordinator.choose(url: Self.anyURL)
    _ = await settleUntil {
      if case .ready = coordinator.state { return true } else { return false }
    }
    coordinator.start()
    _ = await settleUntil { coordinator.state == .finished }
    // Wait for the alignment's FINAL commit to REPORT the stored outcome, not just for
    // `isEngineHeld` to read false — that flag starts false too, so checking it right
    // after the visible run finishes can observe "not yet started" and "already finished"
    // as the exact same value (a race this test itself had before this fix).
    let stored = await settleUntil { telemetry.outcomes.contains(.stored) }
    #expect(stored, "the alignment never reported a stored outcome")

    coordinator.rePolish()
    let rePolishFinished = await settleUntil { coordinator.state == .finished }
    #expect(rePolishFinished)

    // The LAST row `rePolish`'s own `savePolishedToHistory` wrote must still carry the
    // speaker fields the background pass persisted earlier. `withImportResult` never
    // touches them — this only holds if `originalHistoryRow` learned about that earlier
    // write, which is exactly what the whole-diff review found missing.
    let lastRow = recorder.rows.last
    #expect(lastRow?.speakerAnalysis != nil, "re-polish reset the speaker analysis back to nil")
    #expect(lastRow?.turns?.isEmpty == false, "re-polish reset the turns back to nil")
  }

  @Test(
    "pressing Clean it again WHILE the background speaker pass is still in flight does not discard that pass's only analysis"
  )
  func rePolishDuringInFlightSpeakerAnalysisStillPersists() async {
    @MainActor final class MergeRecorder {
      private(set) var analyses: [TranscriptSpeakerAnalysis] = []
      func record(_ analysis: TranscriptSpeakerAnalysis) { analyses.append(analysis) }
    }
    let recorder = MergeRecorder()
    let speakerGate = ManualGate()
    let coordinator = makeCoordinator(
      lease: EngineLease(),
      transcribedText: "hello there friend",
      wordTimings: Self.twoSpeakerWordTimings(),
      speakerLabeler: { _, _ in
        // Blocks BEFORE `runSpeakerStep` ever reaches its own document-identity guard — the
        // exact window `rePolish()` can land in (found by cloud review).
        await speakerGate.markArrived()
        await speakerGate.waitUntilOpen()
        return .labeled(count: 2, segments: Self.twoSpeakerSegments)
      },
      mergeSpeakerFields: { _, analysis, _ in
        recorder.record(analysis)
        return true
      })

    coordinator.choose(url: Self.anyURL)
    _ = await settleUntil {
      if case .ready = coordinator.state { return true } else { return false }
    }
    coordinator.start()
    let visibleRunDone = await settleUntil { coordinator.state == .finished }
    #expect(visibleRunDone)
    await speakerGate.waitUntilArrived()

    // "Clean it again" — bumps `generation` for the SAME document WITHOUT cancelling or
    // restarting the still-blocked speaker pass above.
    coordinator.rePolish()
    let rePolishFinished = await settleUntil { coordinator.state == .finished }
    #expect(rePolishFinished, "the re-polish itself must still complete normally")

    // NOW let the original, still-in-flight speaker pass return its outcome.
    await speakerGate.open()
    let persisted = await settleUntil { recorder.analyses.contains(.labeled(count: 2)) }
    #expect(
      persisted,
      "a re-polish of the SAME document must never discard the only speaker analysis this document will ever get"
    )
  }

  // MARK: - Retry, rename, and the savePolishedToHistory race fix (#2811 phase 4 of #2807)

  /// A live, mutable simulation of the History store — closer to `TranscriptCoordinator`'s own
  /// "the in-memory list is the oracle" contract than four independent recorder closures, and
  /// needed here specifically: these tests exist to prove a write reads back what ANOTHER
  /// writer (an external rename) left behind, which four disconnected spies cannot represent.
  @MainActor private final class FakeHistoryStore {
    private(set) var rows: [UUID: Transcript] = [:]
    func save(_ row: Transcript) { rows[row.id] = row }
    func update(_ row: Transcript) -> Bool {
      guard rows[row.id] != nil else { return false }
      rows[row.id] = row
      return true
    }
    func mergeSpeakerFields(_ id: UUID, _ analysis: TranscriptSpeakerAnalysis, _ turns: [Turn]?)
      -> Bool
    {
      guard let existing = rows[id] else { return false }
      rows[id] = existing.mergingSpeakerFields(analysis: analysis, turns: turns)
      return true
    }
    func rename(
      _ id: UUID, _ analysis: TranscriptSpeakerAnalysis, _ turns: [Turn]?,
      _ explicitRename: (speakerId: String, name: String)
    ) -> Bool {
      guard let existing = rows[id] else { return false }
      rows[id] = existing.mergingSpeakerFields(
        analysis: analysis, turns: turns, explicitRename: explicitRename)
      return true
    }
    func current(_ id: UUID) -> Transcript? { rows[id] }
  }

  private func makeStoreBackedCoordinator(
    store: FakeHistoryStore, lease: EngineLease = EngineLease(), seconds: Double = 1.0,
    transcribedText: String = "hello there friend",
    wordTimings: [ASRWordTiming]? = nil,
    speakerLabeler: @escaping @MainActor ([Float], TimeInterval) async -> SpeakerAnalysis,
    processPart: @escaping @MainActor (String, String?) async throws ->
      FileImportRunner.PartOutcome = { part, _ in
        FileImportRunner.PartOutcome(text: part, polishedText: part, polishError: nil)
      },
    emitTurnTelemetry: @escaping @MainActor (
      TelemetryService.FileImportTurnsOutcome, Int?, Int
    ) -> Void = { _, _, _ in },
    emitRenameTelemetry: @escaping @MainActor (TelemetryService.FileImportRenameOutcome) -> Void = {
      _ in
    },
    emitSpeakerRetryTelemetry: @escaping @MainActor (
      TelemetryService.FileImportSpeakerRetryOutcome
    ) -> Void = { _ in },
    emitTurnsDisplayedTelemetry: @escaping @MainActor () -> Void = {}
  ) -> FileImportCoordinator {
    makeCoordinator(
      lease: lease, seconds: seconds, transcribedText: transcribedText,
      wordTimings: wordTimings, speakerLabeler: speakerLabeler,
      saveToHistory: { store.save($0) },
      updateHistoryRow: { store.update($0) },
      mergeSpeakerFields: { store.mergeSpeakerFields($0, $1, $2) },
      writeExplicitRename: { store.rename($0, $1, $2, $3) },
      currentHistoryRow: { store.current($0) },
      emitTurnTelemetry: emitTurnTelemetry, emitRenameTelemetry: emitRenameTelemetry,
      emitSpeakerRetryTelemetry: emitSpeakerRetryTelemetry,
      emitTurnsDisplayedTelemetry: emitTurnsDisplayedTelemetry, processPart: processPart)
  }

  @Test(
    "a re-polish's own write carries forward a rename that landed on the live row after this coordinator's own snapshot was taken"
  )
  func savePolishedToHistoryCarriesLiveSpeakerFieldsForward() async {
    let store = FakeHistoryStore()
    let telemetry = { @MainActor (
      outcome: TelemetryService.FileImportTurnsOutcome, _: Int?, _: Int
    ) in }
    let coordinator = makeStoreBackedCoordinator(
      store: store, wordTimings: Self.twoSpeakerWordTimings(),
      speakerLabeler: { _, _ in .labeled(count: 2, segments: Self.twoSpeakerSegments) },
      emitTurnTelemetry: telemetry)

    coordinator.choose(url: Self.anyURL)
    _ = await settleUntil {
      if case .ready = coordinator.state { return true } else { return false }
    }
    coordinator.start()
    _ = await settleUntil { coordinator.state == .finished }
    guard let historyID = coordinator.historyID else {
      Issue.record("no historyID after the visible run finished")
      return
    }
    // Waits for the background pass's OWN `speakerStepState` to reach `.finished`, not just
    // for its write to land — the write and the telemetry both fire INSIDE `mergeAndReport`,
    // strictly before that pass's own `defer` releases the shared engine claim. Gating only
    // on the write risks `rePolish()`'s own claim being refused as busy a moment later
    // (found while writing this test: `speakerStepState == .finished` is the one signal that
    // is only set AFTER the whole pass, including its engine release, has unwound).
    let stored = await settleUntil {
      store.current(historyID)?.turns != nil && coordinator.speakerStepState == .finished
    }
    #expect(stored, "the background turn-storage pass never finished persisting turns")

    // An EXTERNAL rename — simulating a write from History, or the wizard's own rename UI —
    // landing directly on the live store, entirely bypassing this coordinator. Nothing in
    // this coordinator's own `originalHistoryRow` snapshot learns about it.
    guard let liveRow = store.current(historyID), let analysis = liveRow.speakerAnalysis else {
      Issue.record("no labeled row to rename against")
      return
    }
    let renamed = store.rename(historyID, analysis, liveRow.turns, (speakerId: "A", name: "Zach"))
    #expect(renamed)

    // "Clean it again" — its own `savePolishedToHistory` write must not revert the rename
    // that landed on the live row while this coordinator's own cache was still stale.
    coordinator.rePolish()
    let rePolishFinished = await settleUntil { coordinator.state == .finished }
    #expect(rePolishFinished)

    #expect(
      store.current(historyID)?.speakerNames?["A"] == "Zach",
      "the re-polish's own write reverted a rename it never knew about — savePolishedToHistory must carry the LIVE row's speaker fields forward, not its own stale snapshot"
    )
  }

  /// A cleanup whose output the test can change between runs, so a re-clean is told apart
  /// from the first clean by the text it wrote, never by a call count alone. It swaps whole
  /// words, since the alignment (#2851) places the cleanup's words onto the turns by
  /// position: a tag appended to the part would belong to the last turn alone.
  @MainActor private final class WordSwappingCleaner {
    static let first = ["hello": "hi", "friend": "buddy"]
    static let second = ["hello": "hey", "friend": "pal"]
    var swaps = WordSwappingCleaner.first
    func outcome(_ part: String) -> FileImportRunner.PartOutcome {
      let swapped = part.split(separator: " ").map { swaps[String($0)] ?? String($0) }
      return FileImportRunner.PartOutcome(
        text: part, polishedText: swapped.joined(separator: " "), polishError: nil)
    }
  }

  /// The two-speaker fixture's turns after `WordSwappingCleaner` with the given swaps:
  /// A "hello" and B "there friend" become (A, B).
  private static func swappedTurnTexts(_ swaps: [String: String]) -> (a: String, b: String) {
    (swaps["hello"]!, "there \(swaps["friend"]!)")
  }

  private func turnTexts(_ row: Transcript?) -> [String?] {
    row?.turns?.map(\.processedText) ?? []
  }

  @Test("Clean it again re-aligns the stored turns from the new cleanup and keeps an explicit rename (#2811, #2851)")
  func rePolishRealignsStoredTurnsAndKeepsRename() async {
    let store = FakeHistoryStore()
    let cleaner = WordSwappingCleaner()
    let telemetry = TurnTelemetryRecorder()
    let coordinator = makeStoreBackedCoordinator(
      store: store, wordTimings: Self.twoSpeakerWordTimings(),
      speakerLabeler: { _, _ in .labeled(count: 2, segments: Self.twoSpeakerSegments) },
      processPart: { part, _ in cleaner.outcome(part) },
      emitTurnTelemetry: { telemetry.record($0, $1, $2) })

    coordinator.choose(url: Self.anyURL)
    _ = await settleUntil {
      if case .ready = coordinator.state { return true } else { return false }
    }
    coordinator.start()
    _ = await settleUntil { coordinator.state == .finished }
    guard let historyID = coordinator.historyID else {
      Issue.record("no historyID after the visible run finished")
      return
    }
    let first = Self.swappedTurnTexts(WordSwappingCleaner.first)
    let firstAligned = await settleUntil {
      coordinator.speakerStepState == .finished
        && turnTexts(store.current(historyID)) == [first.a, first.b]
    }
    #expect(firstAligned, "the first cleanup's words never reached the turns: \(turnTexts(store.current(historyID)))")

    guard let liveRow = store.current(historyID), let analysis = liveRow.speakerAnalysis else {
      Issue.record("no labeled row to rename against")
      return
    }
    #expect(store.rename(historyID, analysis, liveRow.turns, (speakerId: "A", name: "Zach")))

    cleaner.swaps = WordSwappingCleaner.second
    coordinator.rePolish()
    _ = await settleUntil { coordinator.state == .finished }
    let second = Self.swappedTurnTexts(WordSwappingCleaner.second)
    let realigned = await settleUntil {
      turnTexts(store.current(historyID)) == [second.a, second.b]
    }
    #expect(realigned, "Clean it again must re-align the stored turns from the new cleanup: \(turnTexts(store.current(historyID)))")
    #expect(store.current(historyID)?.turns?.count == 2, "re-aligning must not change the turn set")
    #expect(store.current(historyID)?.speakerNames?["A"] == "Zach", "a rename must survive a re-clean")
    for _ in 0..<20 { await Task.yield() }
    #expect(telemetry.stored.count == 1, "file_import_turns is once per import; a re-clean is not a new import: \(telemetry.events)")
  }

  @MainActor private final class TurnTelemetryRecorder {
    private(set) var events: [(outcome: TelemetryService.FileImportTurnsOutcome, turnCount: Int?, fallback: Int)] = []
    func record(_ outcome: TelemetryService.FileImportTurnsOutcome, _ turnCount: Int?, _ fallback: Int) {
      events.append((outcome, turnCount, fallback))
    }
    var stored: [(outcome: TelemetryService.FileImportTurnsOutcome, turnCount: Int?, fallback: Int)] {
      events.filter { $0.outcome == .stored }
    }
  }

  @Test("the turns persist raw while the cleanup is still running, then take its words when it lands (#2851)")
  func rawTurnsPersistBeforeTheCleanupFinishesThenAlign() async {
    let store = FakeHistoryStore()
    let cleanupGate = ManualGate()
    let telemetry = TurnTelemetryRecorder()
    let coordinator = makeStoreBackedCoordinator(
      store: store, wordTimings: Self.twoSpeakerWordTimings(),
      speakerLabeler: { _, _ in .labeled(count: 2, segments: Self.twoSpeakerSegments) },
      processPart: { part, _ in
        await cleanupGate.markArrived()
        await cleanupGate.waitUntilOpen()
        return WordSwappingCleaner().outcome(part)
      },
      emitTurnTelemetry: { telemetry.record($0, $1, $2) })

    coordinator.choose(url: Self.anyURL)
    _ = await settleUntil {
      if case .ready = coordinator.state { return true } else { return false }
    }
    coordinator.start()
    await cleanupGate.waitUntilArrived()
    guard let historyID = coordinator.historyID else {
      Issue.record("no historyID once the cleanup is in flight")
      return
    }
    // The speaker step does not wait for the cleanup: the labels land, raw.
    let rawLanded = await settleUntil {
      coordinator.speakerStepState == .finished
        && turnTexts(store.current(historyID)) == [nil, nil]
    }
    #expect(rawLanded, "the turns must persist raw while the cleanup still runs")
    #expect(store.current(historyID)?.turns?.count == 2)
    #expect(telemetry.stored.isEmpty, "the once-per-import event waits for the cleanup")
    #expect(coordinator.state != .finished)

    await cleanupGate.open()
    let finished = await settleUntil { coordinator.state == .finished }
    #expect(finished)
    let first = Self.swappedTurnTexts(WordSwappingCleaner.first)
    #expect(turnTexts(store.current(historyID)) == [first.a, first.b], "Done must follow the final alignment")
    #expect(telemetry.stored.count == 1, "exactly one stored event: \(telemetry.events)")
    #expect(telemetry.stored.first?.turnCount == 2)
    #expect(telemetry.stored.first?.fallback == 0)
  }

  @Test("turns landing after the cleanup already finished align at once and emit the one stored event (#2851)")
  func turnsLandingAfterTheCleanupAlignAtOnceAndEmitOnce() async {
    let store = FakeHistoryStore()
    let speakerGate = ManualGate()
    let telemetry = TurnTelemetryRecorder()
    let coordinator = makeStoreBackedCoordinator(
      store: store, wordTimings: Self.twoSpeakerWordTimings(),
      speakerLabeler: { _, _ in
        await speakerGate.markArrived()
        await speakerGate.waitUntilOpen()
        return .labeled(count: 2, segments: Self.twoSpeakerSegments)
      },
      processPart: { part, _ in WordSwappingCleaner().outcome(part) },
      emitTurnTelemetry: { telemetry.record($0, $1, $2) })

    coordinator.choose(url: Self.anyURL)
    _ = await settleUntil {
      if case .ready = coordinator.state { return true } else { return false }
    }
    coordinator.start()
    let finished = await settleUntil { coordinator.state == .finished }
    #expect(finished, "Done must not wait for the speaker step")
    await speakerGate.waitUntilArrived()
    guard let historyID = coordinator.historyID else {
      Issue.record("no historyID after the visible run finished")
      return
    }
    #expect(store.current(historyID)?.turns == nil)
    #expect(telemetry.stored.isEmpty, "nothing to report before the turns exist")

    await speakerGate.open()
    let first = Self.swappedTurnTexts(WordSwappingCleaner.first)
    let aligned = await settleUntil {
      coordinator.speakerStepState == .finished
        && turnTexts(store.current(historyID)) == [first.a, first.b]
    }
    #expect(aligned, "turns that land after the cleanup take its words at once: \(turnTexts(store.current(historyID)))")
    for _ in 0..<20 { await Task.yield() }
    #expect(telemetry.stored.count == 1, "exactly one stored event: \(telemetry.events)")
    #expect(telemetry.stored.first?.turnCount == 2)
    #expect(telemetry.stored.first?.fallback == 0)
  }

  /// `count` words "w0 w1 ...", one every 100 ms, speaker A for the first `split` words and
  /// B for the rest. 600 words is over `TranscriptSplitter.maximumWordsPerPart`, so the
  /// cleanup runs in two parts.
  private static func manyWordFixture(count: Int, split: Int) -> (
    text: String, timings: [ASRWordTiming], segments: [SpeakerSegment]
  ) {
    var text = ""
    var timings: [ASRWordTiming] = []
    for i in 0..<count {
      let word = "w\(i)"
      if i > 0 { text += " " }
      let start = text.utf16.count
      text += word
      timings.append(
        ASRWordTiming(
          word: word, range: start..<start + word.utf16.count, startMs: i * 100,
          endMs: i * 100 + 80))
    }
    let segments = [
      SpeakerSegment(speakerId: "A", startMs: 0, endMs: split * 100, quality: 1),
      SpeakerSegment(speakerId: "B", startMs: split * 100, endMs: count * 100, quality: 1),
    ]
    return (text, timings, segments)
  }

  @Test("Clean it again keeps a turn's last cleaned text until the new cleanup reaches its passage (#2851)")
  func rePolishKeepsPreviousTextUntilThePassageLandsAgain() async {
    let store = FakeHistoryStore()
    let secondRunGate = ManualGate()
    let fixture = Self.manyWordFixture(count: 600, split: 300)
    @MainActor final class RunTracker {
      var secondRun = false
      private(set) var partsInSecondRun = 0
      func partSeen() -> Int {
        guard secondRun else { return 0 }
        partsInSecondRun += 1
        return partsInSecondRun
      }
    }
    let tracker = RunTracker()
    let coordinator = makeStoreBackedCoordinator(
      store: store, transcribedText: fixture.text, wordTimings: fixture.timings,
      speakerLabeler: { _, _ in .labeled(count: 2, segments: fixture.segments) },
      processPart: { part, _ in
        let index = tracker.partSeen()
        if index == 2 {
          await secondRunGate.markArrived()
          await secondRunGate.waitUntilOpen()
        }
        // The second run rewrites the first word of each part, so its text is told apart.
        let cleaned = index == 0 ? part : "again " + part
        return FileImportRunner.PartOutcome(text: part, polishedText: cleaned, polishError: nil)
      })

    coordinator.choose(url: Self.anyURL)
    _ = await settleUntil {
      if case .ready = coordinator.state { return true } else { return false }
    }
    coordinator.start()
    _ = await settleUntil { coordinator.state == .finished }
    guard let historyID = coordinator.historyID else {
      Issue.record("no historyID after the visible run finished")
      return
    }
    let firstRunAligned = await settleUntil {
      coordinator.speakerStepState == .finished
        && turnTexts(store.current(historyID)).allSatisfy { $0 != nil }
    }
    #expect(firstRunAligned)
    let firstRunTexts = turnTexts(store.current(historyID))

    tracker.secondRun = true
    coordinator.rePolish()
    await secondRunGate.waitUntilArrived()
    // Part 1 of the second run has landed; part 2 is held. Turn A (inside part 1) carries
    // the new words; turn B (spanning both parts) keeps its FIRST run's text, not raw.
    let partOneRelanded = await settleUntil {
      turnTexts(store.current(historyID)).first??.hasPrefix("again ") == true
    }
    #expect(partOneRelanded, "\(turnTexts(store.current(historyID)).map { $0?.prefix(12) })")
    #expect(turnTexts(store.current(historyID)).count == 2)
    #expect(
      turnTexts(store.current(historyID)).last == firstRunTexts.last,
      "an unreached turn keeps its last cleaned text: \(String(describing: turnTexts(store.current(historyID)).last??.prefix(12)))")

    await secondRunGate.open()
    let finished = await settleUntil { coordinator.state == .finished }
    #expect(finished)
    let texts = turnTexts(store.current(historyID))
    #expect(texts.first??.hasPrefix("again w0 ") == true)
    #expect(texts.last??.contains("again w500 ") == true, "part 2's new words reach turn B once it lands")
  }

  @Test("each cleanup part places its words as it lands; a turn the next part still owns stays raw until then (#2851)")
  func eachCleanupPartAlignsItsOwnTurns() async {
    let store = FakeHistoryStore()
    let secondPartGate = ManualGate()
    let fixture = Self.manyWordFixture(count: 600, split: 300)
    @MainActor final class PartCounter {
      private(set) var count = 0
      func next() -> Int {
        count += 1
        return count
      }
    }
    let partsSeen = PartCounter()
    let coordinator = makeStoreBackedCoordinator(
      store: store, transcribedText: fixture.text, wordTimings: fixture.timings,
      speakerLabeler: { _, _ in .labeled(count: 2, segments: fixture.segments) },
      processPart: { part, _ in
        if partsSeen.next() == 2 {
          await secondPartGate.markArrived()
          await secondPartGate.waitUntilOpen()
        }
        return FileImportRunner.PartOutcome(text: part, polishedText: part, polishError: nil)
      })

    coordinator.choose(url: Self.anyURL)
    _ = await settleUntil {
      if case .ready = coordinator.state { return true } else { return false }
    }
    coordinator.start()
    await secondPartGate.waitUntilArrived()
    #expect(coordinator.pendingPieces.count == 2, "the fixture must split into two parts")
    guard let historyID = coordinator.historyID else {
      Issue.record("no historyID once the second part is in flight")
      return
    }
    // Turn A lies inside part 1; turn B spans parts 1 and 2, so it waits for part 2.
    let partOneAligned = await settleUntil {
      coordinator.speakerStepState == .finished
        && turnTexts(store.current(historyID)).map { $0 != nil } == [true, false]
    }
    #expect(partOneAligned, "part 1 must place its words on turn A alone: \(turnTexts(store.current(historyID)).map { $0?.count })")
    #expect(coordinator.state != .finished)

    await secondPartGate.open()
    let finished = await settleUntil { coordinator.state == .finished }
    #expect(finished)
    let texts = turnTexts(store.current(historyID))
    #expect(texts.count == 2)
    #expect(texts[0] == (0..<300).map { "w\($0)" }.joined(separator: " "))
    #expect(texts[1] == (300..<600).map { "w\($0)" }.joined(separator: " "))
  }

  /// Drives one import to `state == .finished` plus a settled speaker step, and returns the
  /// coordinator and its history id; nil (with an issue recorded) if no row landed.
  private func settledImport(
    store: FakeHistoryStore, wordTimings: [ASRWordTiming]?,
    speakerLabeler: @escaping @MainActor ([Float], TimeInterval) async -> SpeakerAnalysis
  ) async -> (FileImportCoordinator, UUID)? {
    let coordinator = makeStoreBackedCoordinator(
      store: store, wordTimings: wordTimings, speakerLabeler: speakerLabeler)
    coordinator.choose(url: Self.anyURL)
    _ = await settleUntil {
      if case .ready = coordinator.state { return true } else { return false }
    }
    coordinator.start()
    _ = await settleUntil { coordinator.state == .finished }
    guard let historyID = coordinator.historyID else {
      Issue.record("no historyID after the visible run finished")
      return nil
    }
    let settled = await settleUntil {
      store.current(historyID)?.speakerAnalysis != nil
        && coordinator.speakerStepState == .finished
    }
    #expect(settled, "the speaker step never settled")
    return (coordinator, historyID)
  }

  @Test("the retained audio is released once the stored outcome is one no retry could change")
  func retryInputsReleasedOnceSettled() async {
    // A labeled success: nothing to retry, audio freed.
    let labeledStore = FakeHistoryStore()
    guard
      let (labeled, _) = await settledImport(
        store: labeledStore, wordTimings: Self.twoSpeakerWordTimings(),
        speakerLabeler: { _, _ in .labeled(count: 2, segments: Self.twoSpeakerSegments) })
    else { return }
    #expect(!labeled.retainsRetryInputs, "a labeled outcome must not pin the audio")
    #expect(!labeled.canRetrySpeakerAnalysis)

    // A real analyzer failure: retry is offered, so the audio stays.
    let failedStore = FakeHistoryStore()
    guard
      let (failed, _) = await settledImport(
        store: failedStore, wordTimings: Self.twoSpeakerWordTimings(),
        speakerLabeler: { _, _ in .failed(.modelsUnavailable) })
    else { return }
    #expect(failed.retainsRetryInputs, "a retryable failure keeps the audio for Try again")
    #expect(failed.canRetrySpeakerAnalysis)
    #expect(failed.speakerNoticeReason == .failed)
  }

  @Test("a deleted History row releases the retry audio, for that row only")
  func deletedRowReleasesRetryInputs() async {
    let store = FakeHistoryStore()
    guard
      let (coordinator, historyID) = await settledImport(
        store: store, wordTimings: Self.twoSpeakerWordTimings(),
        speakerLabeler: { _, _ in .failed(.modelsUnavailable) })
    else { return }
    #expect(coordinator.retainsRetryInputs)

    coordinator.noteHistoryRowDeleted(UUID())
    #expect(coordinator.retainsRetryInputs, "another row's deletion is not this document's")

    coordinator.noteHistoryRowDeleted(historyID)
    #expect(!coordinator.retainsRetryInputs, "a retry has nothing to write against")
    #expect(!coordinator.canRetrySpeakerAnalysis)
  }

  @Test("the Done step's speaker line says Finding speakers, then goes away")
  func speakerStatusLabelNamesTheAnalysisThenClears() async {
    let store = FakeHistoryStore()
    let speakerGate = ManualGate()
    let coordinator = makeStoreBackedCoordinator(
      store: store, wordTimings: Self.twoSpeakerWordTimings(),
      speakerLabeler: { _, _ in
        await speakerGate.markArrived()
        await speakerGate.waitUntilOpen()
        return .labeled(count: 2, segments: Self.twoSpeakerSegments)
      })

    coordinator.choose(url: Self.anyURL)
    _ = await settleUntil {
      if case .ready = coordinator.state { return true } else { return false }
    }
    coordinator.start()
    await speakerGate.waitUntilArrived()
    #expect(coordinator.speakerStatusLabel == "Finding speakers")

    await speakerGate.open()
    let cleared = await settleUntil { coordinator.speakerStepState == .finished }
    #expect(cleared)
    #expect(coordinator.speakerStatusLabel == nil, "nothing to say once the labels are stored")
  }

  @Test("no word timings: the notice shows, Try again does not, and the audio is released")
  func missingTimingsIsNotRetryable() async {
    let store = FakeHistoryStore()
    guard
      let (coordinator, historyID) = await settledImport(
        store: store, wordTimings: nil,
        speakerLabeler: { _, _ in .labeled(count: 2, segments: Self.twoSpeakerSegments) })
    else { return }
    #expect(store.current(historyID)?.speakerAnalysis == .failed(.noWordTimings))
    #expect(coordinator.speakerNoticeReason == .failed, "the user is still told labels failed")
    #expect(
      !coordinator.canRetrySpeakerAnalysis,
      "a retry reruns only the analyzer against the same missing timings; it cannot help")
    #expect(!coordinator.retainsRetryInputs, "nothing a retry could use is worth holding")
    // And pressing it anyway is a no-op, never an empty-buffer analysis.
    coordinator.retrySpeakerAnalysis()
    #expect(coordinator.speakerStepState == .finished)
  }

  @Test("deleting the row while speakers are being found stops that pass and drops the audio")
  func deletedRowDuringSpeakerPassStopsIt() async {
    let store = FakeHistoryStore()
    let speakerGate = ManualGate()
    let coordinator = makeStoreBackedCoordinator(
      store: store, wordTimings: Self.twoSpeakerWordTimings(),
      speakerLabeler: { _, _ in
        await speakerGate.markArrived()
        await speakerGate.waitUntilOpen()
        return .labeled(count: 2, segments: Self.twoSpeakerSegments)
      })
    coordinator.choose(url: Self.anyURL)
    _ = await settleUntil {
      if case .ready = coordinator.state { return true } else { return false }
    }
    coordinator.start()
    await speakerGate.waitUntilArrived()
    guard let historyID = coordinator.historyID else {
      Issue.record("no historyID once the speaker step is in flight")
      return
    }
    #expect(coordinator.retainsRetryInputs)

    coordinator.noteHistoryRowDeleted(historyID)
    #expect(!coordinator.retainsRetryInputs)
    await speakerGate.open()
    for _ in 0..<50 { await Task.yield() }
    #expect(
      store.current(historyID)?.speakerAnalysis != .labeled(count: 2),
      "a cancelled speaker pass must not persist against the deleted row")
  }

  @Test("a retry's turns take the finished cleanup's words at once, and the stored event fires then (#2811, #2851)")
  func retryAlignsItsTurnsFromTheFinishedCleanup() async {
    let store = FakeHistoryStore()
    let cleaner = WordSwappingCleaner()
    let telemetry = TurnTelemetryRecorder()
    @MainActor final class AttemptCounter {
      private(set) var count = 0
      func next() -> Int {
        count += 1
        return count
      }
    }
    let attempts = AttemptCounter()
    let coordinator = makeStoreBackedCoordinator(
      store: store, wordTimings: Self.twoSpeakerWordTimings(),
      speakerLabeler: { _, _ in
        attempts.next() == 1
          ? .failed(.analyzerThrew("boom")) : .labeled(count: 2, segments: Self.twoSpeakerSegments)
      },
      processPart: { part, _ in cleaner.outcome(part) },
      emitTurnTelemetry: { telemetry.record($0, $1, $2) })

    coordinator.choose(url: Self.anyURL)
    _ = await settleUntil {
      if case .ready = coordinator.state { return true } else { return false }
    }
    coordinator.start()
    _ = await settleUntil { coordinator.state == .finished }
    guard let historyID = coordinator.historyID else {
      Issue.record("no historyID after the visible run finished")
      return
    }
    _ = await settleUntil {
      if case .failed = store.current(historyID)?.speakerAnalysis { return true }
      return false
    }
    #expect(telemetry.stored.isEmpty, "a failed analysis stores no turns")
    coordinator.retrySpeakerAnalysis()
    let first = Self.swappedTurnTexts(WordSwappingCleaner.first)
    let retried = await settleUntil {
      store.current(historyID)?.speakerAnalysis == .labeled(count: 2)
        && coordinator.speakerStepState == .finished
        && turnTexts(store.current(historyID)) == [first.a, first.b]
    }
    #expect(retried, "the retry's turns must take the finished cleanup's words with no Clean it again: \(turnTexts(store.current(historyID)))")
    for _ in 0..<20 { await Task.yield() }
    #expect(telemetry.stored.count == 1, "the once-per-import event fires on the retry's alignment: \(telemetry.events)")
    #expect(telemetry.stored.first?.turnCount == 2)
  }

  @Test(
    "the whole import makes exactly one cleanup call per document part; the speaker step makes none (#2851 drift guard)",
    .tags(.driftGuard))
  func cleanupCallsEqualTheDocumentPartsAcrossTheWholeImport() async {
    let store = FakeHistoryStore()
    @MainActor final class CallRecorder {
      private(set) var parts: [String] = []
      func record(_ part: String) { parts.append(part) }
    }
    let calls = CallRecorder()
    // Two 300-word turns over two parts: long enough that a per-turn cleanup restricted to
    // longer turns would show up too (chunk 4 review).
    let fixture = Self.manyWordFixture(count: 600, split: 300)
    let coordinator = makeStoreBackedCoordinator(
      store: store, transcribedText: fixture.text, wordTimings: fixture.timings,
      speakerLabeler: { _, _ in .labeled(count: 2, segments: fixture.segments) },
      processPart: { part, _ in
        calls.record(part)
        return FileImportRunner.PartOutcome(text: part, polishedText: part, polishError: nil)
      })

    coordinator.choose(url: Self.anyURL)
    _ = await settleUntil {
      if case .ready = coordinator.state { return true } else { return false }
    }
    coordinator.start()
    _ = await settleUntil { coordinator.state == .finished }
    guard let historyID = coordinator.historyID else {
      Issue.record("no historyID after the visible run finished")
      return
    }
    let aligned = await settleUntil {
      coordinator.speakerStepState == .finished
        && turnTexts(store.current(historyID)).allSatisfy { $0 != nil }
    }
    #expect(aligned, "the turns must carry the cleanup's words")
    #expect(store.current(historyID)?.turns?.count == 2)
    for _ in 0..<20 { await Task.yield() }
    #expect(coordinator.pendingPieces.count == 2, "the fixture must split into two parts")
    #expect(
      calls.parts == coordinator.pendingPieces,
      "one cleanup call per document part, none for the turns: \(calls.parts.map(\.count))")
  }

  @Test("a document the user chose not to have polished is not disclosed as unpolished on its turns (#2851 §3 D)")
  func bypassedPolishIsNotDisclosedOnTheTurns() async {
    let store = FakeHistoryStore()
    let coordinator = makeStoreBackedCoordinator(
      store: store, wordTimings: Self.twoSpeakerWordTimings(),
      speakerLabeler: { _, _ in .labeled(count: 2, segments: Self.twoSpeakerSegments) },
      processPart: { part, _ in
        FileImportRunner.PartOutcome(
          text: part, polishedText: nil, polishError: nil, polishAttempted: false)
      })

    coordinator.choose(url: Self.anyURL)
    _ = await settleUntil {
      if case .ready = coordinator.state { return true } else { return false }
    }
    coordinator.start()
    _ = await settleUntil { coordinator.state == .finished }
    guard let historyID = coordinator.historyID else {
      Issue.record("no historyID after the visible run finished")
      return
    }
    let aligned = await settleUntil {
      coordinator.speakerStepState == .finished
        && turnTexts(store.current(historyID)) == ["hello", "there friend"]
    }
    #expect(aligned, "\(turnTexts(store.current(historyID)))")
    #expect(
      store.current(historyID)?.turns?.map(\.wasPolished) == [true, true],
      "a bypass is not a failure: no turn is disclosed")
  }

  @Test("a passage whose polish failed leaves its turns aligned to the floor text and disclosed (#2851 §3 D)")
  func failedPolishIsDisclosedOnTheTurns() async {
    let store = FakeHistoryStore()
    let coordinator = makeStoreBackedCoordinator(
      store: store, wordTimings: Self.twoSpeakerWordTimings(),
      speakerLabeler: { _, _ in .labeled(count: 2, segments: Self.twoSpeakerSegments) },
      processPart: { part, _ in
        FileImportRunner.PartOutcome(text: part, polishedText: nil, polishError: "boom")
      })

    coordinator.choose(url: Self.anyURL)
    _ = await settleUntil {
      if case .ready = coordinator.state { return true } else { return false }
    }
    coordinator.start()
    _ = await settleUntil { coordinator.state == .finished }
    guard let historyID = coordinator.historyID else {
      Issue.record("no historyID after the visible run finished")
      return
    }
    let aligned = await settleUntil {
      coordinator.speakerStepState == .finished
        && turnTexts(store.current(historyID)) == ["hello", "there friend"]
    }
    #expect(aligned, "the floor text still places onto the turns: \(turnTexts(store.current(historyID)))")
    #expect(
      store.current(historyID)?.turns?.map(\.wasPolished) == [false, false],
      "a failed polish is disclosed on every turn of its passage")
  }

  @Test("retrySpeakerAnalysis persists a labeled outcome without ever reaching cleanup")
  func retrySpeakerAnalysisSkipsCleanupButPersists() async {
    let store = FakeHistoryStore()
    @MainActor final class CleanupCounter {
      private(set) var count = 0
      func increment() { count += 1 }
    }
    let cleanupCounter = CleanupCounter()
    // Fails the FIRST attempt, succeeds the second — simulating whatever transient condition
    // "Try again" exists to recover from.
    @MainActor final class AttemptCounter {
      private(set) var count = 0
      func next() -> Int {
        count += 1
        return count
      }
    }
    let attempts = AttemptCounter()
    let coordinator = makeStoreBackedCoordinator(
      store: store, wordTimings: Self.twoSpeakerWordTimings(),
      speakerLabeler: { _, _ in
        attempts.next() == 1
          ? .failed(.analyzerThrew("boom")) : .labeled(count: 2, segments: Self.twoSpeakerSegments)
      },
      processPart: { part, _ in
        // Only the WIZARD's own visible-document part ("hello there friend") is legitimate
        // cleanup; anything sliced to a single speaker's words would mean turn cleanup ran.
        if part != "hello there friend" { await cleanupCounter.increment() }
        return FileImportRunner.PartOutcome(text: part, polishedText: part, polishError: nil)
      })

    coordinator.choose(url: Self.anyURL)
    _ = await settleUntil {
      if case .ready = coordinator.state { return true } else { return false }
    }
    coordinator.start()
    _ = await settleUntil { coordinator.state == .finished }
    guard let historyID = coordinator.historyID else {
      Issue.record("no historyID after the visible run finished")
      return
    }
    let firstPassFinished = await settleUntil {
      if case .failed = store.current(historyID)?.speakerAnalysis { return true }
      return false
    }
    #expect(firstPassFinished, "the first pass never persisted a failed outcome")
    #expect(coordinator.canRetrySpeakerAnalysis, "a failed analysis should be retry-eligible")

    coordinator.retrySpeakerAnalysis()

    let retried = await settleUntil {
      store.current(historyID)?.speakerAnalysis == .labeled(count: 2)
    }
    #expect(retried, "retry never persisted the successful labeled outcome")
    #expect(store.current(historyID)?.turns?.count == 2)
    #expect(cleanupCounter.count == 0, "retry must never run a cleanup of its own")
  }

  @Test(
    "a retry whose analyzer call is still in flight when the document is replaced never persists against the old row"
  )
  func retryNeverPersistsAfterDocumentReplaced() async {
    let store = FakeHistoryStore()
    let speakerGate = ManualGate()
    @MainActor final class AttemptCounter {
      private(set) var count = 0
      func next() -> Int {
        count += 1
        return count
      }
    }
    let attempts = AttemptCounter()
    let retryTelemetry = RetryTelemetryRecorder()
    let coordinator = makeStoreBackedCoordinator(
      store: store, wordTimings: Self.twoSpeakerWordTimings(),
      speakerLabeler: { _, _ in
        // Attempt 1: the ordinary first pass, which fails. Attempt 2: the retry, blocked
        // until the test lets it through — exactly the window a document replacement (or a
        // Stop, in the sibling test below) can land in.
        if attempts.next() == 1 { return .failed(.analyzerThrew("boom")) }
        await speakerGate.markArrived()
        await speakerGate.waitUntilOpen()
        return .labeled(count: 2, segments: Self.twoSpeakerSegments)
      }, emitSpeakerRetryTelemetry: { retryTelemetry.record($0) })

    coordinator.choose(url: Self.anyURL)
    _ = await settleUntil {
      if case .ready = coordinator.state { return true } else { return false }
    }
    coordinator.start()
    _ = await settleUntil { coordinator.state == .finished }
    guard let firstHistoryID = coordinator.historyID else {
      Issue.record("no historyID after the first run")
      return
    }
    let firstPassFailed = await settleUntil {
      if case .failed = store.current(firstHistoryID)?.speakerAnalysis { return true }
      return false
    }
    #expect(firstPassFailed)
    #expect(coordinator.canRetrySpeakerAnalysis)

    coordinator.retrySpeakerAnalysis()
    await speakerGate.waitUntilArrived()

    // The user moves on to a DIFFERENT file while the retry's own analyzer call is still
    // blocked — `choose(url:)` cancels `speakerStepTask` (which now owns the retry, per the
    // chunk-2a review fix) and gives `historyID` a new value.
    coordinator.choose(url: Self.anyURL)

    await speakerGate.open()
    let sawRetryAttempt = await settleUntil { attempts.count == 2 }
    #expect(sawRetryAttempt, "the retry's own analyzer call should still have run to completion")
    // A bounded settle for the (deliberately absent) write, not a wait for a signal that a
    // correct implementation never sends.
    for _ in 0..<50 { await Task.yield() }

    #expect(
      store.current(firstHistoryID)?.speakerAnalysis != .labeled(count: 2),
      "a stale retry must never persist a labeled outcome against a document the user already left"
    )
    #expect(
      retryTelemetry.outcomes == [],
      "a superseded retry says nothing about the analyzer and must report neither outcome")
  }

  @Test("Stop pressed while a retry's own analyzer call is in flight prevents any further write")
  func stopDuringRetryPreventsWrite() async {
    let store = FakeHistoryStore()
    let speakerGate = ManualGate()
    @MainActor final class AttemptCounter {
      private(set) var count = 0
      func next() -> Int {
        count += 1
        return count
      }
    }
    let attempts = AttemptCounter()
    let retryTelemetry = RetryTelemetryRecorder()
    let coordinator = makeStoreBackedCoordinator(
      store: store, wordTimings: Self.twoSpeakerWordTimings(),
      speakerLabeler: { _, _ in
        if attempts.next() == 1 { return .failed(.analyzerThrew("boom")) }
        await speakerGate.markArrived()
        await speakerGate.waitUntilOpen()
        return .labeled(count: 2, segments: Self.twoSpeakerSegments)
      }, emitSpeakerRetryTelemetry: { retryTelemetry.record($0) })

    coordinator.choose(url: Self.anyURL)
    _ = await settleUntil {
      if case .ready = coordinator.state { return true } else { return false }
    }
    coordinator.start()
    _ = await settleUntil { coordinator.state == .finished }
    guard let historyID = coordinator.historyID else {
      Issue.record("no historyID after the first run")
      return
    }
    let firstPassFailed = await settleUntil {
      if case .failed = store.current(historyID)?.speakerAnalysis { return true }
      return false
    }
    #expect(firstPassFailed)
    #expect(coordinator.canRetrySpeakerAnalysis)

    coordinator.retrySpeakerAnalysis()
    await speakerGate.waitUntilArrived()

    // Stop is unconditional, before `isRunning` (the visible screen already reads Done) —
    // this is exactly the "background pass can outlive Done" case the retry task must now
    // be reachable from, per the chunk-2a review fix (retry runs as `speakerStepTask`).
    coordinator.stop()

    await speakerGate.open()
    let sawRetryAttempt = await settleUntil { attempts.count == 2 }
    #expect(sawRetryAttempt, "the retry's own analyzer call should still have run to completion")
    for _ in 0..<50 { await Task.yield() }

    #expect(
      store.current(historyID)?.speakerAnalysis != .labeled(count: 2),
      "Stop during a retry must prevent its result from ever being persisted"
    )
    // Stop leaves `historyID` in place and the row still failed, so an identity-only guard
    // would have blamed the analyzer for a retry the user abandoned (found by chunk review).
    #expect(
      retryTelemetry.outcomes == [],
      "a stopped retry must report neither recovered nor still_failed")
  }

  @Test("canRetrySpeakerAnalysis is false for a labeled or single outcome, and while in progress")
  func canRetryFalseForLabeledOrSingleOrInProgress() async {
    let store = FakeHistoryStore()
    let speakerGate = ManualGate()
    let coordinator = makeStoreBackedCoordinator(
      store: store, wordTimings: Self.twoSpeakerWordTimings(),
      speakerLabeler: { _, _ in
        await speakerGate.markArrived()
        await speakerGate.waitUntilOpen()
        return .labeled(count: 2, segments: Self.twoSpeakerSegments)
      })

    coordinator.choose(url: Self.anyURL)
    _ = await settleUntil {
      if case .ready = coordinator.state { return true } else { return false }
    }
    coordinator.start()
    _ = await settleUntil { coordinator.state == .finished }
    await speakerGate.waitUntilArrived()
    #expect(
      !coordinator.canRetrySpeakerAnalysis, "must not be retry-eligible while still in progress")

    await speakerGate.open()
    let stored = await settleUntil {
      store.current(coordinator.historyID ?? UUID())?.speakerAnalysis == .labeled(count: 2)
    }
    #expect(stored)
    // The write lands BEFORE the step reads finished; asserting on the write alone could
    // pass while "in progress" was still what made the button absent (found by second-pass
    // review). Wait for the whole pass, then the assertion is about the labeled outcome.
    let finished = await settleUntil { coordinator.speakerStepState == .finished }
    #expect(finished)
    #expect(!coordinator.canRetrySpeakerAnalysis, "a labeled outcome has nothing to retry")
  }

  @Test("renameSpeaker re-reads the current row and writes through the explicit-rename path")
  func renameSpeakerWritesThroughExplicitRenamePath() async {
    let store = FakeHistoryStore()
    let coordinator = makeStoreBackedCoordinator(
      store: store, wordTimings: Self.twoSpeakerWordTimings(),
      speakerLabeler: { _, _ in .labeled(count: 2, segments: Self.twoSpeakerSegments) })

    coordinator.choose(url: Self.anyURL)
    _ = await settleUntil {
      if case .ready = coordinator.state { return true } else { return false }
    }
    coordinator.start()
    _ = await settleUntil { coordinator.state == .finished }
    guard let historyID = coordinator.historyID else {
      Issue.record("no historyID after the visible run finished")
      return
    }
    let stored = await settleUntil { store.current(historyID)?.turns != nil }
    #expect(stored)

    let failure = await coordinator.renameSpeaker(id: "A", name: "Zach")
    #expect(failure == nil, "a rename against a real labeled row should not fail")
    #expect(store.current(historyID)?.speakerNames?["A"] == "Zach")
  }

  @Test("renameSpeaker returns a failure, never crashing, when there are no turns to rename against")
  func renameSpeakerFailsGracefullyWithNoTurns() async {
    let store = FakeHistoryStore()
    let coordinator = makeStoreBackedCoordinator(
      store: store, speakerLabeler: { _, _ in .single(segments: []) })

    coordinator.choose(url: Self.anyURL)
    _ = await settleUntil {
      if case .ready = coordinator.state { return true } else { return false }
    }
    coordinator.start()
    _ = await settleUntil { coordinator.state == .finished }

    let failure = await coordinator.renameSpeaker(id: "A", name: "Zach")
    #expect(failure != nil, "there is nothing to rename against a .single outcome")
  }

  @Test("exportButtonLabels relabels for Marked up regardless of whether the document has turns")
  func exportButtonLabelsRelabelForMarkedUpRegardlessOfTurns() async {
    let store = FakeHistoryStore()
    let coordinator = makeStoreBackedCoordinator(
      store: store, speakerLabeler: { _, _ in .single(segments: []) })

    coordinator.choose(url: Self.anyURL)
    _ = await settleUntil {
      if case .ready = coordinator.state { return true } else { return false }
    }
    coordinator.start()
    _ = await settleUntil { coordinator.state == .finished }
    #expect(coordinator.turns == nil, "a .single outcome has no turns")

    #expect(coordinator.exportButtonLabels.copy == "Copy everything")
    coordinator.documentView = .markedUp
    #expect(
      coordinator.exportButtonLabels.copy == "Copy cleaned",
      "the export-rule relabel is general, not scoped to turn-labeled documents")
    #expect(coordinator.exportButtonLabels.save == "Save cleaned as…")
    #expect(coordinator.exportButtonLabels.share == "Share cleaned…")
  }

  @Test("exportText for a turn-labeled document routes through the presenter, honoring timesOn")
  func exportTextForTurnLabeledDocumentRoutesThroughPresenter() async {
    let store = FakeHistoryStore()
    let coordinator = makeStoreBackedCoordinator(
      store: store, transcribedText: "hello there friend", wordTimings: Self.twoSpeakerWordTimings(),
      speakerLabeler: { _, _ in .labeled(count: 2, segments: Self.twoSpeakerSegments) })

    coordinator.choose(url: Self.anyURL)
    _ = await settleUntil {
      if case .ready = coordinator.state { return true } else { return false }
    }
    coordinator.start()
    _ = await settleUntil { coordinator.state == .finished }
    guard let historyID = coordinator.historyID else {
      Issue.record("no historyID after the visible run finished")
      return
    }
    let stored = await settleUntil { store.current(historyID)?.turns != nil }
    #expect(stored)

    coordinator.timesOn = true
    #expect(
      coordinator.exportText.contains(":"),
      "with times on, a turn-labeled export should carry a time label")
    coordinator.timesOn = false
    #expect(
      !coordinator.exportText.contains(":"),
      "with times off, the export should carry no time label")
  }

  @Test("prepareTurnDiffs populates one diff per turn, off the main actor, matching prepareMarkedUp's shape")
  func prepareTurnDiffsPopulatesOneDiffPerTurn() async {
    let store = FakeHistoryStore()
    let coordinator = makeStoreBackedCoordinator(
      store: store, transcribedText: "hello there friend", wordTimings: Self.twoSpeakerWordTimings(),
      speakerLabeler: { _, _ in .labeled(count: 2, segments: Self.twoSpeakerSegments) })

    coordinator.choose(url: Self.anyURL)
    _ = await settleUntil {
      if case .ready = coordinator.state { return true } else { return false }
    }
    coordinator.start()
    _ = await settleUntil { coordinator.state == .finished }
    let stored = await settleUntil { coordinator.turns != nil }
    #expect(stored)
    #expect(coordinator.turnDiffs == nil, "nothing has computed a diff yet")

    await coordinator.prepareTurnDiffs()

    let diffs = coordinator.turnDiffs
    #expect(diffs?.count == coordinator.turns?.count)
    for turn in coordinator.turns ?? [] {
      #expect(diffs?[turn.id] != nil, "every turn should have its own diff entry")
    }
  }

  @Test(
    "speakerNoticeReason distinguishes a real failure from a pass whose write threw and left the row untouched"
  )
  func speakerNoticeReasonDistinguishesFailedFromUnresolved() async {
    let store = FakeHistoryStore()
    struct WriteError: Error {}
    // Since #2851 the speaker step takes no engine claim, so the one way a labeled pass
    // leaves the row exactly as it was is a persistence failure.
    let coordinator = makeCoordinator(
      lease: EngineLease(), transcribedText: "hello there friend",
      wordTimings: Self.twoSpeakerWordTimings(),
      speakerLabeler: { _, _ in .labeled(count: 2, segments: Self.twoSpeakerSegments) },
      saveToHistory: { store.save($0) },
      updateHistoryRow: { store.update($0) },
      mergeSpeakerFields: { _, _, _ in throw WriteError() },
      currentHistoryRow: { store.current($0) })

    coordinator.choose(url: Self.anyURL)
    _ = await settleUntil {
      if case .ready = coordinator.state { return true } else { return false }
    }
    coordinator.start()
    let finished = await settleUntil { coordinator.state == .finished }
    #expect(finished)
    let becameFinished = await settleUntil { coordinator.speakerStepState == .finished }
    #expect(becameFinished)

    guard let historyID = coordinator.historyID else {
      Issue.record("no historyID after the visible run finished")
      return
    }
    #expect(
      store.current(historyID)?.speakerAnalysis == nil,
      "a pass whose write threw must leave the row untouched")
    #expect(coordinator.speakerNoticeReason == .unresolved)
    #expect(coordinator.canRetrySpeakerAnalysis)
  }

  @Test("renameSpeaker reports saved on success and failed when there is nothing to rename against")
  func renameSpeakerTelemetryReportsSavedAndFailed() async {
    let store = FakeHistoryStore()
    @MainActor final class TelemetryRecorder {
      private(set) var outcomes: [TelemetryService.FileImportRenameOutcome] = []
      func record(_ outcome: TelemetryService.FileImportRenameOutcome) { outcomes.append(outcome) }
    }
    let telemetry = TelemetryRecorder()
    let coordinator = makeStoreBackedCoordinator(
      store: store, wordTimings: Self.twoSpeakerWordTimings(),
      speakerLabeler: { _, _ in .labeled(count: 2, segments: Self.twoSpeakerSegments) },
      emitRenameTelemetry: { telemetry.record($0) })

    coordinator.choose(url: Self.anyURL)
    _ = await settleUntil {
      if case .ready = coordinator.state { return true } else { return false }
    }
    coordinator.start()
    _ = await settleUntil { coordinator.state == .finished }
    let stored = await settleUntil { coordinator.turns != nil }
    #expect(stored)

    _ = await coordinator.renameSpeaker(id: "A", name: "Zach")
    #expect(telemetry.outcomes == [.saved])

    let secondStore = FakeHistoryStore()
    let secondCoordinator = makeStoreBackedCoordinator(
      store: secondStore, speakerLabeler: { _, _ in .single(segments: []) },
      emitRenameTelemetry: { telemetry.record($0) })
    secondCoordinator.choose(url: Self.anyURL)
    _ = await settleUntil {
      if case .ready = secondCoordinator.state { return true } else { return false }
    }
    secondCoordinator.start()
    _ = await settleUntil { secondCoordinator.state == .finished }

    _ = await secondCoordinator.renameSpeaker(id: "A", name: "Ariana")
    #expect(telemetry.outcomes == [.saved, .failed], "a .single outcome has nothing to rename against")
  }

  /// Shared by the retry-telemetry tests and the two in-flight retry tests above, which
  /// each prove a retry that never reached its own write reports NOTHING.
  @MainActor final class RetryTelemetryRecorder {
    private(set) var outcomes: [TelemetryService.FileImportSpeakerRetryOutcome] = []
    func record(_ outcome: TelemetryService.FileImportSpeakerRetryOutcome) {
      outcomes.append(outcome)
    }
  }

  /// Runs one import whose first analyzer pass fails, then presses "Try again" once, and
  /// returns the exact retry-telemetry sequence once the retry has settled (bounded yields
  /// AFTER the step reads finished, so a duplicate emit would still be caught).
  private func retryOutcomes(
    afterRetryReturning retryOutcome: SpeakerAnalysis
  ) async -> [TelemetryService.FileImportSpeakerRetryOutcome]? {
    let store = FakeHistoryStore()
    let telemetry = RetryTelemetryRecorder()
    @MainActor final class AttemptCounter {
      private(set) var count = 0
      func next() -> Int {
        count += 1
        return count
      }
    }
    let attempts = AttemptCounter()
    let coordinator = makeStoreBackedCoordinator(
      store: store, wordTimings: Self.twoSpeakerWordTimings(),
      speakerLabeler: { _, _ in
        attempts.next() == 1 ? .failed(.analyzerThrew("boom")) : retryOutcome
      }, emitSpeakerRetryTelemetry: { telemetry.record($0) })

    coordinator.choose(url: Self.anyURL)
    _ = await settleUntil {
      if case .ready = coordinator.state { return true } else { return false }
    }
    coordinator.start()
    _ = await settleUntil { coordinator.state == .finished }
    guard let historyID = coordinator.historyID else {
      Issue.record("no historyID after the first run")
      return nil
    }
    let firstPassFailed = await settleUntil {
      if case .failed = store.current(historyID)?.speakerAnalysis { return true }
      return false
    }
    #expect(firstPassFailed)
    #expect(telemetry.outcomes == [], "the ordinary first pass is not a retry")

    coordinator.retrySpeakerAnalysis()
    let sawRetry = await settleUntil { attempts.count == 2 }
    #expect(sawRetry)
    _ = await settleUntil { coordinator.speakerStepState == .finished && !telemetry.outcomes.isEmpty }
    for _ in 0..<50 { await Task.yield() }
    return telemetry.outcomes
  }

  @Test("a retry whose write lands as labeled reports exactly one recovered (#2811 §3e)")
  func retryTelemetryRecoveredForLabeled() async {
    let outcomes = await retryOutcomes(
      afterRetryReturning: .labeled(count: 2, segments: Self.twoSpeakerSegments))
    #expect(outcomes == [.recovered])
  }

  @Test("a retry whose write lands as single reports recovered too, since that clears the notice")
  func retryTelemetryRecoveredForSingle() async {
    let outcomes = await retryOutcomes(afterRetryReturning: .single(segments: []))
    #expect(outcomes == [.recovered])
  }

  @Test("a retry that runs to its own write and still fails reports exactly one still_failed")
  func retryTelemetryStillFailed() async {
    let outcomes = await retryOutcomes(afterRetryReturning: .failed(.modelsUnavailable))
    #expect(outcomes == [.stillFailed])
  }

  @Test("noteRenameCancelled reports cancelled, and only that (#2811 §3e)")
  func renameCancelledTelemetry() async {
    let store = FakeHistoryStore()
    @MainActor final class TelemetryRecorder {
      private(set) var outcomes: [TelemetryService.FileImportRenameOutcome] = []
      func record(_ outcome: TelemetryService.FileImportRenameOutcome) { outcomes.append(outcome) }
    }
    let telemetry = TelemetryRecorder()
    let coordinator = makeStoreBackedCoordinator(
      store: store, speakerLabeler: { _, _ in .single(segments: []) },
      emitRenameTelemetry: { telemetry.record($0) })
    coordinator.noteRenameCancelled()
    #expect(telemetry.outcomes == [.cancelled])
  }

  @Test("noteTurnsDisplayed reports once per document, and again for the next document")
  func turnsDisplayedTelemetryOncePerDocument() async {
    let store = FakeHistoryStore()
    @MainActor final class Counter {
      private(set) var count = 0
      func bump() { count += 1 }
    }
    let displayed = Counter()
    let coordinator = makeStoreBackedCoordinator(
      store: store, wordTimings: Self.twoSpeakerWordTimings(),
      speakerLabeler: { _, _ in .labeled(count: 2, segments: Self.twoSpeakerSegments) },
      emitTurnsDisplayedTelemetry: { displayed.bump() })

    // Before any import there is no document, so a stray appear reports nothing.
    coordinator.noteTurnsDisplayed()
    #expect(displayed.count == 0)

    coordinator.choose(url: Self.anyURL)
    _ = await settleUntil {
      if case .ready = coordinator.state { return true } else { return false }
    }
    coordinator.start()
    _ = await settleUntil { coordinator.state == .finished }
    #expect(coordinator.historyID != nil)

    coordinator.noteTurnsDisplayed()
    coordinator.noteTurnsDisplayed()
    #expect(displayed.count == 1, "a view-mode flip re-appears the same document; not a new fact")

    // A second import is a new document and reports once more.
    coordinator.choose(url: Self.anyURL)
    _ = await settleUntil {
      if case .ready = coordinator.state { return true } else { return false }
    }
    coordinator.start()
    _ = await settleUntil { coordinator.state == .finished }
    coordinator.noteTurnsDisplayed()
    #expect(displayed.count == 2)
  }
}
