import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprServices

/// #3546 §3.7 T1: which speech model a take used rides on every row the plan names, with the
/// same five keys, and an unknown model sends none of them. When this fails, a rollout reader
/// grouping by `asr_model` loses rows or reads a guessed model.
@Suite("ASR model attribution keys (#3546)", .tags(.observabilityContract))
struct ASRModelAttributionPropertiesTests {
  static let ultra = ASRModelIdentity(
    name: "parakeet-ultra-coreml", revision: "95eaa59a39d4394f047a4dc5cce480388a60d1b6",
    variant: "int8")

  @Test("the five keys carry the manifest name, an eight-character revision, and the two flags")
  func properties() {
    let props = ASRModelAttribution(identity: Self.ultra, loaded: true, inferenceReached: false)
      .telemetryProperties
    #expect(Set(props.keys) == Set(ASRModelAttribution.telemetryKeys))
    #expect(props["asr_model"] as? String == "parakeet-ultra-coreml")
    #expect(props["asr_model_revision"] as? String == "95eaa59a")
    #expect(props["asr_model_variant"] as? String == "int8")
    #expect(props["asr_model_loaded"] as? Bool == true)
    #expect(props["asr_model_inference_reached"] as? Bool == false)
  }

  @Test("a missing revision or variant is omitted, never sent empty")
  func missingPartsAreOmitted() {
    let identity = ASRModelIdentity(name: "parakeet-ultra-coreml", revision: nil, variant: nil)
    let props = ASRModelAttribution(identity: identity, loaded: false, inferenceReached: false)
      .telemetryProperties
    #expect(props["asr_model_revision"] == nil)
    #expect(props["asr_model_variant"] == nil)
    #expect(props.count == 3)
  }

  @Test("a Parakeet request names its manifest identity")
  func parakeetSelectionIdentity() {
    let selection = ParakeetModelSelection(
      model: .v3, revision: "aed02740059203c4a87495924f685de3722ae9ce",
      directory: URL(fileURLWithPath: "/tmp/x"), cacheOnly: true, displayBytes: 1,
      repairable: false, generation: 1)
    #expect(
      selection.modelIdentity
        == ASRModelIdentity(
          name: "parakeet-tdt-0.6b-v3-coreml", revision: "aed02740", variant: "int8"))
  }
}

#if DEBUG
  /// #3546 §3.7 T1: the test hook of every attributed emitter, fed the same attribution, shows
  /// the same keys; fed nil, none. Each row is a separate emitter with its own property code, so
  /// one emitter forgetting the merge fails here by name.
  @MainActor
  @Suite(
    "ASR model attribution on every attributed row (#3546)", .serialized,
    .tags(.observabilityContract))
  struct ASRModelAttributionRowTests {
    final class Box: @unchecked Sendable {
      // Test-only capture box; the hook is called synchronously inside each emit.
      var events: [CapturedTelemetryEvent] = []
    }

    static let model = ASRModelAttribution(
      identity: ASRModelAttributionPropertiesTests.ultra, loaded: true, inferenceReached: true)
    static let take = "D3B6682C-A4F7-47DB-A6D9-F6B0283DD651"

    /// Every attributed emitter, called once with `model`. The names are the events' own.
    static func emitAll(_ service: TelemetryService, model: ASRModelAttribution?) {
      service.dictationStarted(takeID: take, backend: "parakeet", model: model)
      service.dictationTerminal(
        takeID: take, backend: "parakeet", result: "completed", reason: nil, model: model)
      service.dictationCompleted(
        result: "success", inputMode: "ptt", asrBackend: "parakeet", model: model,
        llmProvider: nil, fillerRemoval: false, targetApp: nil, pasteResult: nil,
        e2eSeconds: 1, asrSeconds: nil, llmSeconds: nil, takeID: take)
      service.coldStartWarmupStarted(
        engine: "parakeet", reason: "launch", warmupInFlight: false, model: model)
      service.coldStartWarmupCompleted(
        engine: "parakeet", reason: "launch", durationMs: 10, model: model)
      service.coldStartWarmupFailed(
        engine: "parakeet", reason: "launch", error: "X#1", model: model)
      service.coldStartPressBlocked(asrBackend: "parakeet", warmupInFlight: true, model: model)
      service.appIdleMemory(
        footprintMB: 1, minutesSinceLaunch: 12, wordCheckLoaded: false, wordCheckWanted: false,
        model: model)
      service.trackFileImportCompleted(
        outcome: .success, asrBackend: .parakeet, model: model, durationSeconds: 5)
      service.escapeRecoveryStarted(
        asrBackend: "parakeet", polishProvider: "none", recordingDurationMs: 100, takeID: take,
        model: model)
      service.escapeRecoveryCompleted(
        outcome: .saved, asrDurationMs: nil, polishDurationMs: nil, durationMs: nil,
        asrBackend: nil, takeID: take, model: model)
      service.asrRetryDeadlineStarted(
        takeID: take, asrBackend: "parakeet", budgetMs: 8000, model: model)
      service.asrRetryDeadlineResolved(
        takeID: take, asrBackend: "parakeet", budgetMs: 8000, resolution: .operationReturned,
        disposition: .accepted, operationReturnMs: 10, callerResumeMs: 11,
        acceptedAfterCutoff: false, model: model)
      service.transcriptionInterruptedAtQuit(
        stage: "decode_started", backend: "parakeet", chunksScheduled: 0, stageAgeMs: 5,
        checkpointAppVersion: "2.5.4", model: model)
    }

    static let expectedRows: [String] = [
      "dictation.started", "dictation.terminal", "dictation.completed",
      "coldstart.warmup_started", "coldstart.warmup_completed", "coldstart.warmup_failed",
      "coldstart.press_blocked", "app.idle_memory", "file_import_completed",
      "escape_recovery.started", "escape_recovery.completed", "asr.retry_deadline_observed",
      "asr.retry_deadline_observed", "transcription.interrupted_at_quit",
    ]

    func capture(model: ASRModelAttribution?) -> [CapturedTelemetryEvent] {
      let box = Box()
      let service = TelemetryService.shared
      let previous = service.testEventHook
      service.testEventHook = { box.events.append($0) }
      defer { service.testEventHook = previous }
      Self.emitAll(service, model: model)
      return box.events.filter { Self.expectedRows.contains($0.name) }
    }

    @Test("each attributed row carries all five model keys with the given values")
    func everyRowCarriesTheModel() {
      let events = capture(model: Self.model)
      #expect(events.map(\.name) == Self.expectedRows)
      for event in events {
        #expect(event.stringProps["asr_model"] == "parakeet-ultra-coreml", "\(event.name)")
        #expect(event.stringProps["asr_model_revision"] == "95eaa59a", "\(event.name)")
        #expect(event.stringProps["asr_model_variant"] == "int8", "\(event.name)")
        #expect(event.boolProps["asr_model_loaded"] == true, "\(event.name)")
        #expect(event.boolProps["asr_model_inference_reached"] == true, "\(event.name)")
      }
    }

    @Test("an unknown model sends no model key on any row")
    func unknownModelSendsNothing() {
      let events = capture(model: nil)
      #expect(events.map(\.name) == Self.expectedRows)
      for event in events {
        let keys = Set(event.stringProps.keys).union(event.boolProps.keys)
        #expect(keys.isDisjoint(with: ASRModelAttribution.telemetryKeys), "\(event.name)")
      }
    }
  }
#endif
