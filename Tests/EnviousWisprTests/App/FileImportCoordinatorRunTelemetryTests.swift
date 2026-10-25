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

  /// #3546 Chunk 12 whole-PR review r4: an import that reloads an idle-unloaded Whisper
  /// directly leaves the adapter's cached readiness stale. When this fails, that import's
  /// `file_import_completed` row carries no model at all.
  @Test("the frozen model falls back to Whisper's validated identity, and never crosses engines")
  func frozenASRModelResolution() {
    let whisper = ASRModelIdentity(name: "whisperkit-coreml", revision: "97a5bf9b", variant: "small")
    let ultra = ASRModelIdentity(name: "parakeet-ultra-coreml", revision: "95eaa59a", variant: "int8")
    let validated = ASRModelAttribution(identity: whisper, loaded: false, inferenceReached: false)
    let serving = ASRModelAttribution(identity: ultra, loaded: true, inferenceReached: false)
    #expect(
      FileImportSettingsFreeze.frozenASRModel(
        backend: .whisper, parakeetServing: serving, whisperServing: nil,
        whisperValidated: validated) == whisper,
      "stale Whisper cache: the validated identity")
    #expect(
      FileImportSettingsFreeze.frozenASRModel(
        backend: .parakeet, parakeetServing: nil, whisperServing: nil,
        whisperValidated: validated) == nil,
      "a Parakeet import never borrows Whisper's identity")
    #expect(
      FileImportSettingsFreeze.frozenASRModel(
        backend: .parakeet, parakeetServing: serving, whisperServing: nil,
        whisperValidated: nil) == ultra)
  }

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
    observedTranscribe: (@MainActor ([Float], ASRInferenceEntryObserver?) async throws -> String)? =
      nil,
    processPart: @escaping @MainActor (String) async throws -> FileImportRunner.PartOutcome = {
      FileImportRunner.PartOutcome(text: $0, polishedText: $0)
    },
    polishProvider: LLMProvider = .egOne,
    asrModel: ASRModelIdentity? = nil,
    emitRunTelemetry:
      @escaping @MainActor (
        TelemetryService.FileImportRunOutcome, ASRBackendType, ASRModelAttribution?, TimeInterval,
        TelemetryService.FileImportASROutcome?, TelemetryService.FileImportPolishOutcome?,
        LLMProvider?, String?
      ) -> Void = { _, _, _, _, _, _, _, _ in },
    captureASRFailure: @escaping @MainActor (any Error, ASRBackendType) -> Void = { _, _ in },
    updateHistoryRow: @escaping @MainActor (Transcript) async throws -> Bool = { _ in true }
  ) -> FileImportCoordinator {
    FileImportCoordinator(
      decode: { _ in Self.decoded(seconds: 1.0) },
      transcribe: { samples, _, onInferenceEntered in
        let text =
          if let observedTranscribe {
            try await observedTranscribe(samples, onInferenceEntered)
          } else {
            try await transcribe(samples)
          }
        return ASRResult(
          text: text, language: nil, duration: 0, processingTime: 0, backendType: .parakeet)
      },
      emitRunTelemetry: emitRunTelemetry,
      captureASRFailure: captureASRFailure,
      engineAdmission: .live(lease: lease, as: .fileImport),
      beginRun: {
        FileImportCoordinator.RunConfiguration(
          polishIsCloud: false, localPolishProvider: nil, polishProvider: polishProvider,
          ollamaModel: nil, polishModel: "eg-1", backendType: .parakeet, asrModel: asrModel)
      },
      saveToHistory: { _ in },
      updateHistoryRow: updateHistoryRow,
      mergeSpeakerFields: { _, _, _ in true },
      historyRowExists: { _ in true },
      processParts: serialFileImportTestProcessor { part, _ in try await processPart(part) })
  }

  // MARK: - #3546 model attribution

  @MainActor
  private final class CoordinatorBox {
    var models: [ASRModelAttribution?] = []
    var observers: [ASRInferenceEntryObserver?] = []
  }

  /// #3546 §3.7 T1: a failed run's `asr_model_inference_reached` comes from the engine's own
  /// signal, not the outcome. The failed-AFTER-entry arm is the population this field exists
  /// to expose; the failed-before-entry arm is its control.
  @Test(
    "a failed run reports inference reached only when the engine entered its decode",
    arguments: [false, true])
  func failedRunInferenceFollowsTheEngine(enteredBeforeFailing: Bool) async throws {
    struct EngineError: Error {}
    let ultra = ASRModelIdentity(
      name: "parakeet-ultra-coreml", revision: "95eaa59a", variant: "int8")
    let box = CoordinatorBox()
    let coordinator = makeCoordinator(
      lease: EngineLease(),
      observedTranscribe: { _, onInferenceEntered in
        if enteredBeforeFailing { onInferenceEntered?() }
        throw EngineError()
      },
      asrModel: ultra,
      emitRunTelemetry: { _, _, model, _, _, _, _, _ in box.models.append(model) })

    coordinator.choose(url: Self.anyURL)
    _ = await settleUntil {
      if case .ready = coordinator.state { return true } else { return false }
    }
    coordinator.start()
    _ = await settleUntil {
      if case .rejected = coordinator.state { return true } else { return false }
    }

    #expect(box.models.count == 1)
    let model = try #require(box.models.first ?? nil)
    #expect(model.identity == ultra)
    #expect(model.loaded == true)
    #expect(model.inferenceReached == enteredBeforeFailing)
  }

  /// #3546 §3.7 T1: each run's observation is bound to that run's generation, so one that
  /// fires after a newer run started is dropped. When this fails, a run that never decoded
  /// reports `asr_model_inference_reached: true` because an older run's engine did.
  @Test("an older run's late inference observation never marks a newer run")
  func lateObservationFromAnOlderRunIsDropped() async throws {
    struct EngineError: Error {}
    let box = CoordinatorBox()
    let coordinator = makeCoordinator(
      lease: EngineLease(),
      observedTranscribe: { _, onInferenceEntered in
        box.observers.append(onInferenceEntered)
        // The second run fires the FIRST run's observation, then fails before its own.
        if box.observers.count == 2, let older = box.observers[0] { older() }
        throw EngineError()
      },
      asrModel: ASRModelIdentity(name: "parakeet-ultra-coreml", revision: nil, variant: nil),
      emitRunTelemetry: { _, _, model, _, _, _, _, _ in box.models.append(model) })

    for _ in 0..<2 {
      coordinator.choose(url: Self.anyURL)
      _ = await settleUntil {
        if case .ready = coordinator.state { return true } else { return false }
      }
      coordinator.start()
      _ = await settleUntil {
        if case .rejected = coordinator.state { return true } else { return false }
      }
    }

    #expect(box.observers.count == 2)
    #expect(box.observers.allSatisfy { $0 != nil }, "each run passed its own observation")
    #expect(box.models.count == 2)
    #expect(box.models.map { $0?.inferenceReached } == [false, false])
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
      emitRunTelemetry: { outcome, _, _, _, asrOutcome, polishOutcome, _, _ in
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
      emitRunTelemetry: { outcome, _, _, _, asrOutcome, polishOutcome, _, _ in
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
      emitRunTelemetry: { outcome, _, _, _, asrOutcome, polishOutcome, provider, model in
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
      emitRunTelemetry: { outcome, _, _, _, asrOutcome, polishOutcome, _, _ in
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

  @Test(
    "a failed FINAL write reports history_save_failed, never a false success (#3069 cloud review)")
  func polishedSaveFailureReportsHistorySaveFailed() async {
    let telemetry = RunTelemetryRecorder()
    struct WriteError: Error {}
    let coordinator = makeCoordinator(
      lease: EngineLease(),
      emitRunTelemetry: { outcome, _, _, _, asrOutcome, polishOutcome, _, _ in
        telemetry.record(outcome: outcome, asrOutcome: asrOutcome, polishOutcome: polishOutcome)
      },
      updateHistoryRow: { _ in throw WriteError() })

    coordinator.choose(url: Self.anyURL)
    _ = await settleUntil {
      if case .ready = coordinator.state { return true } else { return false }
    }
    coordinator.start()
    _ = await settleUntil { coordinator.state == .finished }

    #expect(
      telemetry.calls.last?.outcome == .historySaveFailed,
      "the RAW words saved fine, but the cleaned document's own write failed — that must not read as success"
    )
    #expect(telemetry.calls.last?.polishOutcome == nil)
  }
}
