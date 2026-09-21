import EnviousWisprASR
import EnviousWisprCore
import EnviousWisprPipeline
import EnviousWisprServices
import Foundation
import Testing

@testable import EnviousWisprAppKit

/// #3069 — the per-run `file_import_completed` telemetry and Sentry capture wired into
/// `FileImportCoordinator`. What fails when this fails: an ASR engine can break for every
/// Transcribe a File user and neither PostHog nor Sentry would show it, or a re-polish
/// ("Clean it again") reports an ASR success it never measured, or a document polished with
/// no provider chosen gets counted as a polish FAILURE instead of a bypass.
///
/// Tagged `.observabilityContract`, not `.productOutcome`: nothing here changes what a user
/// sees on screen (`FileImportCoordinatorTests` owns that); this protects the diagnosability
/// of a path a user's screen already shows correctly.
@Suite(.tags(.observabilityContract))
@MainActor
struct FileImportCoordinatorRunTelemetryTests {

  /// Synchronous, same-actor recorders: the closures under test are `@MainActor` and called
  /// directly (never through a detached `Task`), so a plain `@MainActor` class is a complete
  /// and race-free record of every call, in order — no `actor`/`await`/settle needed to read it.
  @MainActor
  private final class RunTelemetryRecorder {
    private(set) var calls:
      [(
        outcome: TelemetryService.FileImportRunOutcome,
        asrOutcome: TelemetryService.FileImportASROutcome?,
        polishOutcome: TelemetryService.FileImportPolishOutcome?
      )] = []

    func record(
      outcome: TelemetryService.FileImportRunOutcome,
      asrOutcome: TelemetryService.FileImportASROutcome?,
      polishOutcome: TelemetryService.FileImportPolishOutcome?
    ) {
      calls.append((outcome, asrOutcome, polishOutcome))
    }
  }

  @MainActor
  private final class SentryFailureRecorder {
    private(set) var callCount = 0
    private(set) var lastBackend: ASRBackendType?
    func record(backend: ASRBackendType) {
      callCount += 1
      lastBackend = backend
    }
  }

  /// Proves a `transcribe` call ACTUALLY STARTED before the test cancels it — without this,
  /// `stop()` racing an ASR call that never began would let the test pass having exercised
  /// nothing (#3069 review round 1).
  private actor TranscriptionEntrySignal {
    private(set) var entered = false
    func markEntered() { entered = true }
  }

  nonisolated private static func decoded(seconds: Double) -> AudioFileDecoder.Decoded {
    AudioFileDecoder.Decoded(
      samples: Array(repeating: 0.1, count: Int(seconds * 16_000)),
      seconds: seconds, byteCount: Int64(seconds * 32_000), codec: "AAC",
      sampleRate: 44_100, channelCount: 1)
  }

  private static let anyURL = URL(fileURLWithPath: "/tmp/recording.m4a")

  private func settleUntil(_ condition: @MainActor () async -> Bool) async -> Bool {
    await settleUntilObserved(condition)
  }

  private func makeCoordinator(
    lease: EngineLease,
    transcribe: @escaping @MainActor ([Float]) async throws -> String = { _ in
      "One. Two. Three."
    },
    processPart: @escaping @MainActor (String) async throws -> FileImportRunner.PartOutcome = {
      FileImportRunner.PartOutcome(text: $0, polishedText: $0, polishError: nil)
    },
    polishProvider: LLMProvider = .egOne,
    emitRunTelemetry: @escaping @MainActor (
      TelemetryService.FileImportRunOutcome, ASRBackendType, TimeInterval,
      TelemetryService.FileImportASROutcome?, TelemetryService.FileImportPolishOutcome?,
      LLMProvider?, String?
    ) -> Void = { _, _, _, _, _, _, _ in },
    captureASRFailure: @escaping @MainActor (any Error, ASRBackendType) -> Void = { _, _ in }
  ) -> FileImportCoordinator {
    FileImportCoordinator(
      decode: { _ in Self.decoded(seconds: 1.0) },
      transcribe: { samples, _ in
        ASRResult(
          text: try await transcribe(samples), language: nil, duration: 0, processingTime: 0,
          backendType: .parakeet)
      },
      emitRunTelemetry: emitRunTelemetry,
      captureASRFailure: captureASRFailure,
      engineAdmission: .live(lease: lease, as: .fileImport),
      beginRun: {
        FileImportCoordinator.RunConfiguration(
          polishIsCloud: false, localPolishProvider: nil, polishProvider: polishProvider,
          ollamaModel: nil, polishModel: "eg-1", backendType: .parakeet)
      },
      saveToHistory: { _ in },
      updateHistoryRow: { _ in true },
      mergeSpeakerFields: { _, _, _ in true },
      historyRowExists: { _ in true },
      processPart: { part, _ in try await processPart(part) })
  }

  // MARK: - ASR failure

  @Test("an ASR engine failure reports asr_failed and captures a Sentry error, tagged by backend")
  func asrFailureReportsTelemetryAndSentry() async {
    struct EngineError: Error {}
    let telemetry = RunTelemetryRecorder()
    let sentry = SentryFailureRecorder()
    let coordinator = makeCoordinator(
      lease: EngineLease(),
      transcribe: { _ in throw EngineError() },
      emitRunTelemetry: { outcome, _, _, asrOutcome, polishOutcome, _, _ in
        telemetry.record(outcome: outcome, asrOutcome: asrOutcome, polishOutcome: polishOutcome)
      },
      captureASRFailure: { _, backend in
        sentry.record(backend: backend)
      })

    coordinator.choose(url: Self.anyURL)
    _ = await settleUntil {
      if case .ready = coordinator.state { return true } else { return false }
    }
    coordinator.start()
    _ = await settleUntil {
      if case .rejected = coordinator.state { return true } else { return false }
    }

    #expect(telemetry.calls.count == 1)
    #expect(telemetry.calls.first?.outcome == .asrFailed)
    #expect(telemetry.calls.first?.asrOutcome == .failed)
    #expect(telemetry.calls.first?.polishOutcome == nil)
    #expect(sentry.callCount == 1)
    #expect(sentry.lastBackend == .parakeet)
  }

  @Test("cancelling a run (Stop) never reports asr_failed or a Sentry capture")
  func cancellationNeverReportsAsFailure() async {
    let telemetry = RunTelemetryRecorder()
    let sentry = SentryFailureRecorder()
    let transcription = TranscriptionEntrySignal()
    let coordinator = makeCoordinator(
      lease: EngineLease(),
      transcribe: { _ in
        await transcription.markEntered()
        try await Task.sleep(for: .seconds(30))  // settle: cancelled by stop() below, never reached
        return "unreachable"
      },
      emitRunTelemetry: { outcome, _, _, asrOutcome, polishOutcome, _, _ in
        telemetry.record(outcome: outcome, asrOutcome: asrOutcome, polishOutcome: polishOutcome)
      },
      captureASRFailure: { _, backend in
        sentry.record(backend: backend)
      })

    coordinator.choose(url: Self.anyURL)
    _ = await settleUntil {
      if case .ready = coordinator.state { return true } else { return false }
    }
    coordinator.start()
    #expect(
      await settleUntil { await transcription.entered },
      "the test must cancel an ASR invocation that actually started")

    coordinator.stop()
    #expect(
      await settleUntil { coordinator.isEngineHeld == false },
      "the cancelled run must finish unwinding")

    #expect(telemetry.calls.isEmpty, "a user-initiated Stop must never read as an ASR failure")
    #expect(sentry.callCount == 0)
  }

  // MARK: - Polish outcome aggregation

  @Test("all parts polished successfully reports polish_outcome success, with provider and model")
  func allPartsPolishedReportsSuccess() async {
    let telemetry = RunTelemetryRecorder()
    let coordinator = makeCoordinator(
      lease: EngineLease(), polishProvider: .ollama,
      emitRunTelemetry: { outcome, _, _, asrOutcome, polishOutcome, provider, model in
        telemetry.record(outcome: outcome, asrOutcome: asrOutcome, polishOutcome: polishOutcome)
        #expect(provider == .ollama)
        #expect(model == "eg-1")
      })

    coordinator.choose(url: Self.anyURL)
    _ = await settleUntil {
      if case .ready = coordinator.state { return true } else { return false }
    }
    coordinator.start()
    _ = await settleUntil { coordinator.state == .finished }

    #expect(telemetry.calls.last?.outcome == .success)
    #expect(telemetry.calls.last?.asrOutcome == .success)
    #expect(telemetry.calls.last?.polishOutcome == .success)
  }

  @Test("a part whose polish attempt threw counts toward failed, never skipped")
  func aThrownPartCountsAsAttempted() async {
    let telemetry = RunTelemetryRecorder()
    struct PolishError: Error {}
    let coordinator = makeCoordinator(
      lease: EngineLease(),
      processPart: { _ in throw PolishError() },
      emitRunTelemetry: { outcome, _, _, asrOutcome, polishOutcome, _, _ in
        telemetry.record(outcome: outcome, asrOutcome: asrOutcome, polishOutcome: polishOutcome)
      })

    coordinator.choose(url: Self.anyURL)
    _ = await settleUntil {
      if case .ready = coordinator.state { return true } else { return false }
    }
    coordinator.start()
    _ = await settleUntil { coordinator.state == .finished }

    #expect(
      telemetry.calls.last?.outcome == .success,
      "the document still saves; only the polish limb failed")
    #expect(telemetry.calls.last?.polishOutcome == .failed)
  }
}
