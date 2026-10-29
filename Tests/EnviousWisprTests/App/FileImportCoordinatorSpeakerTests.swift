import EnviousWisprASR
import EnviousWisprCore
import EnviousWisprLLM
@testable import EnviousWisprPipeline
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
  ///
  /// The test-side wait is BOUNDED and returns whether the signal came. A bare continuation
  /// wait passes instantly on the happy path and, when the coordinator's completion path is
  /// broken, parks the whole lane: the night battery of 2026-09-14 killed two #2896 lanes at
  /// 1800 s on exactly that (`~/.claude/knowledge/dev/test-timing.md`). Callers `#expect` the
  /// result, so a signal that never arrives is a red test with a name.
  private actor Gate {
    private var entered = false

    func markEntered() {
      entered = true
    }

    func waitUntilEntered(deadline: Duration = .seconds(10)) async -> Bool {
      let clock = ContinuousClock()
      let end = clock.now + deadline
      while !entered, clock.now < end {
        // settle: poll the gate's own flag until the deadline; a cancelled waiter gives up
        // rather than spinning on sleeps that throw at once.
        do { try await Task.sleep(for: .milliseconds(2)) } catch { return false }
      }
      return entered
    }
  }

  /// A gate a test controls from outside: a call can wait to be told to proceed, and the
  /// test can wait to know a call has arrived. Used to prove ORDERING between the speaker
  /// step and the document cleanup (#2851: either may land first).
  ///
  /// `waitUntilOpen()` stays a plain continuation: it is awaited INSIDE the fake step, on the
  /// coordinator's side; a test that returns early must still open it. `waitUntilArrived()`
  /// is the TEST-side wait and is bounded for the reason `Gate` states above.
  private actor ManualGate {
    private var openWaiters: [CheckedContinuation<Void, Never>] = []
    private var isOpen = false
    private var hasArrived = false

    func markArrived() {
      hasArrived = true
    }

    func waitUntilArrived(deadline: Duration = .seconds(10)) async -> Bool {
      let clock = ContinuousClock()
      let end = clock.now + deadline
      while !hasArrived, clock.now < end {
        // settle: poll the gate's own flag until the deadline; a cancelled waiter gives up
        // rather than spinning on sleeps that throw at once.
        do { try await Task.sleep(for: .milliseconds(2)) } catch { return false }
      }
      return hasArrived
    }

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
    segmentTimings: [ASRSegmentTiming]? = nil,
    speakerLabeler: @escaping @MainActor ([Float], TimeInterval) async -> SpeakerAnalysis,
    saveToHistory: @escaping @MainActor (Transcript) async throws -> Void = { _ in },
    updateHistoryRow: @escaping @MainActor (Transcript) async throws -> Bool = { _ in true },
    mergeSpeakerFields: @escaping @MainActor (UUID, TranscriptSpeakerAnalysis, [Turn]?) async throws ->
      Bool = { _, _, _ in true },
    writeExplicitRename: @escaping @MainActor (
      UUID, TranscriptSpeakerAnalysis, [Turn]?, (speakerId: String, name: String)
    ) async throws -> Bool = { _, _, _, _ in false },
    currentHistoryRow: @escaping @MainActor (UUID) -> Transcript? = { _ in nil },
    historyRowExists: @escaping @MainActor (UUID) -> Bool = { _ in true },
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
        FileImportRunner.PartOutcome(text: part, polishedText: part)
      },
    processPartsOverride: FileImportCoordinator.ProcessParts? = nil,
    beginRunOverride: (@MainActor () -> FileImportCoordinator.RunConfiguration)? = nil,
    onEngineReleased: @escaping @MainActor () -> Void = {}
  ) -> FileImportCoordinator {
    FileImportCoordinator(
      decode: { _ in Self.decoded(seconds: seconds) },
      transcribe: { _, _, _ in
        ASRResult(
          text: transcribedText, language: "en", duration: 0, processingTime: 0,
          backendType: .parakeet, wordTimings: wordTimings, wordTimingCoverage: wordTimingCoverage,
          segmentTimings: segmentTimings)
      },
      speakerLabeler: speakerLabeler,
      emitSpeakerTelemetry: emitSpeakerTelemetry,
      emitTurnTelemetry: emitTurnTelemetry,
      emitRenameTelemetry: emitRenameTelemetry,
      emitSpeakerRetryTelemetry: emitSpeakerRetryTelemetry,
      emitTurnsDisplayedTelemetry: emitTurnsDisplayedTelemetry,
      engineAdmission: .live(lease: lease, as: .fileImport),
      onEngineReleased: onEngineReleased,
      beginRun: beginRunOverride ?? {
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
      historyRowExists: historyRowExists,
      processParts: processPartsOverride ?? serialFileImportTestProcessor(processPart))
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
        return FileImportRunner.PartOutcome(text: part, polishedText: part)
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
    // The speaker step finishes before the cleanup starts (#2851 follow-up), so
    // `.finished` implies it ran.
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
    #expect(coordinator.speakerAnalysis == .labeled(count: 2, segments: []))

    // A second file must not read as though the first file's speaker analysis was
    // about it — found by second-pass review.
    coordinator.choose(url: Self.anyURL)
    #expect(coordinator.speakerAnalysis == nil)
  }

  @Test("the cleanup waits for the speaker step, and Stop cancels the wait")
  func cleanupWaitsForTheSpeakerStepAndStopCancelsTheWait() async {
    let gate = Gate()
    let coordinator = makeCoordinator(
      lease: EngineLease(),
      speakerLabeler: { _, _ in
        await gate.markEntered()
        // #2851 follow-up: the cleanup runs per speaker section, so it needs the turns
        // first. A step that never returns in-window must hold the cleanup back.
        try? await Task.sleep(nanoseconds: 30_000_000_000)  // settle: cancelled by Stop first
        return .single(segments: [])
      })

    coordinator.choose(url: Self.anyURL)
    _ = await settleUntil {
      if case .ready = coordinator.state { return true } else { return false }
    }
    coordinator.start()
    #expect(await gate.waitUntilEntered(), "gate: the fake step never entered")

    #expect(coordinator.phase == "Finding who said what")
    #expect(coordinator.parts.isEmpty, "no cleanup before the sections exist")
    #expect(coordinator.state != .finished)

    coordinator.stop()
    let released = await settleUntil { coordinator.isEngineHeld == false }
    #expect(released, "the engine claim was never released after Stop")
  }

  @Test("Stop cancels the awaited speaker step and the claim comes back")
  func stopCancelsTheAwaitedSpeakerStep() async {
    let speakerGate = Gate()
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
      })

    coordinator.choose(url: Self.anyURL)
    _ = await settleUntil {
      if case .ready = coordinator.state { return true } else { return false }
    }
    coordinator.start()
    #expect(await speakerGate.waitUntilEntered(), "speakerGate: the fake step never entered")

    // The run task holds the claim through the awaited step.
    #expect(coordinator.isEngineHeld)

    coordinator.stop()

    let released = await settleUntil { coordinator.isEngineHeld == false }
    #expect(released, "the engine claim was never released after Stop")
    // `stop()` cancels the step directly, or it keeps running for its own deadline
    // after the user has moved on.
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
      mergeSpeakerFields: { try store.mergeSpeakerFields($0, $1, $2) },
      currentHistoryRow: { store.current($0) },
      emitTurnTelemetry: { outcome, _, _ in telemetry.record(outcome) })

    coordinator.choose(url: Self.anyURL)
    _ = await settleUntil {
      if case .ready = coordinator.state { return true } else { return false }
    }
    coordinator.start()
    _ = await settleUntil { coordinator.state == .finished }
    // `.stored` is emitted by `finishRun`'s one write, before `.finished`.
    #expect(telemetry.outcomes.contains(.stored), "the final write never reported a stored outcome")

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
    "Clean it again is refused while the speaker step runs, and the analysis still lands once"
  )
  func rePolishIsRefusedWhileTheSpeakerStepRuns() async {
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
    #expect(await speakerGate.waitUntilArrived(), "speakerGate: the gated call never arrived")

    // "Clean it again" while the run is still on the awaited speaker step: refused, since
    // the run is in progress (#2851 follow-up); nothing about the step is disturbed.
    let generationBefore = coordinator.generation
    coordinator.rePolish()
    #expect(coordinator.generation == generationBefore, "refused while running")
    #expect(coordinator.isRunning)

    await speakerGate.open()
    let finished = await settleUntil { coordinator.state == .finished }
    #expect(finished)
    let persisted = await settleUntil { recorder.analyses.contains(.labeled(count: 2)) }
    #expect(
      persisted,
      "the only speaker analysis this document will ever get must land once"
    )
  }

  /// #3194: the relaunch owner that the update install and the language relaunch both read says
  /// a file transcription is work in flight while the run waits on its speaker step, and releases
  /// once the run finishes and the engine is let go. Before #3194 the update install read
  /// dictation alone, so a Sparkle relaunch could take the transcription down.
  @Test("a relaunch is refused while a file transcription runs, and allowed once it ends (#3194)")
  func relaunchIsRefusedWhileAFileTranscriptionRuns() async {
    let speakerGate = ManualGate()
    let coordinator = makeCoordinator(
      lease: EngineLease(),
      transcribedText: "hello there friend",
      wordTimings: Self.twoSpeakerWordTimings(),
      speakerLabeler: { _, _ in
        await speakerGate.markArrived()
        await speakerGate.waitUntilOpen()
        return .labeled(count: 2, segments: Self.twoSpeakerSegments)
      },
      mergeSpeakerFields: { _, _, _ in true })
    #expect(!AppRelauncher.workInFlight(dictationActive: false, fileImport: coordinator))

    coordinator.choose(url: Self.anyURL)
    _ = await settleUntil {
      if case .ready = coordinator.state { return true } else { return false }
    }
    coordinator.start()
    #expect(await speakerGate.waitUntilArrived(), "speakerGate: the gated call never arrived")
    #expect(
      AppRelauncher.workInFlight(dictationActive: false, fileImport: coordinator),
      "a relaunch mid transcription would lose the run")

    await speakerGate.open()
    #expect(await settleUntil { coordinator.state == .finished })
    let released = await settleUntil {
      !AppRelauncher.workInFlight(dictationActive: false, fileImport: coordinator)
    }
    #expect(released, "a finished run with its engine released is not work in flight")
  }

  // MARK: - Retry, rename, and the savePolishedToHistory race fix (#2811 phase 4 of #2807)

  /// A live, mutable simulation of the History store — closer to `TranscriptCoordinator`'s own
  /// "the in-memory list is the oracle" contract than four independent recorder closures, and
  /// needed here specifically: these tests exist to prove a write reads back what ANOTHER
  /// writer (an external rename) left behind, which four disconnected spies cannot represent.
  @MainActor private final class FakeHistoryStore {
    private(set) var rows: [UUID: Transcript] = [:]
    /// The 1-based merge call that throws, for a write that fails once mid-run.
    var throwOnMergeCall: Int?
    /// A second 1-based merge call that throws, for two failed writes in one test (#3903).
    var alsoThrowOnMergeCall: Int?
    private(set) var mergeCalls = 0
    struct MergeError: Error {}
    func save(_ row: Transcript) { rows[row.id] = row }
    func delete(_ id: UUID) { rows[id] = nil }
    func update(_ row: Transcript) -> Bool {
      guard rows[row.id] != nil else { return false }
      rows[row.id] = row
      return true
    }
    func mergeSpeakerFields(_ id: UUID, _ analysis: TranscriptSpeakerAnalysis, _ turns: [Turn]?)
      throws -> Bool
    {
      mergeCalls += 1
      if mergeCalls == throwOnMergeCall || mergeCalls == alsoThrowOnMergeCall {
        throw MergeError()
      }
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

    /// #4075 S1: holds the next explicit rename until `releaseHeldRename()`, like a write
    /// already sent: cancelling the waiting caller does not withdraw it.
    var holdNextRename = false
    /// Makes the next released rename throw instead of writing.
    var failNextRename = false
    private(set) var renameCalls = 0
    private var heldRename: CheckedContinuation<Void, Never>?
    var isHoldingRename: Bool { heldRename != nil }
    struct RenameError: Error {}

    func submitRename(
      _ id: UUID, _ analysis: TranscriptSpeakerAnalysis, _ turns: [Turn]?,
      _ explicitRename: (speakerId: String, name: String)
    ) async throws -> Bool {
      renameCalls += 1
      if holdNextRename {
        holdNextRename = false
        await withCheckedContinuation { heldRename = $0 }
      }
      if failNextRename {
        failNextRename = false
        throw RenameError()
      }
      return rename(id, analysis, turns, explicitRename)
    }

    func releaseHeldRename() {
      holdNextRename = false
      let held = heldRename
      heldRename = nil
      held?.resume()
    }
  }

  private func makeStoreBackedCoordinator(
    store: FakeHistoryStore, lease: EngineLease = EngineLease(), seconds: Double = 1.0,
    transcribedText: String = "hello there friend",
    wordTimings: [ASRWordTiming]? = nil,
    segmentTimings: [ASRSegmentTiming]? = nil,
    speakerLabeler: @escaping @MainActor ([Float], TimeInterval) async -> SpeakerAnalysis,
    processPart: @escaping @MainActor (String, String?) async throws ->
      FileImportRunner.PartOutcome = { part, _ in
        FileImportRunner.PartOutcome(text: part, polishedText: part)
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
    emitTurnsDisplayedTelemetry: @escaping @MainActor () -> Void = {},
    prepareLocalPolish: @escaping @MainActor (FileImportCoordinator.RunConfiguration) async ->
      Bool = { _ in true },
    processPartsOverride: FileImportCoordinator.ProcessParts? = nil,
    beginRunOverride: (@MainActor () -> FileImportCoordinator.RunConfiguration)? = nil,
    onEngineReleased: @escaping @MainActor () -> Void = {}
  ) -> FileImportCoordinator {
    makeCoordinator(
      lease: lease, seconds: seconds, transcribedText: transcribedText,
      wordTimings: wordTimings, segmentTimings: segmentTimings, speakerLabeler: speakerLabeler,
      saveToHistory: { store.save($0) },
      updateHistoryRow: { store.update($0) },
      mergeSpeakerFields: { try store.mergeSpeakerFields($0, $1, $2) },
      writeExplicitRename: { try await store.submitRename($0, $1, $2, $3) },
      currentHistoryRow: { store.current($0) },
      emitTurnTelemetry: emitTurnTelemetry, emitRenameTelemetry: emitRenameTelemetry,
      emitSpeakerRetryTelemetry: emitSpeakerRetryTelemetry,
      emitTurnsDisplayedTelemetry: emitTurnsDisplayedTelemetry,
      prepareLocalPolish: prepareLocalPolish, processPart: processPart,
      processPartsOverride: processPartsOverride, beginRunOverride: beginRunOverride,
      onEngineReleased: onEngineReleased)
  }

  @MainActor
  private final class BatchCapture {
    var requests = 0
    var batches = 0
    var onRequest: (@MainActor () -> Void)?
  }
  private struct BatchPolisher: TranscriptPolisher {
    let capture: BatchCapture
    var preserveExistingPunctuation = false
    func polish(
      text: String, instructions: PolishInstructions, config: LLMProviderConfig,
      onToken: (@Sendable (String) -> Void)?
    ) async throws -> LLMResult { throw LLMError.requestFailed("Unexpected legacy batch fixture path") }
    func polish(
      envelope: PromptEnvelope, config: LLMProviderConfig,
      onToken: (@Sendable (String) -> Void)?
    ) async throws -> LLMResult {
      await MainActor.run { capture.requests += 1; capture.onRequest?() }
      guard let pair = envelope.asSingleTurn(), pair.user.hasPrefix("Transcript to clean:\n\n")
      else { throw LLMError.requestFailed("Unexpected fixture envelope") }
      let text = String(pair.user.dropFirst("Transcript to clean:\n\n".count))
      func clean(_ text: String) -> String {
        let sentence = text.prefix(1).uppercased() + text.dropFirst()
        return preserveExistingPunctuation && sentence.hasSuffix(".") ? sentence : sentence + "."
      }
      if text.hasPrefix("<s1>") {
        await MainActor.run { capture.batches += 1 }
        guard let sections = SectionEnvelope.unwrap(text, expected: 2)
        else { throw LLMError.requestFailed("Expected two real runner sections in one request") }
        return LLMResult(polishedText: SectionEnvelope.wrap(sections.map(clean)))
      }
      return LLMResult(polishedText: clean(text))
    }
  }

  @Test("Initial import and Clean it again use real batching while keeping speaker IDs, gaps, History and piece progress",
    arguments: [(false, false), (true, false), (true, true)])
  func realBatchPreservesSpeakerDocument(longFirstTurn: Bool, sentenceBoundary: Bool) async throws {
    let tail = "please send the final report to the design team before lunch tomorrow"
    let left = Array(repeating: "the report needs review by our design team before Friday", count: 50).joined(separator: " ") + (sentenceBoundary ? "." : "")
    let insideGap = sentenceBoundary ? " \t \n" : "  "
    let a = longFirstTurn ? left + insideGap + tail : tail
    let b = "we should review the remaining changes with our colleagues before we publish"
    let gap = "  \n"
    let raw = a + gap + b
    let firstCount = a.split(whereSeparator: \.isWhitespace).count
    var timings: [ASRWordTiming] = []
    var cursor = raw.startIndex
    for (index, token) in raw.split(whereSeparator: \.isWhitespace).enumerated() {
      let range = try #require(raw.range(of: String(token), range: cursor..<raw.endIndex))
      let ns = NSRange(range, in: raw)
      let start = index < firstCount ? index * 50 : firstCount * 50 + 1000 + (index - firstCount) * 50
      timings.append(ASRWordTiming(word: String(token), range: ns.location..<(ns.location + ns.length), startMs: start, endMs: start + 40))
      cursor = range.upperBound
    }
    let store = FakeHistoryStore(); let capture = BatchCapture()
    let processor = FileImportRunner(
      keychainManager: KeychainManager(), egOneRuntime: nil, s1MiniRuntime: nil,
      outputClassifierHolder: nil, languageIdentifier: { _ in ("en", 0.99) },
      makeEGOnePolisher: nil, promptPlanner: nil,
      makePolisher: { _, _, _ in BatchPolisher(capture: capture, preserveExistingPunctuation: sentenceBoundary) })
    let settings = RecordingSettingsSnapshot(
      backendType: .parakeet, backendSupportsLanguageDetection: false, languageMode: .locked("en"),
      wordCorrectionEnabled: false, fillerRemovalEnabled: sentenceBoundary, emojiFormatterEnabled: false,
      spokenPunctuationEnabled: false, spokenPunctuationStartWords: nil,
      llmProvider: LLMProvider.openAI.rawValue, llmModel: "gpt-6.1-sol",
      s1Control: nil, englishSpelling: .american, casualModeEnabled: false)
    var finished = BoundedWait.Signal()
    weak var observed: FileImportCoordinator?
    var progress: [FileImportCoordinator.State] = []
    let coordinator = makeStoreBackedCoordinator(
      store: store, seconds: Double((timings.last?.endMs ?? 0) + 1000) / 1000, transcribedText: raw, wordTimings: timings,
      speakerLabeler: { _, _ in .labeled(count: 2, segments: [
        SpeakerSegment(speakerId: "A", startMs: 0, endMs: firstCount * 50, quality: 1),
        SpeakerSegment(speakerId: "B", startMs: firstCount * 50 + 1000, endMs: (timings.last?.endMs ?? 0) + 10, quality: 1)
      ]) },
      processPartsOverride: { pieces, language, emit in
        if sentenceBoundary == false {
          #expect(pieces == (longFirstTurn ? [left, tail, b] : [a, b]))
        }
        try await processor.process(parts: pieces, engineLanguage: language) { index, outcome in
          let accepted = emit(index, outcome)
          if let state = observed?.state { progress.append(state) }
          return accepted
        }
      },
      beginRunOverride: {
        processor.freeze(settings: settings, vocabulary: nil)
        return FileImportCoordinator.RunConfiguration(
          polishIsCloud: true, localPolishProvider: nil, polishProvider: .openAI,
          ollamaModel: nil, polishModel: settings.llmModel, backendType: .parakeet)
      }, onEngineReleased: { processor.releaseCheckerSelections(); finished.fire() })
    observed = coordinator
    capture.onRequest = {
      guard let id = observed?.historyID else { Issue.record("missing durable History identity before cleanup"); return }
      #expect(store.current(id)?.text == raw)
    }
    coordinator.choose(url: Self.anyURL)
    try #require(await settleUntil { if case .ready = coordinator.state { return true }; return false })
    coordinator.start()
    try await BoundedWait.until(finished)
    let id = try #require(coordinator.historyID)
    let row = try #require(store.current(id))
    let turns = try #require(row.turns)
    func clean(_ text: String) -> String {
      let sentence = text.prefix(1).uppercased() + text.dropFirst()
      return sentenceBoundary && sentence.hasSuffix(".") ? sentence : sentence + "."
    }
    let expected = [longFirstTurn ? clean(left) + insideGap + clean(tail) : clean(a), clean(b)]
    let perPassRequests = longFirstTurn ? 2 : 1
    let expectedGaps = longFirstTurn ? [insideGap, "", ""] : ["", ""]
    let expectedProgress: [FileImportCoordinator.State] = longFirstTurn
      ? [.polishing(done: 1, total: 3), .polishing(done: 2, total: 3), .polishing(done: 3, total: 3)]
      : [.polishing(done: 1, total: 2), .polishing(done: 2, total: 2)]
    #expect(capture.requests == perPassRequests)
    #expect(capture.batches == 1)
    #expect(turns.map(\.speakerId) == ["A", "B"])
    #expect(turns.map(\.processedText) == expected.map(Optional.some))
    #expect(turns.allSatisfy { $0.wasPolished })
    #expect(coordinator.parts.map(\.turnID) == (longFirstTurn ? [turns[0].id, turns[0].id, turns[1].id] : turns.map(\.id)).map(Optional.some))
    #expect(coordinator.parts.map(\.trailingGap) == expectedGaps)
    #expect(progress == expectedProgress)
    #expect(row.polishedText == expected.joined(separator: "\n\n"))
    if sentenceBoundary {
      #expect(row.polishedText?.contains("Friday. \t \nPlease") == true,
        "#3859: saved output must retain the exact source separator after real cleanup")
    }
    let ids = turns.map(\.id)
    finished = BoundedWait.Signal(); progress = []
    coordinator.rePolish()
    try await BoundedWait.until(finished)
    let repeated = try #require(store.current(id)?.turns)
    #expect(capture.requests == perPassRequests * 2)
    #expect(capture.batches == 2)
    #expect(repeated.map(\.id) == ids)
    #expect(repeated.map(\.speakerId) == ["A", "B"])
    #expect(repeated.map(\.processedText) == expected.map(Optional.some))
    #expect(coordinator.parts.map(\.trailingGap) == expectedGaps)
    #expect(progress == expectedProgress)
    #expect(coordinator.state == .finished)
    if sentenceBoundary {
      #expect(store.current(id)?.polishedText?.contains("Friday. \t \nPlease") == true,
        "#3859: Clean it again must retain the exact source separator")
    }
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
        text: part, polishedText: swapped.joined(separator: " "))
    }
  }

  /// The two-speaker fixture's turns after `WordSwappingCleaner` with the given swaps:
  /// A "hello" and B "there friend" become (A, B).
  private static func swappedTurnTexts(_ swaps: [String: String]) -> (a: String, b: String) {
    (swaps["hello"]!, "there \(swaps["friend"]!)")
  }

  /// #4075 S1: waits for the coordinator's own settlement of a Stop's History writes.
  private func settleWrites(_ c: FileImportCoordinator) async -> Bool {
    await settleUntil { c.hasPendingSettlement == false }
  }

  private func turnTexts(_ row: Transcript?) -> [String?] {
    row?.turns?.map(\.processedText) ?? []
  }

  @Test("Clean it again re-cleans the same speaker sections and keeps an explicit rename (#2811, #2851)")
  func rePolishRecleansTheSameSectionsAndKeepsRename() async {
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
    #expect(realigned, "Clean it again must re-clean the stored turns' sections: \(turnTexts(store.current(historyID)))")
    #expect(store.current(historyID)?.turns?.count == 2, "a re-clean must not change the turn set")
    #expect(coordinator.pendingPieces == ["hello", "there friend"], "the sections are the turns")
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

  @Test("the turns are written once, cleaned, at Done; nothing before (#2851 follow-up)")
  func turnsAreWrittenOnceAtDone() async {
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
    #expect(await cleanupGate.waitUntilArrived(), "cleanupGate: the gated call never arrived")
    guard let historyID = coordinator.historyID else {
      Issue.record("no historyID once the cleanup is in flight")
      return
    }
    // The speaker step finishes before the first section is cleaned, and writes nothing.
    let awaited = await settleUntil { coordinator.speakerStepState == .finished }
    #expect(awaited, "the speaker step finishes before the first section is cleaned")
    #expect(store.current(historyID)?.turns == nil, "nothing is written before Done")
    #expect(telemetry.events.isEmpty, "the once-per-import event waits for the cleanup")
    #expect(coordinator.state != .finished)

    await cleanupGate.open()
    let finished = await settleUntil { coordinator.state == .finished }
    #expect(finished)
    let first = Self.swappedTurnTexts(WordSwappingCleaner.first)
    #expect(turnTexts(store.current(historyID)) == [first.a, first.b], "Done must follow the one write")
    #expect(telemetry.stored.count == 1, "exactly one stored event: \(telemetry.events)")
    #expect(telemetry.stored.first?.turnCount == 2)
    #expect(telemetry.stored.first?.fallback == 0)
  }

  @Test("the one write throwing is the import's one event (#2851 follow-up)")
  func theOneWriteThrowingIsTheOneEvent() async {
    let store = FakeHistoryStore()
    // There is ONE merge per run now, at Done. It throws.
    store.throwOnMergeCall = 1
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
    #expect(await cleanupGate.waitUntilArrived(), "cleanupGate: the gated call never arrived")
    guard let historyID = coordinator.historyID else {
      Issue.record("no historyID once the cleanup is in flight")
      return
    }
    await cleanupGate.open()
    let finished = await settleUntil { coordinator.state == .finished }
    #expect(finished)
    #expect(store.current(historyID)?.turns == nil, "the write threw")
    #expect(store.current(historyID)?.polishedText != nil, "the document text still lands")
    #expect(store.mergeCalls == 1, "merge calls: \(store.mergeCalls)")
    #expect(
      telemetry.events.map(\.outcome) == [.saveFailed],
      "one event per import: \(telemetry.events)")
  }

  @Test("History's settling question is true while the speaker step and the cleanup run, false at Done (#2851 §3 D)")
  func settlingCoversTheSpeakerStepAndTheCleanup() async {
    let store = FakeHistoryStore()
    let speakerGate = ManualGate()
    let coordinator = makeStoreBackedCoordinator(
      store: store, wordTimings: Self.twoSpeakerWordTimings(),
      speakerLabeler: { _, _ in
        await speakerGate.markArrived()
        await speakerGate.waitUntilOpen()
        return .labeled(count: 2, segments: Self.twoSpeakerSegments)
      },
      processPart: { part, _ in WordSwappingCleaner().outcome(part) })

    coordinator.choose(url: Self.anyURL)
    _ = await settleUntil {
      if case .ready = coordinator.state { return true } else { return false }
    }
    coordinator.start()
    #expect(await speakerGate.waitUntilArrived(), "speakerGate: the gated call never arrived")
    guard let historyID = coordinator.historyID else {
      Issue.record("no historyID once the speaker step is in flight")
      return
    }
    #expect(coordinator.isRunning, "the run waits on the speaker step")
    #expect(coordinator.isSettlingTurns, "the wizard's own document: still finding who said what")
    #expect(coordinator.isSettlingTurns(of: historyID), "History's row: the same answer")
    #expect(coordinator.isSettlingTurns(of: UUID()) == false)
    await speakerGate.open()
    let finished = await settleUntil { coordinator.state == .finished }
    #expect(finished)
    let first = Self.swappedTurnTexts(WordSwappingCleaner.first)
    #expect(turnTexts(store.current(historyID)) == [first.a, first.b])
    #expect(coordinator.isSettlingTurns == false, "written and finished: both screens may disclose")
    #expect(coordinator.isSettlingTurns(of: historyID) == false)
  }

  @Test("History's import-in-progress question reads true for this row while the cleanup runs, false for another row, false after Done (#2851 §3 D)")
  func importInProgressFollowsTheRunAndTheRow() async {
    // The expression the bootstrapper installs on `TranscriptCoordinator.isImportInProgress`,
    // against a real coordinator with its cleanup held at a gate.
    let store = FakeHistoryStore()
    let cleanupGate = ManualGate()
    let coordinator = makeStoreBackedCoordinator(
      store: store, wordTimings: Self.twoSpeakerWordTimings(),
      speakerLabeler: { _, _ in .labeled(count: 2, segments: Self.twoSpeakerSegments) },
      processPart: { part, _ in
        await cleanupGate.markArrived()
        await cleanupGate.waitUntilOpen()
        return WordSwappingCleaner().outcome(part)
      })
    let inProgress: @MainActor (UUID) -> Bool = { id in coordinator.isSettlingTurns(of: id) }

    coordinator.choose(url: Self.anyURL)
    _ = await settleUntil {
      if case .ready = coordinator.state { return true } else { return false }
    }
    coordinator.start()
    #expect(await cleanupGate.waitUntilArrived(), "cleanupGate: the gated call never arrived")
    guard let historyID = coordinator.historyID else {
      Issue.record("no historyID once the cleanup is in flight")
      return
    }
    #expect(store.current(historyID)?.turns == nil, "no raw turns are written mid-run any more")
    #expect(inProgress(historyID) == true, "this row's import is running")
    #expect(inProgress(UUID()) == false, "another row is not")

    await cleanupGate.open()
    let finished = await settleUntil { coordinator.state == .finished }
    #expect(finished)
    #expect(inProgress(historyID) == false, "Done: History may disclose")
  }

  @Test(
    "a labeled import whose polisher cannot start reports polisher_not_ready once, with the turns raw and disclosed (#2851)"
  )
  func polisherNotReadyIsTheTurnsTerminalOutcome() async {
    let store = FakeHistoryStore()
    let telemetry = TurnTelemetryRecorder()
    let coordinator = makeStoreBackedCoordinator(
      store: store, wordTimings: Self.twoSpeakerWordTimings(),
      speakerLabeler: { _, _ in .labeled(count: 2, segments: Self.twoSpeakerSegments) },
      emitTurnTelemetry: { telemetry.record($0, $1, $2) },
      prepareLocalPolish: { _ in false })

    coordinator.choose(url: Self.anyURL)
    _ = await settleUntil {
      if case .ready = coordinator.state { return true } else { return false }
    }
    coordinator.start()
    let rejected = await settleUntil { coordinator.state == .rejected(.polisherNotReady) }
    #expect(rejected)
    guard let historyID = coordinator.historyID else {
      Issue.record("no historyID after the rejection")
      return
    }
    let reported = await settleUntil {
      coordinator.speakerStepState == .finished && !telemetry.events.isEmpty
    }
    #expect(reported)
    for _ in 0..<20 { await Task.yield() }
    #expect(telemetry.events.map(\.outcome) == [.polisherNotReady], "\(telemetry.events)")
    #expect(turnTexts(store.current(historyID)) == [nil, nil], "the turns keep their raw words")
    #expect(
      store.current(historyID)?.turns?.map(\.wasPolished) == [false, false],
      "a cleanup that never reached the turns is disclosed on each of them")
    #expect(coordinator.isRunning == false, "the rejection is terminal, so History may disclose")
  }

  @Test("Done waits for the speaker step, and the one stored event follows the write (#2851 follow-up)")
  func doneWaitsForTheSpeakerStep() async {
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
    #expect(await speakerGate.waitUntilArrived(), "speakerGate: the gated call never arrived")
    guard let historyID = coordinator.historyID else {
      Issue.record("no historyID once the speaker step is in flight")
      return
    }
    #expect(coordinator.state != .finished, "Done waits for the speaker step")
    #expect(store.current(historyID)?.turns == nil)
    #expect(telemetry.stored.isEmpty, "nothing to report before the turns exist")

    await speakerGate.open()
    let finished = await settleUntil { coordinator.state == .finished }
    #expect(finished)
    let first = Self.swappedTurnTexts(WordSwappingCleaner.first)
    #expect(turnTexts(store.current(historyID)) == [first.a, first.b], "\(turnTexts(store.current(historyID)))")
    #expect(telemetry.stored.count == 1, "exactly one stored event: \(telemetry.events)")
    #expect(telemetry.stored.first?.turnCount == 2)
    #expect(telemetry.stored.first?.fallback == 0)
  }

  /// `count` words "w0 w1 ...", one every 100 ms, speaker A for the first `split` words and
  /// B for the rest: two turns, one cleanup section each while both stay under the run's
  /// part ceiling (`TranscriptSplitter.maximumWordsPerLocalPart` for the fixtures' EG-1
  /// polisher); a `split` over the ceiling makes A's turn several sections sharing one turn
  /// id.
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

  @Test("Clean it again keeps the previous document until Done, then writes the new sections once (#2851 follow-up)")
  func rePolishKeepsThePreviousDocumentUntilDone() async {
    let store = FakeHistoryStore()
    let secondRunGate = ManualGate()
    let fixture = Self.manyWordFixture(count: 300, split: 150)
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
        // The second run rewrites the first word of each section, so its text is told apart.
        let cleaned = index == 0 ? part : "again " + part
        return FileImportRunner.PartOutcome(text: part, polishedText: cleaned)
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
    let firstRunTexts = turnTexts(store.current(historyID))
    #expect(firstRunTexts.allSatisfy { $0 != nil })

    tracker.secondRun = true
    coordinator.rePolish()
    #expect(await secondRunGate.waitUntilArrived(), "secondRunGate: the gated call never arrived")
    // Section 1 of the second run has landed in memory; section 2 is held. Nothing has
    // been written: the row still shows the first run's document.
    #expect(coordinator.state == .polishing(done: 1, total: 2))
    #expect(turnTexts(store.current(historyID)) == firstRunTexts, "the previous document stays until Done")

    await secondRunGate.open()
    let finished = await settleUntil { coordinator.state == .finished }
    #expect(finished)
    let texts = turnTexts(store.current(historyID))
    #expect(texts.first??.hasPrefix("again w0 ") == true)
    #expect(texts.last??.hasPrefix("again w150 ") == true, "each section is its own part")
  }

  @Test("each section is one cleanup part carrying its turn id; the turns are written once at Done (#2851 follow-up)")
  func eachSectionIsOnePartCarryingItsTurnID() async {
    let store = FakeHistoryStore()
    let secondPartGate = ManualGate()
    let fixture = Self.manyWordFixture(count: 300, split: 150)
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
        return FileImportRunner.PartOutcome(text: part, polishedText: part)
      })

    coordinator.choose(url: Self.anyURL)
    _ = await settleUntil {
      if case .ready = coordinator.state { return true } else { return false }
    }
    coordinator.start()
    #expect(await secondPartGate.waitUntilArrived(), "secondPartGate: the gated call never arrived")
    #expect(coordinator.pendingPieces.count == 2, "two turns, two sections")
    guard let historyID = coordinator.historyID else {
      Issue.record("no historyID once the second part is in flight")
      return
    }
    #expect(coordinator.parts.count == 1)
    #expect(coordinator.parts.first?.turnID != nil, "a section carries its turn id")
    #expect(store.current(historyID)?.turns == nil, "nothing is written before Done")
    #expect(coordinator.state == .polishing(done: 1, total: 2))

    await secondPartGate.open()
    let finished = await settleUntil { coordinator.state == .finished }
    #expect(finished)
    let texts = turnTexts(store.current(historyID))
    #expect(texts.count == 2)
    #expect(texts[0] == (0..<150).map { "w\($0)" }.joined(separator: " "))
    #expect(texts[1] == (150..<300).map { "w\($0)" }.joined(separator: " "))
  }

  /// The part ceiling follows the run's polisher: a cloud polisher is bound by the request,
  /// an on-device one by the words (15 s budget; 470-word parts timed out on a fast Mac).
  @Test("the part ceiling is the local one for an on-device polisher and the default for cloud")
  func partCeilingFollowsThePolisher() {
    let local = FileImportCoordinator.RunConfiguration(
      polishIsCloud: false, localPolishProvider: .egOne, polishProvider: .egOne,
      ollamaModel: nil, polishModel: "eg-1", backendType: .parakeet)
    let cloud = FileImportCoordinator.RunConfiguration(
      polishIsCloud: true, localPolishProvider: nil, polishProvider: .openAI,
      ollamaModel: nil, polishModel: "gpt-4o-mini", backendType: .parakeet)
    #expect(FileImportDocumentMath.partCeiling(local) == TranscriptSplitter.maximumWordsPerLocalPart)
    #expect(FileImportDocumentMath.partCeiling(cloud) == TranscriptSplitter.maximumWordsPerPart)
    #expect(FileImportDocumentMath.partCeiling(nil) == TranscriptSplitter.maximumWordsPerPart)
    let none = FileImportCoordinator.RunConfiguration(
      polishIsCloud: false, localPolishProvider: nil, polishProvider: .none,
      ollamaModel: nil, polishModel: "", backendType: .parakeet)
    #expect(FileImportDocumentMath.partCeiling(none) == TranscriptSplitter.maximumWordsPerPart)
  }

  /// With no turns and a local polisher, a 600-word memo is cut at the local ceiling.
  @Test("a single-speaker memo is cut at the local ceiling for an on-device polisher")
  func singleSpeakerMemoUsesTheLocalCeiling() {
    let text = (0..<600).map { "w\($0)" }.joined(separator: " ")
    let cut = FileImportDocumentMath.cleanupPieces(
      turns: nil, rawText: text, maximumWords: TranscriptSplitter.maximumWordsPerLocalPart)
    #expect(cut.pieces.count == 3)
    #expect(cut.pieces.map { TranscriptSplitter.wordCount(in: $0) } == [200, 200, 200])
    let wide = FileImportDocumentMath.cleanupPieces(turns: nil, rawText: text)
    #expect(wide.pieces.count == 2)
  }

  @Test("a turn over the splitter's ceiling becomes several parts sharing its id, joined back into one turn (#2851 follow-up)")
  func anOverlongTurnIsSeveralPartsWithOneTurnID() async {
    let store = FakeHistoryStore()
    // One speaker for all 600 words: a single turn over `maximumWordsPerPart`.
    let fixture = Self.manyWordFixture(count: 600, split: 600)
    let coordinator = makeStoreBackedCoordinator(
      store: store, transcribedText: fixture.text, wordTimings: fixture.timings,
      speakerLabeler: { _, _ in .labeled(count: 2, segments: fixture.segments) },
      processPart: { part, _ in
        FileImportRunner.PartOutcome(text: part, polishedText: "clean " + part)
      })

    coordinator.choose(url: Self.anyURL)
    _ = await settleUntil {
      if case .ready = coordinator.state { return true } else { return false }
    }
    coordinator.start()
    let finished = await settleUntil { coordinator.state == .finished }
    #expect(finished)
    guard let historyID = coordinator.historyID else {
      Issue.record("no historyID after the visible run finished")
      return
    }
    #expect(coordinator.parts.count >= 2, "600 words must split: \(coordinator.parts.count)")
    #expect(Set(coordinator.parts.compactMap(\.turnID)).count == 1, "every part carries the one turn's id")
    let turns = store.current(historyID)?.turns
    #expect(turns?.count == 1)
    #expect(turns?.first?.wasPolished == true)
    #expect(turns?.first?.processedText?.hasPrefix("clean w0 ") == true)
    #expect(turns?.first?.processedText?.contains(" clean w") == true, "the parts are joined in order, with the raw gap between them")
    #expect(turns?.first?.processedText?.hasSuffix("w599") == true)
  }

  @Test("Stop mid-cleanup keeps the finished sections on screen, writes the turns raw as stopped, and reaches Done once (#2851 follow-up)")
  func stopMidCleanupWritesTheTurnsAsStopped() async {
    let store = FakeHistoryStore()
    let secondPartGate = ManualGate()
    let telemetry = TurnTelemetryRecorder()
    @MainActor final class PartCounter {
      private(set) var count = 0
      func next() -> Int {
        count += 1
        return count
      }
    }
    let partsSeen = PartCounter()
    let coordinator = makeStoreBackedCoordinator(
      store: store, wordTimings: Self.twoSpeakerWordTimings(),
      speakerLabeler: { _, _ in .labeled(count: 2, segments: Self.twoSpeakerSegments) },
      processPart: { part, _ in
        if partsSeen.next() == 2 {
          await secondPartGate.markArrived()
          await secondPartGate.waitUntilOpen()
        }
        return FileImportRunner.PartOutcome(text: part, polishedText: "clean " + part)
      },
      emitTurnTelemetry: { telemetry.record($0, $1, $2) })

    coordinator.choose(url: Self.anyURL)
    _ = await settleUntil {
      if case .ready = coordinator.state { return true } else { return false }
    }
    coordinator.start()
    #expect(await secondPartGate.waitUntilArrived(), "secondPartGate: the gated call never arrived")
    guard let historyID = coordinator.historyID else {
      Issue.record("no historyID once the second section is in flight")
      return
    }
    #expect(coordinator.parts.count == 1)
    coordinator.stop()
    #expect(coordinator.state == .stopped)
    #expect(coordinator.step == .done)
    #expect(coordinator.parts.count == 1, "the finished section stays")
    let written = await settleUntil { store.current(historyID)?.turns != nil }
    #expect(written, "the labels found before the Stop are written")
    #expect(turnTexts(store.current(historyID)) == [nil, nil], "a Stop writes the turns raw")
    #expect(store.current(historyID)?.turns?.map(\.wasPolished) == [false, false], "and disclosed")
    #expect(telemetry.events.map(\.outcome) == [.stopped], "\(telemetry.events)")
    #expect(store.current(historyID)?.polishedText == nil, "no polished document on a Stop")
    #expect(coordinator.isSavedToHistory, "the raw labeled document on screen is the saved one")
    await secondPartGate.open()
    for _ in 0..<20 { await Task.yield() }
    #expect(coordinator.state == .stopped, "a late part cannot finish a stopped run")
    #expect(store.mergeCalls == 1)
  }

  /// What a completed first cleanup left everywhere the user can read it (#3903).
  private struct CleanupSeen: Equatable {
    let historyTurns: [String?]
    let historyPolished: [Bool]?
    let partTexts: [String]
    let documentText: String
    let exportText: String
    let saved: Bool
    let provider: LLMProvider?

    @MainActor init(_ c: FileImportCoordinator, _ store: FakeHistoryStore, _ id: UUID) {
      let row = store.current(id)
      historyTurns = row?.turns?.map(\.processedText) ?? []
      historyPolished = row?.turns?.map(\.wasPolished)
      partTexts = c.parts.map(\.text)
      documentText = c.documentText
      exportText = c.exportText
      saved = c.isSavedToHistory
      provider = c.runConfiguration?.polishProvider
    }
  }

  /// A labeled or single-voice import cleaned once ("first ..."), then Clean it again under a
  /// different polisher ("second ..."), which `gateAt` holds at one of its parts.
  @MainActor private final class ReRunScript {
    var calls = 0
    var firstRunCalls = 0
    var gateAt: Int?
    var rerun = false
    var polisherReadyOnRerun = true
    /// Presses Stop from inside the re-run's History turn write, the moment the merge lands.
    var stopInsideRerunMerge = false
    /// The re-run polishes to the SAME words as the first run, under a different provider.
    var sameWordsOnRerun = false
    /// How many document updates (`updateHistoryRow`) still fail.
    var failingUpdates = 0
    weak var coordinator: FileImportCoordinator?
    let gate = ManualGate()
    /// #4075 S1: holds the next History merge or document update until released, like a
    /// write already sent: the waiting caller being cancelled does not withdraw it.
    var holdNextMerge = false
    var holdNextUpdate = false
    private var heldWrite: CheckedContinuation<Void, Never>?
    var isHoldingWrite: Bool { heldWrite != nil }
    /// The order merges, updates and polisher preparation actually ran in.
    private(set) var events: [String] = []
    func note(_ event: String) { events.append(event) }

    func holdIfArmed(merge: Bool) async {
      if merge ? holdNextMerge : holdNextUpdate {
        if merge { holdNextMerge = false } else { holdNextUpdate = false }
        await withCheckedContinuation { heldWrite = $0 }
      }
    }

    func releaseHeldWrite() {
      holdNextMerge = false
      holdNextUpdate = false
      let held = heldWrite
      heldWrite = nil
      held?.resume()
    }
  }

  private func makeReRunCoordinator(
    _ script: ReRunScript, store: FakeHistoryStore, labeled: Bool,
    telemetry: TurnTelemetryRecorder
  ) -> FileImportCoordinator {
    let c = makeCoordinator(
      lease: EngineLease(), transcribedText: "hello there friend",
      wordTimings: labeled ? Self.twoSpeakerWordTimings() : nil,
      speakerLabeler: { _, _ in
        labeled ? .labeled(count: 2, segments: Self.twoSpeakerSegments) : .single(segments: [])
      },
      saveToHistory: { store.save($0) },
      updateHistoryRow: { row in
        await script.holdIfArmed(merge: false)
        script.note("update")
        if script.failingUpdates > 0 {
          script.failingUpdates -= 1
          throw FakeHistoryStore.MergeError()
        }
        return store.update(row)
      },
      mergeSpeakerFields: { id, analysis, turns in
        await script.holdIfArmed(merge: true)
        script.note("merge")
        let saved = try store.mergeSpeakerFields(id, analysis, turns)
        if script.rerun, script.stopInsideRerunMerge {
          script.stopInsideRerunMerge = false
          script.coordinator?.stop()
        }
        return saved
      },
      writeExplicitRename: { store.rename($0, $1, $2, $3) },
      currentHistoryRow: { store.current($0) },
      historyRowExists: { store.current($0) != nil },
      emitTurnTelemetry: { telemetry.record($0, $1, $2) },
      prepareLocalPolish: { _ in
        script.note("prepare")
        return script.rerun ? script.polisherReadyOnRerun : true
      },
      processPart: { part, _ in
        script.calls += 1
        if script.calls == script.gateAt {
          await script.gate.markArrived()
          await script.gate.waitUntilOpen()
        }
        return FileImportRunner.PartOutcome(
          text: part,
          polishedText: (script.rerun && !script.sameWordsOnRerun ? "second " : "first ") + part)
      },
      beginRunOverride: {
        FileImportCoordinator.RunConfiguration(
          polishIsCloud: true, localPolishProvider: nil,
          polishProvider: script.rerun ? .gemini : .openAI, ollamaModel: nil,
          polishModel: script.rerun ? "second-model" : "first-model", backendType: .parakeet)
      })
    script.coordinator = c
    return c
  }

  /// Runs the first cleanup to Done and returns what it left.
  private func completeFirstCleanup(
    _ c: FileImportCoordinator, _ store: FakeHistoryStore, _ script: ReRunScript
  ) async -> (UUID, CleanupSeen)? {
    c.choose(url: Self.anyURL)
    _ = await settleUntil {
      if case .ready = c.state { return true } else { return false }
    }
    c.start()
    guard await settleUntil({ c.state == .finished }), let id = c.historyID else {
      Issue.record("the first cleanup never finished")
      return nil
    }
    _ = await settleUntil { c.speakerStepState == .finished }
    script.firstRunCalls = script.calls
    script.rerun = true
    return (id, CleanupSeen(c, store, id))
  }

  @Test(
    "Stop during Clean it again keeps the completed cleanup everywhere: History turns, screen, Copy and Save, badge and header (#3903)",
    // A single-voice document of this fixture is one section, so "one section finished" is
    // a labeled (two-section) case only.
    arguments: [(true, 0), (true, 1), (false, 0)])
  func stopDuringCleanItAgainKeepsTheCompletedCleanup(labeled: Bool, finishedBeforeStop: Int)
    async
  {
    let store = FakeHistoryStore()
    let telemetry = TurnTelemetryRecorder()
    let script = ReRunScript()
    let c = makeReRunCoordinator(script, store: store, labeled: labeled, telemetry: telemetry)
    guard let (id, first) = await completeFirstCleanup(c, store, script) else { return }
    #expect(first.partTexts.allSatisfy { $0.hasPrefix("first ") }, "\(first.partTexts)")
    #expect(first.saved)
    if labeled {
      #expect(first.historyTurns.allSatisfy { $0?.hasPrefix("first ") == true })
    }
    let eventsAfterFirst = telemetry.events.count
    let mergesAfterFirst = store.mergeCalls
    // Gate the replacement's first part (nothing replaced yet) or its second part (one
    // replacement section already finished).
    script.gateAt = script.firstRunCalls + 1 + finishedBeforeStop
    if finishedBeforeStop == 1, first.partTexts.count < 2 {
      Issue.record("the fixture needs at least two sections")
      return
    }
    c.rePolish()
    #expect(await script.gate.waitUntilArrived(), "the replacement run never reached its gate")
    #expect(c.parts.count == finishedBeforeStop)
    c.stop()
    #expect(c.state == .stopped)
    #expect(c.step == .done)
    #expect(await settleWrites(c), "the Stop's History writes never settled")
    let after = CleanupSeen(c, store, id)
    #expect(
      after == first, "labeled \(labeled), finished \(finishedBeforeStop): \(after) vs \(first)")
    #expect(!after.partTexts.contains { $0.hasPrefix("second ") }, "never two generations mixed")
    #expect(store.mergeCalls == mergesAfterFirst, "no raw turns were written over the cleanup")
    #expect(telemetry.events.count == eventsAfterFirst, "the first run already reported the turns")
    await script.gate.open()
    #expect(await settleWrites(c), "the Stop's History writes never settled")
    #expect(CleanupSeen(c, store, id) == first, "a late replacement part changes nothing")
  }

  @Test(
    "a polisher that does not start for Clean it again keeps the completed cleanup (#3903)",
    arguments: [true, false])
  func refusedPolisherDuringCleanItAgainKeepsTheCompletedCleanup(labeled: Bool) async {
    let store = FakeHistoryStore()
    let telemetry = TurnTelemetryRecorder()
    let script = ReRunScript()
    let c = makeReRunCoordinator(script, store: store, labeled: labeled, telemetry: telemetry)
    guard let (id, first) = await completeFirstCleanup(c, store, script) else { return }
    let mergesAfterFirst = store.mergeCalls
    script.polisherReadyOnRerun = false
    c.rePolish()
    #expect(await settleUntil { c.state == .rejected(.polisherNotReady) })
    #expect(await settleWrites(c), "the Stop's History writes never settled")
    #expect(CleanupSeen(c, store, id) == first, "labeled \(labeled)")
    #expect(store.mergeCalls == mergesAfterFirst, "no raw turns were written over the cleanup")
  }

  @Test(
    "a Stop while a completed Clean it again writes its turns keeps that NEW cleanup (#3903, Codex)",
    arguments: [true, false])
  func stopDuringTheReRunsHistoryWriteKeepsTheNewCleanup(labeled: Bool) async {
    let store = FakeHistoryStore()
    let telemetry = TurnTelemetryRecorder()
    let script = ReRunScript()
    let c = makeReRunCoordinator(script, store: store, labeled: labeled, telemetry: telemetry)
    guard let (id, _) = await completeFirstCleanup(c, store, script) else { return }
    script.stopInsideRerunMerge = true
    c.rePolish()
    #expect(await settleUntil { c.state == .stopped }, "the Stop inside the write never landed")
    #expect(await settleWrites(c), "the Stop's History writes never settled")
    let after = CleanupSeen(c, store, id)
    #expect(after.partTexts.allSatisfy { $0.hasPrefix("second ") }, "\(after.partTexts)")
    if labeled {
      #expect(
        after.historyTurns.allSatisfy { $0?.hasPrefix("second ") == true }, "\(after.historyTurns)")
    }
    #expect(after.provider == .gemini, "the header credits the cleanup on screen")
    #expect(
      store.current(id)?.displayText == c.documentText,
      "History's text and the screen describe the same cleanup")
    #expect(after.saved)
  }

  @Test(
    "the same words under a new provider: a Stop during the re-run's write still saves the new credit (#3903)",
    arguments: [true, false])
  func stopDuringTheWriteSavesTheNewCreditForTheSameWords(labeled: Bool) async {
    let store = FakeHistoryStore()
    let telemetry = TurnTelemetryRecorder()
    let script = ReRunScript()
    script.sameWordsOnRerun = true
    let c = makeReRunCoordinator(script, store: store, labeled: labeled, telemetry: telemetry)
    guard let (id, first) = await completeFirstCleanup(c, store, script) else { return }
    #expect(store.current(id)?.llmProvider == LLMProvider.openAI.rawValue)
    script.stopInsideRerunMerge = true
    c.rePolish()
    #expect(await settleUntil { c.state == .stopped })
    #expect(await settleWrites(c), "the Stop's History writes never settled")
    #expect(c.documentText == first.documentText, "the same words")
    #expect(c.runConfiguration?.polishProvider == .gemini, "the screen credits the re-run")
    #expect(
      store.current(id)?.llmProvider == LLMProvider.gemini.rawValue,
      "History credits the same cleanup the screen does")
    #expect(store.current(id)?.llmModel == "second-model")
  }

  @Test(
    "a row the user deleted and Clean it again wrote back gets the kept cleanup saved again on Stop (#3903, Codex)",
    arguments: [true, false])
  func stopAfterTheRowWasWrittenAgainSavesTheKeptCleanup(labeled: Bool) async {
    let store = FakeHistoryStore()
    let telemetry = TurnTelemetryRecorder()
    let script = ReRunScript()
    let c = makeReRunCoordinator(script, store: store, labeled: labeled, telemetry: telemetry)
    guard let (id, first) = await completeFirstCleanup(c, store, script) else { return }
    store.delete(id)
    c.noteHistoryRowDeleted(id)
    script.gateAt = script.firstRunCalls + 1
    c.rePolish()
    #expect(await script.gate.waitUntilArrived(), "the re-run never reached its first part")
    #expect(store.current(id)?.text != nil, "Clean it again wrote the raw row back")
    c.stop()
    #expect(await settleWrites(c), "the Stop's History writes never settled")
    #expect(c.documentText == first.documentText, "the screen shows the kept cleanup")
    #expect(
      store.current(id)?.displayText == c.documentText,
      "History holds the kept cleanup again, not the raw words")
    #expect(store.current(id)?.llmProvider == LLMProvider.openAI.rawValue)
    await script.gate.open()
  }

  @Test(
    "a later cleanup whose turn save failed is the one restored, turns included, on the next Stop (#3903, Codex)"
  )
  func stopAfterACleanupWhoseTurnSaveFailedRestoresItsTurns() async {
    let store = FakeHistoryStore()
    let telemetry = TurnTelemetryRecorder()
    let script = ReRunScript()
    let c = makeReRunCoordinator(script, store: store, labeled: true, telemetry: telemetry)
    guard let (id, _) = await completeFirstCleanup(c, store, script) else { return }
    // Cleanup B completes, but its turn save fails: History keeps A's turns.
    store.throwOnMergeCall = store.mergeCalls + 1
    c.rePolish()
    #expect(await settleUntil { c.state == .finished }, "cleanup B never finished")
    #expect(turnTexts(store.current(id)).allSatisfy { $0?.hasPrefix("first ") == true })
    let b = c.documentText
    // Cleanup C is stopped before its first part: B is the kept cleanup.
    script.gateAt = script.calls + 1
    c.rePolish()
    #expect(await script.gate.waitUntilArrived())
    c.stop()
    #expect(await settleWrites(c), "the Stop's History writes never settled")
    #expect(c.documentText == b, "the screen shows cleanup B")
    #expect(
      turnTexts(store.current(id)).allSatisfy { $0?.hasPrefix("second ") == true },
      "History's turns are cleanup B's too: \(turnTexts(store.current(id)))")
    #expect(c.turns?.map(\.processedText) == turnTexts(store.current(id)), "the screen reads them")
    #expect(store.current(id)?.llmProvider == LLMProvider.gemini.rawValue)
    await script.gate.open()
  }

  // MARK: - #4075 S1: awaited cleaned and speaker writes, and the Stop settlement

  /// The finished run's two writes are awaited: Done, and a saved badge, come only after
  /// each settles, and a failed document update reads as a failure, not as saved.
  @Test("a run's held speaker write or document update keeps it off Done until it settles")
  func heldFinalWritesKeepTheRunOffDone() async throws {
    for (holdMerge, updateFails) in [(true, false), (false, false), (false, true)] {
      let store = FakeHistoryStore()
      let script = ReRunScript()
      defer { script.releaseHeldWrite() }
      let c = makeReRunCoordinator(
        script, store: store, labeled: true, telemetry: TurnTelemetryRecorder())
      if holdMerge { script.holdNextMerge = true } else { script.holdNextUpdate = true }
      if updateFails { script.failingUpdates = 1 }
      c.choose(url: Self.anyURL)
      try #require(
        await settleUntil {
          if case .ready = c.state { return true } else { return false }
        })
      c.start()
      try #require(await settleUntil { script.isHoldingWrite }, "the write never arrived")
      #expect(c.state != .finished, "the run reached Done before its write settled")
      #expect(c.isSettlingRunPersistence)
      #expect(c.isSavedToHistory == false)
      script.releaseHeldWrite()
      try #require(await settleUntil { c.state == .finished }, "the run never finished")
      #expect(c.isSettlingRunPersistence == false)
      if updateFails {
        #expect(c.historySaveFailure != nil)
        #expect(c.isSavedToHistory == false)
      } else {
        #expect(c.historySaveFailure == nil)
        #expect(c.isSavedToHistory)
      }
    }
  }

  /// A Stop while the finished run's document update waits: the screen stops at once, the
  /// run never reaches Done, and the stopped document's History row still ends up holding it.
  @Test("a Stop while the final document update waits stops at once and the row still lands")
  func stopDuringHeldFinalUpdate() async throws {
    let store = FakeHistoryStore()
    let script = ReRunScript()
    defer { script.releaseHeldWrite() }
    let c = makeReRunCoordinator(
      script, store: store, labeled: true, telemetry: TurnTelemetryRecorder())
    script.holdNextUpdate = true
    c.choose(url: Self.anyURL)
    try #require(
      await settleUntil {
        if case .ready = c.state { return true } else { return false }
      })
    c.start()
    try #require(await settleUntil { script.isHoldingWrite }, "the update never arrived")
    let id = try #require(c.historyID)
    let shown = c.documentText
    c.stop()
    #expect(c.state == .stopped)
    #expect(c.documentText == shown, "the completed cleanup stays on screen")
    try #require(
      await settleUntil { store.current(id)?.displayText == shown },
      "the stopped document's row never received its cleanup")
    script.releaseHeldWrite()
    try #require(await settleUntil { c.isEngineHeld == false }, "the stopped run never ended")
    #expect(c.state == .stopped, "the stopped run reached Done after all")
    #expect(c.isSavedToHistory)
  }

  #if DEBUG
  /// A Stop's restoration shows the kept cleanup at once while its History writes settle
  /// behind it; a rename pressed meanwhile waits for them and then lands.
  @Test("a Stop's restoration shows at once, settles its writes, and a rename waits for them")
  func restorationSettlesAndRenameWaits() async throws {
    let store = FakeHistoryStore()
    let script = ReRunScript()
    defer { script.releaseHeldWrite() }
    let c = makeReRunCoordinator(
      script, store: store, labeled: true, telemetry: TurnTelemetryRecorder())
    guard let (id, _) = await completeFirstCleanup(c, store, script) else { return }
    // Cleanup B completes but its turn save fails, so restoring B must write its turns.
    store.throwOnMergeCall = store.mergeCalls + 1
    c.rePolish()
    try #require(await settleUntil { c.state == .finished }, "cleanup B never finished")
    let b = c.documentText
    script.gateAt = script.calls + 1
    c.rePolish()
    try #require(await script.gate.waitUntilArrived(), "cleanup C never reached its first part")
    script.holdNextMerge = true
    c.stop()
    #expect(c.documentText == b, "the kept cleanup is not on screen at once")
    // The screen and Copy read cleanup B's turns at once, before History holds them.
    #expect(
      c.turns?.allSatisfy { $0.processedText?.hasPrefix("second ") == true } == true,
      "the screen does not show cleanup B's turns yet: \(c.turns?.map(\.processedText) as Any)")
    #expect(turnTexts(store.current(id)).allSatisfy { $0?.hasPrefix("first ") == true })
    try #require(await settleUntil { script.isHoldingWrite }, "the restoration never wrote")
    #expect(c.isSavedToHistory == false, "the badge claims writes that have not settled")
    let waitsBefore = c.settlementWaitsForTesting
    let namesBefore = store.current(id)?.speakerNames
    let rename = Task { @MainActor in await c.renameSpeaker(id: "A", name: "Zach") }
    try #require(
      await settleUntil { c.settlementWaitsForTesting == waitsBefore + 1 },
      "the rename never reached the settlement")
    #expect(store.current(id)?.speakerNames == namesBefore, "the rename wrote before the Stop's")
    script.releaseHeldWrite()
    let failure = await rename.value
    #expect(failure == nil)
    #expect(
      turnTexts(store.current(id)).allSatisfy { $0?.hasPrefix("second ") == true },
      "History's turns are not cleanup B's: \(turnTexts(store.current(id)))")
    #expect(store.current(id)?.speakerNames?["A"] == "Zach", "the rename was lost")
    try #require(await settleWrites(c))
    #expect(c.isSavedToHistory)
    await script.gate.open()
  }

  /// A rename pressed on a stopped document waits for its settlement; if another file is
  /// chosen meanwhile, the rename sends nothing at all, to either file.
  @Test("a rename waiting on a Stop's writes sends nothing if another file is chosen")
  func renameAfterReplacementDuringSettlementSendsNothing() async throws {
    let store = FakeHistoryStore()
    let script = ReRunScript()
    defer { script.releaseHeldWrite() }
    let c = makeReRunCoordinator(
      script, store: store, labeled: true, telemetry: TurnTelemetryRecorder())
    guard let (id, _) = await completeFirstCleanup(c, store, script) else { return }
    store.throwOnMergeCall = store.mergeCalls + 1
    c.rePolish()
    try #require(await settleUntil { c.state == .finished }, "cleanup B never finished")
    script.gateAt = script.calls + 1
    c.rePolish()
    try #require(await script.gate.waitUntilArrived(), "cleanup C never reached its first part")
    script.holdNextMerge = true
    c.stop()
    try #require(await settleUntil { script.isHoldingWrite }, "the restoration never wrote")
    let waitsBefore = c.settlementWaitsForTesting
    let rename = Task { @MainActor in await c.renameSpeaker(id: "A", name: "Zach") }
    try #require(
      await settleUntil { c.settlementWaitsForTesting == waitsBefore + 1 },
      "the rename never reached the settlement")
    await script.gate.open()
    try #require(await settleUntil { c.isEngineHeld == false }, "cleanup C never ended")
    c.choose(url: URL(fileURLWithPath: "/tmp/replacement.m4a"))
    script.releaseHeldWrite()
    let failure = await rename.value
    #expect(failure?.message == RenameFailure.couldNotSaveName)
    try #require(await settleWrites(c))
    #expect(store.current(id)?.speakerNames?["A"] != "Zach", "the rename reached the old row")
    #expect(c.historyID == nil, "the new file took the old row's identity")
  }

  /// Clean it again on the same document after a Stop starts only after the Stop's writes
  /// for that row settle; another file chosen meanwhile is untouched by them.
  @Test("Clean it again after a Stop waits for its writes, and a new file is left alone by them")
  func reCleanWaitsForSettlementAndReplacementIsUntouched() async throws {
    for replace in [false, true] {
      let store = FakeHistoryStore()
      let script = ReRunScript()
      defer { script.releaseHeldWrite() }
      let c = makeReRunCoordinator(
        script, store: store, labeled: true, telemetry: TurnTelemetryRecorder())
      guard let (id, _) = await completeFirstCleanup(c, store, script) else { return }
      store.throwOnMergeCall = store.mergeCalls + 1
      c.rePolish()
      try #require(await settleUntil { c.state == .finished }, "cleanup B never finished")
      script.gateAt = script.calls + 1
      c.rePolish()
      try #require(await script.gate.waitUntilArrived(), "cleanup C never reached its first part")
      script.holdNextMerge = true
      c.stop()
      try #require(await settleUntil { script.isHoldingWrite }, "the restoration never wrote")
      await script.gate.open()
      try #require(await settleUntil { c.isEngineHeld == false }, "cleanup C never ended")
      let eventsBefore = script.events.count
      if replace {
        c.choose(url: URL(fileURLWithPath: "/tmp/replacement.m4a"))
        try #require(
          await settleUntil {
            if case .ready = c.state { return true } else { return false }
          })
        let revisionBefore = c.speakerFieldsRevision
        script.releaseHeldWrite()
        try #require(await settleWrites(c), "the Stop's writes never settled")
        #expect(
          turnTexts(store.current(id)).allSatisfy { $0?.hasPrefix("second ") == true },
          "the old row never received its restored turns")
        #expect(c.historyID == nil, "the new file took the old row's identity")
        #expect(c.historySaveFailure == nil)
        #expect(c.speakerFieldsRevision == revisionBefore)
        #expect(c.file?.name == "replacement.m4a")
      } else {
        c.rePolish()
        #expect(c.isRunning)
        script.releaseHeldWrite()
        try #require(await settleUntil { c.state == .finished }, "Clean it again never finished")
        let after = Array(script.events[eventsBefore...])
        let firstPrepare = try #require(after.firstIndex(of: "prepare"))
        let firstMerge = try #require(after.firstIndex(of: "merge"))
        #expect(firstMerge < firstPrepare, "Clean it again ran before the Stop's write: \(after)")
      }
    }
  }
  #endif


  @Test("when restoring cannot write the turns either, the screen shows the kept turns, unsaved (#3903)")
  func restoreWhoseTurnWriteFailsShowsTheKeptTurnsUnsaved() async {
    let store = FakeHistoryStore()
    let telemetry = TurnTelemetryRecorder()
    let script = ReRunScript()
    let c = makeReRunCoordinator(script, store: store, labeled: true, telemetry: telemetry)
    guard let (id, _) = await completeFirstCleanup(c, store, script) else { return }
    // B's turn save fails, and so does the restore's write on C's Stop.
    store.throwOnMergeCall = store.mergeCalls + 1
    store.alsoThrowOnMergeCall = store.mergeCalls + 2
    c.rePolish()
    #expect(await settleUntil { c.state == .finished })
    let b = c.documentText
    script.gateAt = script.calls + 1
    c.rePolish()
    #expect(await script.gate.waitUntilArrived())
    c.stop()
    #expect(await settleWrites(c), "the Stop's History writes never settled")
    #expect(c.documentText == b)
    #expect(
      c.turns?.allSatisfy { $0.processedText?.hasPrefix("second ") == true } == true,
      "the screen and Copy show cleanup B's turns: \(c.turns?.map(\.processedText) as Any)")
    #expect(turnTexts(store.current(id)).allSatisfy { $0?.hasPrefix("first ") == true })
    #expect(!c.isSavedToHistory, "the badge does not claim History holds what is on screen")
    await script.gate.open()
  }

  @Test("a restored cleanup whose document save fails again is not shown as saved (#3903, Codex)")
  func restoredCleanupWhoseSaveFailsIsNotShownAsSaved() async {
    let store = FakeHistoryStore()
    let telemetry = TurnTelemetryRecorder()
    let script = ReRunScript()
    // The first cleanup's document update fails (its turns save), and so does the retry.
    script.failingUpdates = 2
    let c = makeReRunCoordinator(script, store: store, labeled: true, telemetry: telemetry)
    guard let (id, first) = await completeFirstCleanup(c, store, script) else { return }
    #expect(!first.saved, "the first cleanup's document never reached History")
    script.gateAt = script.calls + 1
    c.rePolish()
    #expect(await script.gate.waitUntilArrived())
    c.stop()
    #expect(await settleWrites(c), "the Stop's History writes never settled")
    #expect(c.documentText == first.documentText, "the kept cleanup is on screen")
    #expect(store.current(id)?.polishedText == nil, "History still lacks its text")
    #expect(!c.isSavedToHistory, "the badge does not say Saved to History")
    c.documentView = .original
    #expect(c.isSavedToHistory, "the original words on screen ARE saved (Codex round 7)")
    c.documentView = .cleaned
    await script.gate.open()
  }

  @Test(
    "a Stop during the first cleanup still writes the turns raw: there is nothing to keep (#3903)")
  func stopDuringTheFirstCleanupHasNothingToKeep() async {
    let store = FakeHistoryStore()
    let telemetry = TurnTelemetryRecorder()
    let script = ReRunScript()
    script.gateAt = 2
    let c = makeReRunCoordinator(script, store: store, labeled: true, telemetry: telemetry)
    c.choose(url: Self.anyURL)
    _ = await settleUntil {
      if case .ready = c.state { return true } else { return false }
    }
    c.start()
    #expect(await script.gate.waitUntilArrived())
    guard let id = c.historyID else { return }
    c.stop()
    #expect(await settleUntil { store.current(id)?.turns != nil })
    #expect(turnTexts(store.current(id)) == [nil, nil], "the first run's Stop is unchanged")
    #expect(telemetry.events.map(\.outcome) == [.stopped])
    await script.gate.open()
  }

  @Test("Clean it again is refused while a retry's analysis is in flight, and the retry's re-clean still lands (#2851 follow-up)")
  func rePolishIsRefusedDuringARetry() async {
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
    let coordinator = makeStoreBackedCoordinator(
      store: store, wordTimings: Self.twoSpeakerWordTimings(),
      speakerLabeler: { _, _ in
        if attempts.next() == 1 { return .failed(.analyzerThrew("boom")) }
        await speakerGate.markArrived()
        await speakerGate.waitUntilOpen()
        return .labeled(count: 2, segments: Self.twoSpeakerSegments)
      },
      processPart: { part, _ in
        FileImportRunner.PartOutcome(text: part, polishedText: "clean " + part)
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
    _ = await settleUntil {
      if case .failed = store.current(historyID)?.speakerAnalysis { return true }
      return false
    }
    coordinator.retrySpeakerAnalysis()
    #expect(await speakerGate.waitUntilArrived(), "speakerGate: the gated call never arrived")
    let generationBefore = coordinator.generation
    coordinator.rePolish()
    #expect(coordinator.generation == generationBefore, "refused while the retry's analysis runs")
    #expect(!coordinator.isRunning)

    await speakerGate.open()
    let retried = await settleUntil {
      store.current(historyID)?.speakerAnalysis == .labeled(count: 2) && coordinator.state == .finished
    }
    #expect(retried)
    #expect(turnTexts(store.current(historyID)) == ["clean hello", "clean there friend"])
  }

  @Test("a Stop whose turn write throws leaves the partial cleaned document on screen, reported as not saved (#2851 follow-up)")
  func stopWhoseWriteThrowsIsNotReportedSaved() async {
    let store = FakeHistoryStore()
    store.throwOnMergeCall = 1
    let secondPartGate = ManualGate()
    @MainActor final class PartCounter {
      private(set) var count = 0
      func next() -> Int {
        count += 1
        return count
      }
    }
    let partsSeen = PartCounter()
    let coordinator = makeStoreBackedCoordinator(
      store: store, wordTimings: Self.twoSpeakerWordTimings(),
      speakerLabeler: { _, _ in .labeled(count: 2, segments: Self.twoSpeakerSegments) },
      processPart: { part, _ in
        if partsSeen.next() == 2 {
          await secondPartGate.markArrived()
          await secondPartGate.waitUntilOpen()
        }
        return FileImportRunner.PartOutcome(text: part, polishedText: "clean " + part)
      })

    coordinator.choose(url: Self.anyURL)
    _ = await settleUntil {
      if case .ready = coordinator.state { return true } else { return false }
    }
    coordinator.start()
    #expect(await secondPartGate.waitUntilArrived(), "secondPartGate: the gated call never arrived")
    guard let historyID = coordinator.historyID else {
      Issue.record("no historyID once the second section is in flight")
      return
    }
    coordinator.stop()
    let attempted = await settleUntil { store.mergeCalls == 1 }
    #expect(attempted)
    #expect(store.current(historyID)?.turns == nil, "the write threw")
    #expect(!coordinator.isSavedToHistory, "the cleaned section on screen is not on disk")
    await secondPartGate.open()
  }

  @Test("a space-free turn cut at character boundaries is rebuilt with no invented spaces; a spaced one keeps its real gaps (#2851 follow-up)")
  func piecesRejoinWithTheirRealGaps() {
    // A long space-free run past the byte ceiling: the splitter cuts it at characters.
    let cjk = String(repeating: "日本語の長い文章です。", count: TranscriptSplitter.maximumBytesPerPart / 30 + 5)
    let cjkTurn = Turn(id: "cjk", speakerId: "A", startMs: 0, endMs: 1, originalTextRange: 0..<cjk.utf16.count)
    let cut = FileImportDocumentMath.cleanupPieces(turns: [cjkTurn], rawText: cjk)
    #expect(cut.pieces.count >= 2, "the fixture must split: \(cut.pieces.count)")
    #expect(cut.gaps.allSatisfy { $0.isEmpty }, "no whitespace lies between character-boundary cuts")
    let parts = zip(cut.pieces, cut.gaps).enumerated().map { index, pair in
      FileImportCoordinator.Part(
        id: index, text: pair.0, isUnpolished: false, wasPolished: true, turnID: "cjk",
        trailingGap: pair.1)
    }
    let rebuilt = FileImportDocumentMath.finalTurns([cjkTurn], parts: parts, cleanupCompleted: true)
    #expect(rebuilt.first?.processedText == cjk, "identity cleanup must give the text back byte for byte")

    // A spaced long turn keeps the space (or newline) that really sat between its pieces.
    let words = (0..<700).map { "w\($0)" }
    let spaced = words.prefix(350).joined(separator: " ") + "\n" + words.dropFirst(350).joined(separator: " ")
    let spacedTurn = Turn(id: "sp", speakerId: "A", startMs: 0, endMs: 1, originalTextRange: 0..<spaced.utf16.count)
    let cut2 = FileImportDocumentMath.cleanupPieces(turns: [spacedTurn], rawText: spaced)
    #expect(cut2.pieces.count >= 2)
    let parts2 = zip(cut2.pieces, cut2.gaps).enumerated().map { index, pair in
      FileImportCoordinator.Part(
        id: index, text: pair.0, isUnpolished: false, wasPolished: true, turnID: "sp",
        trailingGap: pair.1)
    }
    #expect(FileImportDocumentMath.finalTurns([spacedTurn], parts: parts2, cleanupCompleted: true).first?.processedText == spaced)
    // The document joins the same way inside a turn, and with a blank line between turns.
    #expect(FileImportDocumentMath.joinedDocument(parts) == cjk)
    let twoTurns = [
      FileImportCoordinator.Part(id: 0, text: "hello", isUnpolished: false, wasPolished: true, turnID: "a"),
      FileImportCoordinator.Part(id: 1, text: "there", isUnpolished: false, wasPolished: true, turnID: "b"),
    ]
    #expect(FileImportDocumentMath.joinedDocument(twoTurns) == "hello\n\nthere")
  }

  /// Drives one import to `state == .finished` plus a settled speaker step, and returns the
  /// coordinator and its history id; nil (with an issue recorded) if no row landed.
  private func settledImport(
    store: FakeHistoryStore, wordTimings: [ASRWordTiming]?,
    segmentTimings: [ASRSegmentTiming]? = nil,
    speakerLabeler: @escaping @MainActor ([Float], TimeInterval) async -> SpeakerAnalysis
  ) async -> (FileImportCoordinator, UUID)? {
    let coordinator = makeStoreBackedCoordinator(
      store: store, wordTimings: wordTimings, segmentTimings: segmentTimings,
      speakerLabeler: speakerLabeler)
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

  @Test("while speakers are found the Working phase names it; the Done line clears once the step finishes")
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
    #expect(await speakerGate.waitUntilArrived(), "speakerGate: the gated call never arrived")
    #expect(coordinator.speakerStatusLabel == "Finding speakers")
    #expect(coordinator.phase == "Finding who said what")

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
    #expect(await speakerGate.waitUntilArrived(), "speakerGate: the gated call never arrived")
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

  @Test("a retry re-cleans its new sections through Clean it again, and the stored event fires once (#2811, #2851)")
  func retryRecleansItsNewSections() async {
    let store = FakeHistoryStore()
    let cleaner = WordSwappingCleaner()
    let telemetry = TurnTelemetryRecorder()
    @MainActor final class PartRecorder {
      private(set) var parts: [String] = []
      func record(_ part: String) { parts.append(part) }
    }
    let partsSeen = PartRecorder()
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
        partsSeen.record(part)
        return cleaner.outcome(part)
      },
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
        && coordinator.state == .finished
        && turnTexts(store.current(historyID)) == [first.a, first.b]
    }
    #expect(retried, "the retry's new sections must be cleaned and written: \(turnTexts(store.current(historyID)))")
    for _ in 0..<20 { await Task.yield() }
    #expect(telemetry.stored.count == 1, "the once-per-import event fires on the retry's write: \(telemetry.events)")
    #expect(telemetry.stored.first?.turnCount == 2)
    // The first cleanup saw the one-speaker document; the retry re-cleans it as sections.
    #expect(partsSeen.parts == ["hello there friend", "hello", "there friend"])
    #expect(!coordinator.retainsRetryInputs, "a labeled row is settled: the audio is released")
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
    // Two 300-word turns, one section each: long enough that a per-turn second pass
    // restricted to longer turns would show up as extra calls too (chunk 4 review).
    let fixture = Self.manyWordFixture(count: 300, split: 150)
    let coordinator = makeStoreBackedCoordinator(
      store: store, transcribedText: fixture.text, wordTimings: fixture.timings,
      speakerLabeler: { _, _ in .labeled(count: 2, segments: fixture.segments) },
      processPart: { part, _ in
        calls.record(part)
        return FileImportRunner.PartOutcome(text: part, polishedText: part)
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
    #expect(coordinator.pendingPieces.count == 2, "two turns, two sections")
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
          text: part, polishedText: nil, polishAttempted: false)
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

  @Test("a section whose polish failed keeps its floor words and is disclosed (#2851 §3 D)")
  func failedPolishIsDisclosedOnTheTurns() async {
    let store = FakeHistoryStore()
    let coordinator = makeStoreBackedCoordinator(
      store: store, wordTimings: Self.twoSpeakerWordTimings(),
      speakerLabeler: { _, _ in .labeled(count: 2, segments: Self.twoSpeakerSegments) },
      processPart: { part, _ in
        FileImportRunner.PartOutcome(text: part, polishedText: nil)
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
      "a failed polish is disclosed on every turn whose section failed")
  }

  @Test("only the section whose polish failed is disclosed; its neighbour is clean (#2851 follow-up)")
  func onlyTheFailedSectionIsDisclosed() async {
    let store = FakeHistoryStore()
    let telemetry = TurnTelemetryRecorder()
    let coordinator = makeStoreBackedCoordinator(
      store: store, wordTimings: Self.twoSpeakerWordTimings(),
      speakerLabeler: { _, _ in .labeled(count: 2, segments: Self.twoSpeakerSegments) },
      processPart: { part, _ in
        part == "there friend"
          ? FileImportRunner.PartOutcome(text: part, polishedText: nil)
          : FileImportRunner.PartOutcome(text: part, polishedText: "Hello.")
      },
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
    #expect(turnTexts(store.current(historyID)) == ["Hello.", "there friend"])
    #expect(store.current(historyID)?.turns?.map(\.wasPolished) == [true, false])
    #expect(telemetry.stored.first?.fallback == 1, "\(telemetry.events)")
  }

  // MARK: - #3735 §3.10 segment timings

  /// "hello there friend": "hello there" inside speaker A's interval, "friend" inside B's.
  private static let twoSpeakerSegmentTimings = [
    ASRSegmentTiming(range: 0..<11, startMs: 0, endMs: 200),
    ASRSegmentTiming(range: 12..<18, startMs: 5_000, endMs: 5_400),
  ]

  @Test("segment timings alone label speakers on the first pass and store segment turns (#3735)")
  func segmentOnlyInitialAnalysis() async {
    let store = FakeHistoryStore()
    guard
      let (coordinator, historyID) = await settledImport(
        store: store, wordTimings: nil, segmentTimings: Self.twoSpeakerSegmentTimings,
        speakerLabeler: { _, _ in .labeled(count: 2, segments: Self.twoSpeakerSegments) })
    else { return }
    let stored = await settleUntil { store.current(historyID)?.turns != nil && coordinator.state == .finished }
    #expect(stored)
    let row = store.current(historyID)
    #expect(row?.speakerAnalysis == .labeled(count: 2))
    #expect(row?.turns?.map(\.speakerId) == ["A", "B"])
    #expect(row?.turns?.map(\.granularity) == [.segment, .segment])
    #expect(row?.turns?.map(\.originalTextRange) == [0..<11, 12..<18])
    #expect(!coordinator.retainsRetryInputs, "a labeled outcome releases the audio")
  }

  @Test("segments that mix speakers store Both turns as a labeled result, not a timing failure (#3735)")
  func mixedSegmentsAreLabeledBoth() async {
    let store = FakeHistoryStore()
    guard
      let (_, historyID) = await settledImport(
        store: store, wordTimings: nil,
        segmentTimings: [ASRSegmentTiming(range: 0..<18, startMs: 0, endMs: 5_400)],
        speakerLabeler: { _, _ in .labeled(count: 2, segments: Self.twoSpeakerSegments) })
    else { return }
    let stored = await settleUntil { store.current(historyID)?.turns != nil }
    #expect(stored)
    #expect(store.current(historyID)?.speakerAnalysis == .labeled(count: 2))
    #expect(store.current(historyID)?.turns?.map(\.speakerId) == [TurnAssembler.bothSpeakersID])
  }

  @Test("segment timings with no usable bounds and no word timings: noWordTimings, no retry, audio released (#3735)")
  func unusableSegmentsAreNotRetryable() async {
    let store = FakeHistoryStore()
    guard
      let (coordinator, historyID) = await settledImport(
        store: store, wordTimings: nil,
        segmentTimings: [ASRSegmentTiming(range: 0..<18, startMs: nil, endMs: nil)],
        speakerLabeler: { _, _ in .labeled(count: 2, segments: Self.twoSpeakerSegments) })
    else { return }
    #expect(store.current(historyID)?.speakerAnalysis == .failed(.noWordTimings))
    #expect(!coordinator.canRetrySpeakerAnalysis)
    #expect(!coordinator.retainsRetryInputs)
  }

  @Test("zero-length, reversed or negative segment bounds alone: noWordTimings, no retry, audio released (#3735)")
  func invalidSegmentBoundsAreNotRetryable() async {
    for bounds in [(100, 100), (400, 300), (-50, 50)] {
      let store = FakeHistoryStore()
      guard
        let (coordinator, historyID) = await settledImport(
          store: store, wordTimings: nil,
          segmentTimings: [ASRSegmentTiming(range: 0..<18, startMs: bounds.0, endMs: bounds.1)],
          speakerLabeler: { _, _ in .labeled(count: 2, segments: Self.twoSpeakerSegments) })
      else { return }
      #expect(store.current(historyID)?.speakerAnalysis == .failed(.noWordTimings))
      #expect(!coordinator.canRetrySpeakerAnalysis, "bounds \(bounds) can never overlap")
      #expect(!coordinator.retainsRetryInputs)
    }
  }

  @Test("usable segments that bind no interval fail as noWordTimings but stay retryable (#3735)")
  func unboundUsableSegmentsStayRetryable() async {
    let store = FakeHistoryStore()
    guard
      let (coordinator, historyID) = await settledImport(
        store: store, wordTimings: nil,
        segmentTimings: [ASRSegmentTiming(range: 0..<18, startMs: 9_000, endMs: 9_500)],
        speakerLabeler: { _, _ in .labeled(count: 2, segments: Self.twoSpeakerSegments) })
    else { return }
    #expect(store.current(historyID)?.speakerAnalysis == .failed(.noWordTimings))
    #expect(coordinator.canRetrySpeakerAnalysis, "another segmentation could bind these segments")
    #expect(coordinator.retainsRetryInputs)
    // Deleting the row releases the retained segment state with the audio.
    coordinator.noteHistoryRowDeleted(historyID)
    #expect(!coordinator.retainsRetryInputs)
    #expect(!coordinator.canRetrySpeakerAnalysis)
  }

  @Test("a retry on segment timings re-runs only the analyzer and stores segment turns (#3735)")
  func segmentRetry() async {
    let store = FakeHistoryStore()
    @MainActor final class AttemptCounter {
      private(set) var count = 0
      func next() -> Int {
        count += 1
        return count
      }
    }
    let attempts = AttemptCounter()
    let coordinator = makeStoreBackedCoordinator(
      store: store, wordTimings: nil, segmentTimings: Self.twoSpeakerSegmentTimings,
      speakerLabeler: { _, _ in
        attempts.next() == 1
          ? .failed(.analyzerThrew("boom")) : .labeled(count: 2, segments: Self.twoSpeakerSegments)
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
    let failed = await settleUntil {
      if case .failed = store.current(historyID)?.speakerAnalysis { return true }
      return false
    }
    #expect(failed)
    #expect(coordinator.canRetrySpeakerAnalysis, "segment timings are a usable retry input")
    coordinator.retrySpeakerAnalysis()
    let retried = await settleUntil {
      store.current(historyID)?.speakerAnalysis == .labeled(count: 2)
        && coordinator.state == .finished
    }
    #expect(retried)
    #expect(store.current(historyID)?.turns?.map(\.granularity) == [.segment, .segment])
    #expect(store.current(historyID)?.turns?.map(\.speakerId) == ["A", "B"])
    #expect(attempts.count == 2, "the analyzer ran twice; the ASR never re-ran")
  }

  @Test("word timings keep precedence when they bind; segments are not used (#3735)")
  func wordPathKeepsPrecedence() async {
    let store = FakeHistoryStore()
    guard
      let (_, historyID) = await settledImport(
        store: store, wordTimings: Self.twoSpeakerWordTimings(),
        segmentTimings: [ASRSegmentTiming(range: 0..<18, startMs: 0, endMs: 5_400)],
        speakerLabeler: { _, _ in .labeled(count: 2, segments: Self.twoSpeakerSegments) })
    else { return }
    let stored = await settleUntil { store.current(historyID)?.turns != nil }
    #expect(stored)
    #expect(store.current(historyID)?.turns?.map(\.speakerId) == ["A", "B"])
    #expect(store.current(historyID)?.turns?.allSatisfy { $0.granularity == nil } == true)
  }

  @Test("choosing another file drops the previous file's segment retry state (#3735)")
  func chooseDropsSegmentRetryState() async {
    let store = FakeHistoryStore()
    guard
      let (coordinator, _) = await settledImport(
        store: store, wordTimings: nil,
        segmentTimings: [ASRSegmentTiming(range: 0..<18, startMs: 9_000, endMs: 9_500)],
        speakerLabeler: { _, _ in .labeled(count: 2, segments: Self.twoSpeakerSegments) })
    else { return }
    #expect(coordinator.canRetrySpeakerAnalysis)
    coordinator.choose(url: Self.anyURL)
    #expect(!coordinator.retainsRetryInputs)
    #expect(!coordinator.canRetrySpeakerAnalysis)
  }

  @Test("a retry re-cleans the new sections and persists them")
  func retrySpeakerAnalysisRecleansAndPersists() async {
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
        // The first cleanup sees the one-speaker document; the retry's re-clean sees the
        // two sections (#2851 follow-up).
        if part != "hello there friend" { await cleanupCounter.increment() }
        return FileImportRunner.PartOutcome(text: part, polishedText: part)
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
        && coordinator.state == .finished
    }
    #expect(retried, "retry never persisted the successful labeled outcome")
    #expect(store.current(historyID)?.turns?.count == 2)
    #expect(cleanupCounter.count == 2, "the retry re-cleans its two sections, once each")
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
    #expect(await speakerGate.waitUntilArrived(), "speakerGate: the gated call never arrived")

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
    #expect(await speakerGate.waitUntilArrived(), "speakerGate: the gated call never arrived")

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
    #expect(await speakerGate.waitUntilArrived(), "speakerGate: the gated call never arrived")
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

  /// A finished two-speaker import with its labeled row stored, for the held-rename tests.
  private func finishedLabeledImport(
    store: FakeHistoryStore,
    emitRenameTelemetry: @escaping @MainActor (TelemetryService.FileImportRenameOutcome) -> Void
  ) async throws -> (FileImportCoordinator, UUID) {
    let coordinator = makeStoreBackedCoordinator(
      store: store, wordTimings: Self.twoSpeakerWordTimings(),
      speakerLabeler: { _, _ in .labeled(count: 2, segments: Self.twoSpeakerSegments) },
      emitRenameTelemetry: emitRenameTelemetry)
    coordinator.choose(url: Self.anyURL)
    try #require(
      await settleUntil {
        if case .ready = coordinator.state { return true } else { return false }
      })
    coordinator.start()
    try #require(await settleUntil { coordinator.state == .finished }, "the import never finished")
    let historyID = try #require(coordinator.historyID)
    try #require(await settleUntil { store.current(historyID)?.turns != nil })
    try #require(await settleUntil { coordinator.speakerStepState == .finished })
    return (coordinator, historyID)
  }

  /// #4075 S1: the rename's write is awaited. It reports its real outcome only after the
  /// write settles: success, a row deleted while it waited, or a failure that names the
  /// speaker's name as it is now.
  @Test("a held rename reports the write's real outcome once it settles")
  func heldRenameReportsTheRealOutcome() async throws {
    for ending in ["saved", "deleted", "failed"] {
      let store = FakeHistoryStore()
      defer { store.releaseHeldRename() }
      var outcomes: [TelemetryService.FileImportRenameOutcome] = []
      let (coordinator, historyID) = try await finishedLabeledImport(
        store: store, emitRenameTelemetry: { outcomes.append($0) })
      let revisionBefore = coordinator.speakerFieldsRevision
      store.holdNextRename = true
      var returned = false
      let rename = Task { @MainActor in
        let failure = await coordinator.renameSpeaker(id: "A", name: "Zach")
        returned = true
        return failure
      }
      try #require(await settleUntil { store.isHoldingRename }, "the rename never arrived")
      #expect(returned == false, "the rename answered before its write settled")
      switch ending {
      case "deleted":
        store.delete(historyID)
      case "failed":
        // Someone else renamed A while this write waited; the failure must say so.
        let row = try #require(store.current(historyID))
        store.save(
          row.mergingSpeakerFields(
            analysis: try #require(row.speakerAnalysis), turns: row.turns,
            explicitRename: ("A", "Latest")))
        try #require(store.current(historyID)?.speakerNames?["A"] == "Latest")
        store.failNextRename = true
      default:
        break
      }
      store.releaseHeldRename()
      let failure = await rename.value
      #expect(store.renameCalls == 1)
      switch ending {
      case "saved":
        #expect(failure == nil)
        #expect(store.current(historyID)?.speakerNames?["A"] == "Zach")
        #expect(outcomes == [.saved])
        #expect(coordinator.speakerFieldsRevision == revisionBefore + 1)
      case "deleted":
        #expect(failure?.message == RenameFailure.recordingRemoved)
        #expect(store.current(historyID) == nil, "the refused rename brought the row back")
        #expect(outcomes == [.failed])
      default:
        #expect(failure?.message == RenameFailure.couldNotSaveName)
        #expect(failure?.currentName == "Latest", "the failure named a stale speaker name")
        #expect(store.current(historyID)?.speakerNames?["A"] == "Latest")
        #expect(outcomes == [.failed])
      }
    }
  }

  /// #4075 S1: a new file chosen while an old rename waits. The old rename still settles and
  /// reports once; the new file's identity and view are untouched.
  @Test("a rename that settles after another file was chosen leaves that file alone")
  func heldRenameAfterReplacement() async throws {
    for fails in [false, true] {
      let store = FakeHistoryStore()
      defer { store.releaseHeldRename() }
      var outcomes: [TelemetryService.FileImportRenameOutcome] = []
      let (coordinator, historyID) = try await finishedLabeledImport(
        store: store, emitRenameTelemetry: { outcomes.append($0) })
      let nameBefore = store.current(historyID)?.speakerNames?["A"]
      store.holdNextRename = true
      let rename = Task { @MainActor in
        await coordinator.renameSpeaker(id: "A", name: "Zach")
      }
      try #require(await settleUntil { store.isHoldingRename }, "the rename never arrived")
      coordinator.choose(url: URL(fileURLWithPath: "/tmp/replacement.m4a"))
      try #require(
        await settleUntil {
          if case .ready = coordinator.state { return true } else { return false }
        })
      let revisionBefore = coordinator.speakerFieldsRevision
      store.failNextRename = fails
      store.releaseHeldRename()
      let failure = await rename.value
      #expect((failure == nil) == (fails == false))
      #expect(outcomes == [fails ? .failed : .saved])
      #expect(store.current(historyID)?.speakerNames?["A"] == (fails ? nameBefore : "Zach"))
      #expect(coordinator.historyID == nil, "the new file took the old row's identity")
      #expect(coordinator.file?.name == "replacement.m4a")
      #expect(coordinator.speakerFieldsRevision == revisionBefore)
      #expect(coordinator.historySaveFailure == nil)
    }
  }

  /// #4075 S1: cancellation. A caller cancelled before the write is sent sends none; one
  /// cancelled after it is sent still gets the write's real result, with no second write.
  @Test("a cancelled rename sends no write, and a sent one still settles")
  func cancelledRename() async throws {
    let store = FakeHistoryStore()
    defer { store.releaseHeldRename() }
    let (coordinator, historyID) = try await finishedLabeledImport(
      store: store, emitRenameTelemetry: { _ in })
    // Not yet started: this test holds the main actor until it awaits the task.
    let early = Task { @MainActor in await coordinator.renameSpeaker(id: "A", name: "Early") }
    early.cancel()
    let earlyFailure = await early.value
    #expect(earlyFailure?.message == RenameFailure.couldNotSaveName)
    #expect(store.renameCalls == 0, "a cancelled rename still sent a write")

    store.holdNextRename = true
    let late = Task { @MainActor in await coordinator.renameSpeaker(id: "A", name: "Zach") }
    try #require(await settleUntil { store.isHoldingRename }, "the rename never arrived")
    late.cancel()
    store.releaseHeldRename()
    let lateFailure = await late.value
    #expect(lateFailure == nil, "a sent write was reported as failed because its caller left")
    #expect(store.renameCalls == 1)
    #expect(store.current(historyID)?.speakerNames?["A"] == "Zach")
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
