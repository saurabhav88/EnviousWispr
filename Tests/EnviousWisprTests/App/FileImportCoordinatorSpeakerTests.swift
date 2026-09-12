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
  /// test can wait to know a call has arrived. Used to prove ORDERING (turn-cleanup's own
  /// calls never arrive before the visible document's cleanup has actually returned).
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

  private func settleUntil(
    limit: Int = 500, _ condition: @MainActor () async -> Bool
  ) async -> Bool {
    for _ in 0..<limit {
      if await condition() { return true }
      await Task.yield()
    }
    return await condition()
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
    emitSpeakerTelemetry: @escaping @MainActor (
      SpeakerAnalysis, TimeInterval, Int, ASRWordTimingCoverage?
    ) -> Void = { _, _, _, _ in },
    emitTurnTelemetry: @escaping @MainActor (
      TelemetryService.FileImportTurnsOutcome, Int?, Int
    ) -> Void = { _, _, _ in },
    onVisibleCleanupWaitResolved: @escaping @MainActor (Int) -> Void = { _ in },
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
      onVisibleCleanupWaitResolved: onVisibleCleanupWaitResolved,
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

  @Test(
    "turn-safe cleanup's own processPart calls never arrive before the visible document's cleanup has returned"
  )
  func turnCleanupWaitsForVisibleCleanupToFinish() async {
    let documentGate = ManualGate()
    let turnGate = ManualGate()
    let coordinator = makeCoordinator(
      lease: EngineLease(),
      transcribedText: "hello there friend",
      wordTimings: Self.twoSpeakerWordTimings(),
      speakerLabeler: { _, _ in .labeled(count: 2, segments: Self.twoSpeakerSegments) },
      processPart: { part, _ in
        if part == "hello there friend" {
          // The visible document's own single piece — hold it open until the test says go.
          await documentGate.markArrived()
          await documentGate.waitUntilOpen()
        } else {
          // A turn's own sliced text ("hello", or "there friend") — must never arrive
          // before the document gate above has been explicitly opened.
          await turnGate.markArrived()
        }
        return FileImportRunner.PartOutcome(text: part, polishedText: part, polishError: nil)
      })

    coordinator.choose(url: Self.anyURL)
    _ = await settleUntil {
      if case .ready = coordinator.state { return true } else { return false }
    }
    coordinator.start()
    await documentGate.waitUntilArrived()

    // The visible pass's own call is in flight and held open; turn-cleanup must not have
    // started yet, because it has not even been signaled that the visible pass finished.
    #expect(await turnGate.arrivedSoFar() == false)

    await documentGate.open()
    let finished = await settleUntil { coordinator.state == .finished }
    #expect(finished, "the visible run should finish once its own held part is released")

    // NOW turn-cleanup's calls are free to arrive — a BOUNDED wait, never an unconditional
    // await of the very signal under test: if the gate had a bug and never resolved, this
    // fails with a clear message instead of hanging the suite forever.
    let turnCleanupArrived = await settleUntil { await turnGate.arrivedSoFar() }
    #expect(turnCleanupArrived, "turn-cleanup should have started once the visible pass finished")
  }

  @Test(
    "a superseded generation's completion gate still resolves when its run is stopped, never hangs")
  func supersededGenerationGateStillResolves() async {
    let documentGate = ManualGate()
    let coordinator = makeCoordinator(
      lease: EngineLease(),
      transcribedText: "hello there friend",
      wordTimings: Self.twoSpeakerWordTimings(),
      speakerLabeler: { _, _ in .labeled(count: 2, segments: Self.twoSpeakerSegments) },
      processPart: { part, _ in
        await documentGate.markArrived()
        await documentGate.waitUntilOpen()
        return FileImportRunner.PartOutcome(text: part, polishedText: part, polishError: nil)
      })

    coordinator.choose(url: Self.anyURL)
    _ = await settleUntil {
      if case .ready = coordinator.state { return true } else { return false }
    }
    coordinator.start()
    await documentGate.waitUntilArrived()

    // Stop while the visible pass's own part call is still held open. `stop()` cancels the
    // run task and bumps `generation`, but the blocked `processPart` call itself does not
    // return until the gate opens — `Task.cancel()` alone cannot interrupt an in-flight
    // `await` with no cooperative check inside it.
    coordinator.stop()
    let stopped = await settleUntil { coordinator.state == .stopped }
    #expect(stopped)

    // NOW let the stale call return. `polishAll`'s own generation guard sees a superseded
    // generation and returns early — its `defer` must still settle the completion gate for
    // that generation, so anything that had been waiting on it (or would wait on it later)
    // is never left hanging forever.
    await documentGate.open()

    // If the gate were broken (never settled on this exit path), a background task still
    // waiting on this exact generation would hang. Prove it resolves within a bounded
    // window by driving a SECOND run and confirming ITS OWN turn-cleanup still completes
    // normally — a wedged gate implementation (e.g. one that leaked a waiter into the wrong
    // bucket) would show up as the second run's own sequencing breaking.
    coordinator.choose(url: Self.anyURL)
    _ = await settleUntil {
      if case .ready = coordinator.state { return true } else { return false }
    }
    coordinator.start()
    let secondFinished = await settleUntil { coordinator.state == .finished }
    #expect(secondFinished, "a fresh run after a superseded generation must complete normally")
  }

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

  @Test("a refused engine admission skips the turn-cleanup pass entirely, with no merge call")
  func refusedAdmissionSkipsCleanupEntirely() async {
    @MainActor final class MergeRecorder {
      private(set) var callCount = 0
      func record() { callCount += 1 }
    }
    @MainActor final class TelemetryRecorder {
      private(set) var outcomes: [TelemetryService.FileImportTurnsOutcome] = []
      func record(_ outcome: TelemetryService.FileImportTurnsOutcome) { outcomes.append(outcome) }
    }
    let recorder = MergeRecorder()
    let telemetry = TelemetryRecorder()
    let speakerGate = ManualGate()
    let lease = EngineLease()
    let coordinator = makeCoordinator(
      lease: lease,
      transcribedText: "hello there friend",
      wordTimings: Self.twoSpeakerWordTimings(),
      speakerLabeler: { _, _ in
        // Blocks AFTER the main run's own claim has already been granted and released
        // (the main run does not depend on this returning), so the test can claim the
        // SAME lease itself in the exact window before turn-cleanup tries to.
        await speakerGate.markArrived()
        await speakerGate.waitUntilOpen()
        return .labeled(count: 2, segments: Self.twoSpeakerSegments)
      },
      mergeSpeakerFields: { _, _, _ in
        recorder.record()
        return true
      },
      emitTurnTelemetry: { outcome, _, _ in telemetry.record(outcome) })

    coordinator.choose(url: Self.anyURL)
    _ = await settleUntil {
      if case .ready = coordinator.state { return true } else { return false }
    }
    coordinator.start()

    // The main run finishes on its own (processPart is the fast default fake) while the
    // speaker step sits blocked before returning its outcome.
    let finished = await settleUntil { coordinator.state == .finished }
    #expect(finished)
    await speakerGate.waitUntilArrived()
    #expect(coordinator.isEngineHeld == false, "the main run's own claim must already be released")

    // Claim the lease from OUTSIDE, simulating a competing workload — a new dictation, or
    // another import — taking it in the narrow window before turn-cleanup asks.
    guard case .granted = lease.admit(.dictation) else {
      Issue.record("test setup: could not claim the lease to simulate contention")
      return
    }

    // Let the speaker step return its outcome; turn-cleanup's own claim attempt is now
    // refused, and the pass must skip entirely — no merge call at all. Wait for the actual
    // refusal EVENT (found by chunk review round 2: 200 unconditional yields only hopes
    // enough scheduler turns passed, and never proves the refusal branch itself ran) —
    // a bounded wait on the real telemetry seam the production code already emits through.
    await speakerGate.open()
    let refused = await settleUntil { telemetry.outcomes.contains(.admissionRefused) }
    #expect(refused, "the admission-refused outcome was never observed")
    #expect(recorder.callCount == 0)
  }

  @Test(
    "a superseded generation's own waiter is directly proven to register and then resolve"
  )
  func supersededGenerationWaiterObservablyResolves() async {
    let documentGate = ManualGate()
    @MainActor final class ResolvedRecorder {
      private(set) var generations: [Int] = []
      func record(_ generation: Int) { generations.append(generation) }
    }
    let resolvedRecorder = ResolvedRecorder()
    let coordinator = makeCoordinator(
      lease: EngineLease(),
      transcribedText: "hello there friend",
      wordTimings: Self.twoSpeakerWordTimings(),
      speakerLabeler: { _, _ in .labeled(count: 2, segments: Self.twoSpeakerSegments) },
      onVisibleCleanupWaitResolved: { generation in resolvedRecorder.record(generation) },
      processPart: { part, _ in
        await documentGate.markArrived()
        await documentGate.waitUntilOpen()
        return FileImportRunner.PartOutcome(text: part, polishedText: part, polishError: nil)
      })

    coordinator.choose(url: Self.anyURL)
    _ = await settleUntil {
      if case .ready = coordinator.state { return true } else { return false }
    }
    coordinator.start()
    let firstGeneration = coordinator.generation
    await documentGate.waitUntilArrived()

    // REGISTRATION: the speaker step's own labeler returns immediately (no gate), so by
    // the time the visible pass's own part call has arrived, its background turn-cleanup
    // continuation should already be enqueued as a waiter on THIS generation — a bounded
    // wait on the actual internal state, never inferred from a later run's success.
    let registered = await settleUntil {
      coordinator.visibleCleanupWaiters[firstGeneration]?.isEmpty == false
    }
    #expect(
      registered, "generation \(firstGeneration)'s turn-cleanup pass never registered as a waiter")
    #expect(coordinator.visibleCleanupFinished.contains(firstGeneration) == false)
    #expect(resolvedRecorder.generations.isEmpty, "the wait resolved before the gate opened")

    // Stop while the visible pass's own part call is still held open. `stop()` cancels the
    // run task and bumps `generation`, but the blocked `processPart` call itself does not
    // return until the gate opens.
    coordinator.stop()
    let stopped = await settleUntil { coordinator.state == .stopped }
    #expect(stopped)

    // COMPLETION: let the stale call return, so `polishAll`'s own `defer` settles THIS
    // generation's gate. `onVisibleCleanupWaitResolved` fires from INSIDE the previously
    // suspended background task, the instant its `await` actually returns — proof the
    // continuation was truly resumed, not just that bookkeeping dictionaries were updated
    // (which would stay consistent even if `waiter.resume()` were deleted; found by chunk
    // review round 3). A bounded wait, since a broken resume would otherwise hang forever.
    await documentGate.open()
    let resolved = await settleUntil { resolvedRecorder.generations.contains(firstGeneration) }
    #expect(resolved, "generation \(firstGeneration)'s waiter was never resumed")
    #expect(coordinator.visibleCleanupFinished.contains(firstGeneration))
    #expect(coordinator.visibleCleanupWaiters[firstGeneration] == nil)
  }

  @Test(
    "Stop pressed AFTER Done cancels an in-flight background cleanup without persisting a partial pass, releasing only once the in-flight call returns"
  )
  func stopAfterDoneNeverPersistsAPartialPass() async {
    @MainActor final class MergeRecorder {
      private(set) var callCount = 0
      func record() { callCount += 1 }
    }
    let recorder = MergeRecorder()
    let turnGate = ManualGate()
    let coordinator = makeCoordinator(
      lease: EngineLease(),
      transcribedText: "hello there friend",
      wordTimings: Self.twoSpeakerWordTimings(),
      speakerLabeler: { _, _ in .labeled(count: 2, segments: Self.twoSpeakerSegments) },
      mergeSpeakerFields: { _, _, _ in
        recorder.record()
        return true
      },
      processPart: { part, _ in
        if part == "hello there friend" {
          // The visible pass's own single piece returns immediately — the visible run
          // reaches Done well before the background pass below is even asked to clean
          // anything up, which is the exact "Stop after Done" case #2810's addendum
          // names: `stop()`'s `isRunning` guard makes this an EARLY RETURN before
          // `generation` is bumped, so cancellation is the only signal left.
          return FileImportRunner.PartOutcome(text: part, polishedText: part, polishError: nil)
        }
        await turnGate.markArrived()
        await turnGate.waitUntilOpen()
        return FileImportRunner.PartOutcome(text: part, polishedText: part, polishError: nil)
      })

    coordinator.choose(url: Self.anyURL)
    _ = await settleUntil {
      if case .ready = coordinator.state { return true } else { return false }
    }
    coordinator.start()
    let visibleRunDone = await settleUntil { coordinator.state == .finished }
    #expect(
      visibleRunDone, "the visible run should reach Done before the background pass is exercised")

    // Bounded, never an unconditional await of the very signal under test — a regression
    // that stopped the background pass from ever starting must fail cleanly here instead
    // of hanging the suite (found by chunk review round 3).
    let backgroundInFlight = await settleUntil { await turnGate.arrivedSoFar() }
    #expect(backgroundInFlight, "the background pass never started its per-turn cleanup")
    #expect(coordinator.isEngineHeld, "the background pass's own claim must be genuinely held")

    coordinator.stop()

    // The claim must not be released until the in-flight call ACTUALLY returns —
    // `Task.cancel()` alone cannot interrupt an `await` with no cooperative check inside it.
    #expect(coordinator.isEngineHeld, "the claim was released before the in-flight call returned")

    await turnGate.open()
    let released = await settleUntil { coordinator.isEngineHeld == false }
    #expect(released, "the claim was never released once the in-flight call returned")
    #expect(recorder.callCount == 0, "a partial pass was persisted after Stop")
  }

  @Test(
    "the background hold re-prepares the frozen import polisher under its own claim, and reacts to its OWN readiness result even when it differs from the visible run's"
  )
  func backgroundHoldRePreparesAndReactsToItsOwnReadiness() async {
    @MainActor final class PrepareRecorder {
      private(set) var callCount = 0
      func record() { callCount += 1 }
    }
    @MainActor final class MergeRecorder {
      private(set) var callCount = 0
      func record() { callCount += 1 }
    }
    @MainActor final class TelemetryRecorder {
      private(set) var outcomes: [TelemetryService.FileImportTurnsOutcome] = []
      func record(_ outcome: TelemetryService.FileImportTurnsOutcome) { outcomes.append(outcome) }
    }
    let prepareRecorder = PrepareRecorder()
    let mergeRecorder = MergeRecorder()
    let telemetry = TelemetryRecorder()
    let coordinator = makeCoordinator(
      lease: EngineLease(),
      transcribedText: "hello there friend",
      wordTimings: Self.twoSpeakerWordTimings(),
      speakerLabeler: { _, _ in .labeled(count: 2, segments: Self.twoSpeakerSegments) },
      mergeSpeakerFields: { _, _, _ in
        mergeRecorder.record()
        return true
      },
      emitTurnTelemetry: { outcome, _, _ in telemetry.record(outcome) },
      prepareLocalPolish: { _ in
        prepareRecorder.record()
        // First call: the visible run's own `start()`. Every call after that is the
        // background hold's SEPARATE claim — simulating the shared engine's provider
        // having moved on in between, exactly the case #2810's addendum names.
        return prepareRecorder.callCount == 1
      })

    coordinator.choose(url: Self.anyURL)
    _ = await settleUntil {
      if case .ready = coordinator.state { return true } else { return false }
    }
    coordinator.start()
    let finished = await settleUntil { coordinator.state == .finished }
    #expect(
      finished,
      "the visible run must succeed on the FIRST preparation, independent of what the background pass later sees"
    )

    let reactedToItsOwnFailure = await settleUntil {
      telemetry.outcomes.contains(.polisherNotReady)
    }
    #expect(
      reactedToItsOwnFailure, "the background pass never reported its own re-preparation failure")
    #expect(
      prepareRecorder.callCount >= 2,
      "the background pass must re-prepare under its own claim rather than reusing the visible run's readiness"
    )
    #expect(
      mergeRecorder.callCount == 0,
      "a write must never happen once the background pass's own preparation fails")
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
    let coordinator = makeCoordinator(
      lease: EngineLease(),
      transcribedText: "hello there friend",
      wordTimings: Self.twoSpeakerWordTimings(),
      speakerLabeler: { _, _ in .labeled(count: 2, segments: Self.twoSpeakerSegments) },
      updateHistoryRow: { row in
        recorder.record(row)
        return true
      },
      emitTurnTelemetry: { outcome, _, _ in telemetry.record(outcome) })

    coordinator.choose(url: Self.anyURL)
    _ = await settleUntil {
      if case .ready = coordinator.state { return true } else { return false }
    }
    coordinator.start()
    _ = await settleUntil { coordinator.state == .finished }
    // Wait for the BACKGROUND turn-storage pass to actually REPORT a stored write, not
    // just for `isEngineHeld` to read false — that flag starts false too, so checking it
    // right after the visible run finishes can observe "not yet started" and "already
    // finished" as the exact same value (a race this test itself had before this fix).
    let stored = await settleUntil { telemetry.outcomes.contains(.stored) }
    #expect(stored, "the background turn-storage pass never reported a stored outcome")

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
}
