import Foundation
import Testing

@testable import EnviousWisprServices

/// Schema freeze for the three record-start VAD markers (#1780).
///
/// These assert the exact PostHog event names, keys, values and typed buckets
/// that `TelemetryService` owns. The sink parity tests deliberately do NOT
/// cover this: they prove one-breadcrumb-plus-one-call, not the names or
/// serialization, which live here.
///
/// `.serialized` because `testEventHook` is process-global; concurrent suites
/// would cross-capture (`swift-patterns.md`
/// RULE: tests-no-process-global-mutable-delegate applies to production code —
/// this hook is a DEBUG-only test seam, so serialize rather than inject).
#if DEBUG
  @MainActor
  @Suite("Record-start VAD telemetry schema (#1780)", .serialized)
  struct RecordStartTelemetryServiceTests {

    /// Captures exactly the events emitted inside `body`, then always restores
    /// the global hook so a failure cannot leak into a sibling suite.
    private func capture(
      _ body: () -> Void
    ) -> [CapturedTelemetryEvent] {
      let box = EventBox()
      TelemetryService.shared.testEventHook = { event in box.append(event) }
      defer { TelemetryService.shared.testEventHook = nil }
      body()
      return box.events
    }

    /// Locked to match `DictationInvokedTelemetryTests.EventBox`: the hook is
    /// `@Sendable`, so `@unchecked Sendable` must be backed by real
    /// synchronisation rather than an assumption about call-site threading.
    private final class EventBox: @unchecked Sendable {
      private let lock = NSLock()
      private var stored: [CapturedTelemetryEvent] = []

      func append(_ event: CapturedTelemetryEvent) {
        lock.withLock { stored.append(event) }
      }

      var events: [CapturedTelemetryEvent] {
        lock.withLock { stored }
      }
    }

    @Test("preparation_completed emits its exact schema")
    func preparationSchema() {
      let events = capture {
        TelemetryService.shared.dictationVADPreparationCompleted(
          backend: "parakeet", inputRoute: "built_in_mic", ready: true, modelReused: false)
      }

      #expect(events.count == 1)
      let e = try! #require(events.first)
      #expect(e.name == "dictation.vad_preparation_completed")
      #expect(e.stringProps == ["backend": "parakeet", "input_route": "built_in_mic"])
      #expect(e.boolProps == ["ready": true, "model_reused": false])
      #expect(e.intProps.isEmpty)
      #expect(e.doubleProps.isEmpty)
    }

    @Test("first_vad_chunk_started emits its exact schema")
    func chunkStartedSchema() {
      let events = capture {
        TelemetryService.shared.dictationFirstVADChunkStarted(
          backend: "whisperKit", inputRoute: "bluetooth", monitorToFirstChunkMs: 12.5)
      }

      #expect(events.count == 1)
      let e = try! #require(events.first)
      #expect(e.name == "dictation.first_vad_chunk_started")
      #expect(e.stringProps == ["backend": "whisperKit", "input_route": "bluetooth"])
      #expect(e.doubleProps == ["monitor_to_first_chunk_ms": 12.5])
      #expect(e.boolProps.isEmpty)
      #expect(e.intProps.isEmpty)
    }

    @Test("first_vad_chunk_completed emits its exact schema")
    func chunkCompletedSchema() {
      let events = capture {
        TelemetryService.shared.dictationFirstVADChunkCompleted(
          backend: "parakeet", inputRoute: "built_in_mic",
          chunkProcessingLatencyMs: 3.25, shouldStop: false)
      }

      #expect(events.count == 1)
      let e = try! #require(events.first)
      #expect(e.name == "dictation.first_vad_chunk_completed")
      #expect(e.stringProps == ["backend": "parakeet", "input_route": "built_in_mic"])
      #expect(e.doubleProps == ["chunk_processing_latency_ms": 3.25])
      #expect(e.boolProps == ["should_stop": false])
      #expect(e.intProps.isEmpty)
    }
  }
#endif
