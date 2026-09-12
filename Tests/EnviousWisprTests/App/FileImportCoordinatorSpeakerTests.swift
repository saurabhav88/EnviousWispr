import EnviousWisprASR
import EnviousWisprCore
import EnviousWisprPipeline
import Foundation
import Testing

@testable import EnviousWisprAppKit

/// #2809 — the dormant, phase-2 speaker step wired into the file-import coordinator.
///
/// **When this fails, a stopped import holds the shared engine for as long as the speaker
/// worker takes to finish on its own, or a refused raw save still runs an analysis on words
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
    wordTimingCoverage: ASRWordTimingCoverage? = nil,
    speakerLabeler: @escaping @MainActor ([Float], TimeInterval) async -> SpeakerAnalysis,
    saveToHistory: @escaping @MainActor (Transcript) throws -> Void = { _ in },
    emitSpeakerTelemetry: @escaping @MainActor (
      SpeakerAnalysis, TimeInterval, Int, ASRWordTimingCoverage?
    ) -> Void = { _, _, _, _ in },
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
          text: "one two three", language: "en", duration: 0, processingTime: 0,
          backendType: .parakeet, wordTimings: nil, wordTimingCoverage: wordTimingCoverage)
      },
      speakerLabeler: speakerLabeler,
      emitSpeakerTelemetry: emitSpeakerTelemetry,
      engineAdmission: .live(lease: lease, as: .fileImport),
      beginRun: {
        FileImportCoordinator.RunConfiguration(
          polishIsCloud: false, localPolishProvider: nil, polishProvider: .egOne,
          ollamaModel: nil, polishModel: "eg-1", backendType: .parakeet)
      },
      saveToHistory: saveToHistory,
      updateHistoryRow: { _ in true },
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

  @Test("Stop exits the speaker worker before the engine claim is released")
  func stopJoinsTheSpeakerWorkerBeforeReleasingTheEngine() async {
    let gate = Gate()
    let coordinator = makeCoordinator(
      lease: EngineLease(),
      speakerLabeler: { _, _ in
        await gate.markEntered()
        do {
          // settle: cancelled by Stop long before this would ever elapse.
          try await Task.sleep(nanoseconds: 30_000_000_000)
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
    await gate.waitUntilEntered()

    // The speaker worker is genuinely in flight: the claim must still be held.
    #expect(coordinator.isEngineHeld)

    coordinator.stop()

    let released = await settleUntil { coordinator.isEngineHeld == false }
    #expect(released, "the engine claim was never released after Stop")
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
}
