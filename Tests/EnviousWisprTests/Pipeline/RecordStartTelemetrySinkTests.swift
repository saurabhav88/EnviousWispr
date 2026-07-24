import Foundation
import Testing

@testable import EnviousWisprPipeline

/// Dual-channel parity freeze for the record-start VAD markers (#1780).
///
/// The whole diagnostic value of these markers depends on BOTH channels firing:
/// the Sentry breadcrumb is what survives inside a crash report (it is how
/// #1780 was reconstructed), the PostHog event is what answers the fleet
/// question. A marker that emits only one is a defect, so each test asserts
/// exactly one of each and no extras.
///
/// Spies are per-instance injected closures, never the process-global
/// `SentryBreadcrumb.breadcrumbDelegate` or `TelemetryService.testEventHook`
/// (`swift-patterns.md` RULE: tests-no-process-global-mutable-delegate).
@MainActor
@Suite("Record-start VAD telemetry parity (#1780)")
struct RecordStartTelemetrySinkTests {

  @MainActor
  private final class Spy {
    var breadcrumbs: [(stage: String, message: String, data: [String: Any])] = []
    var preparation: [(String, String, Bool, Bool)] = []
    var chunkStarted: [(String, String, Double)] = []
    var chunkCompleted: [(String, String, Double, Bool)] = []

    func makeSink() -> RecordStartTelemetrySink {
      RecordStartTelemetrySink(
        breadcrumb: { [self] stage, message, data in
          breadcrumbs.append((stage, message, data))
        },
        emitPreparation: { [self] b, r, ready, reused in
          preparation.append((b, r, ready, reused))
        },
        emitChunkStarted: { [self] b, r, ms in chunkStarted.append((b, r, ms)) },
        emitChunkCompleted: { [self] b, r, ms, stop in
          chunkCompleted.append((b, r, ms, stop))
        })
    }
  }

  @Test("preparation_completed emits one breadcrumb and one event")
  func preparationParity() {
    let spy = Spy()
    spy.makeSink().vadPreparationCompleted(
      backend: "parakeet", inputRoute: "built_in_mic", ready: true, modelReused: true)

    #expect(spy.breadcrumbs.count == 1)
    #expect(spy.preparation.count == 1)
    #expect(spy.chunkStarted.isEmpty)
    #expect(spy.chunkCompleted.isEmpty)

    let crumb = try! #require(spy.breadcrumbs.first)
    #expect(crumb.stage == "vad")
    #expect(crumb.message == "vad#preparation_completed")
    #expect(crumb.data["backend"] as? String == "parakeet")
    #expect(crumb.data["input_route"] as? String == "built_in_mic")
    #expect(crumb.data["ready"] as? Bool == true)
    #expect(crumb.data["model_reused"] as? Bool == true)
    #expect(crumb.data.count == 4)

    let emitted = try! #require(spy.preparation.first)
    #expect(emitted.0 == "parakeet")
    #expect(emitted.1 == "built_in_mic")
    #expect(emitted.2 == true)
    #expect(emitted.3 == true)
  }

  @Test("first_chunk_started emits one breadcrumb and one event")
  func chunkStartedParity() {
    let spy = Spy()
    spy.makeSink().firstChunkStarted(
      backend: "whisperKit", inputRoute: "bluetooth", monitorToFirstChunkMs: 7.5)

    #expect(spy.breadcrumbs.count == 1)
    #expect(spy.chunkStarted.count == 1)
    #expect(spy.preparation.isEmpty)
    #expect(spy.chunkCompleted.isEmpty)

    let crumb = try! #require(spy.breadcrumbs.first)
    #expect(crumb.stage == "vad")
    #expect(crumb.message == "vad#first_chunk_started")
    #expect(crumb.data["backend"] as? String == "whisperKit")
    #expect(crumb.data["input_route"] as? String == "bluetooth")
    #expect(crumb.data["monitor_to_first_chunk_ms"] as? Double == 7.5)
    #expect(crumb.data.count == 3)

    let emitted = try! #require(spy.chunkStarted.first)
    #expect(emitted.0 == "whisperKit")
    #expect(emitted.1 == "bluetooth")
    #expect(emitted.2 == 7.5)
  }

  @Test("first_chunk_completed emits one breadcrumb and one event")
  func chunkCompletedParity() {
    let spy = Spy()
    spy.makeSink().firstChunkCompleted(
      backend: "parakeet", inputRoute: "built_in_mic",
      chunkProcessingLatencyMs: 2.25, shouldStop: true)

    #expect(spy.breadcrumbs.count == 1)
    #expect(spy.chunkCompleted.count == 1)
    #expect(spy.preparation.isEmpty)
    #expect(spy.chunkStarted.isEmpty)

    let crumb = try! #require(spy.breadcrumbs.first)
    #expect(crumb.stage == "vad")
    #expect(crumb.message == "vad#first_chunk_completed")
    #expect(crumb.data["backend"] as? String == "parakeet")
    #expect(crumb.data["input_route"] as? String == "built_in_mic")
    #expect(crumb.data["chunk_processing_latency_ms"] as? Double == 2.25)
    #expect(crumb.data["should_stop"] as? Bool == true)
    #expect(crumb.data.count == 4)

    let emitted = try! #require(spy.chunkCompleted.first)
    #expect(emitted.0 == "parakeet")
    #expect(emitted.1 == "built_in_mic")
    #expect(emitted.2 == 2.25)
    #expect(emitted.3 == true)
  }
}
