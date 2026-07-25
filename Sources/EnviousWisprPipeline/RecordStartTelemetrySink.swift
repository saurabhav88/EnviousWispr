import EnviousWisprServices
import Foundation

/// Emits the three record-start VAD stage markers (#1780) to BOTH channels.
///
/// Why both: a Sentry breadcrumb travels inside the crash report, so it is the
/// authoritative crash-local sequence — that is what let #1780 be reconstructed
/// at all. A PostHog event answers the fleet question ("where do recordings
/// normally reach or drop out"). `sentry-operations.md`
/// RULE: sentry-for-bugs-posthog-for-behaviour permits exactly this pairing:
/// it forbids turning non-bugs into alerting Sentry *errors*, not non-alerting
/// diagnostic breadcrumbs alongside counted events.
///
/// Ownership boundary: this type owns the three breadcrumb messages and the
/// one-breadcrumb-plus-one-event parity rule. `TelemetryService` remains the
/// sole authority for the exact PostHog event names and property
/// serialization. Observation of the physical boundaries stays with
/// `CaptureVADSignalSource` and `VADMonitorLoop`; this type only routes the
/// facts they report.
///
/// Deliberately stateless: no session identity, no lifecycle, no detector
/// state, no orchestration. Callers own the monitor-generation validity check
/// and must perform it immediately before every call.
@MainActor
final class RecordStartTelemetrySink {
  /// Injected so tests observe per-instance, never through the process-global
  /// `SentryBreadcrumb.breadcrumbDelegate` (`swift-patterns.md`
  /// RULE: tests-no-process-global-mutable-delegate).
  typealias BreadcrumbSink = @MainActor (
    _ stage: String, _ message: String, _ data: [String: Any]
  ) -> Void

  typealias PreparationSink = @MainActor (
    _ backend: String, _ inputRoute: String, _ ready: Bool, _ modelReused: Bool
  ) -> Void

  typealias ChunkStartedSink = @MainActor (
    _ backend: String, _ inputRoute: String, _ monitorToFirstChunkMs: Double
  ) -> Void

  typealias ChunkCompletedSink = @MainActor (
    _ backend: String, _ inputRoute: String, _ chunkProcessingLatencyMs: Double,
    _ shouldStop: Bool
  ) -> Void

  private let breadcrumb: BreadcrumbSink
  private let emitPreparation: PreparationSink
  private let emitChunkStarted: ChunkStartedSink
  private let emitChunkCompleted: ChunkCompletedSink

  init(
    // `level: .info` is passed explicitly rather than relying on
    // `SentryBreadcrumb.add`'s default, matching `KernelLifecycleTelemetrySink`:
    // these are diagnostic stage markers, never alerting errors.
    breadcrumb: @escaping BreadcrumbSink = { stage, message, data in
      SentryBreadcrumb.add(stage: stage, message: message, level: .info, data: data)
    },
    emitPreparation: @escaping PreparationSink = { backend, inputRoute, ready, modelReused in
      TelemetryService.shared.dictationVADPreparationCompleted(
        backend: backend, inputRoute: inputRoute, ready: ready, modelReused: modelReused)
    },
    emitChunkStarted: @escaping ChunkStartedSink = { backend, inputRoute, monitorMs in
      TelemetryService.shared.dictationFirstVADChunkStarted(
        backend: backend, inputRoute: inputRoute, monitorToFirstChunkMs: monitorMs)
    },
    emitChunkCompleted: @escaping ChunkCompletedSink = {
      backend, inputRoute, latencyMs, shouldStop in
      TelemetryService.shared.dictationFirstVADChunkCompleted(
        backend: backend, inputRoute: inputRoute,
        chunkProcessingLatencyMs: latencyMs, shouldStop: shouldStop)
    }
  ) {
    self.breadcrumb = breadcrumb
    self.emitPreparation = emitPreparation
    self.emitChunkStarted = emitChunkStarted
    self.emitChunkCompleted = emitChunkCompleted
  }

  /// Readiness evaluation returned, immediately before monitor entry.
  func vadPreparationCompleted(
    backend: String,
    inputRoute: String,
    ready: Bool,
    modelReused: Bool
  ) {
    breadcrumb(
      "vad", "vad#preparation_completed",
      [
        "backend": backend,
        "input_route": inputRoute,
        "ready": ready,
        "model_reused": modelReused,
      ])
    emitPreparation(backend, inputRoute, ready, modelReused)
  }

  /// Immediately before the first `SilenceDetector.processChunk` await.
  func firstChunkStarted(
    backend: String,
    inputRoute: String,
    monitorToFirstChunkMs: Double
  ) {
    breadcrumb(
      "vad", "vad#first_chunk_started",
      [
        "backend": backend,
        "input_route": inputRoute,
        "monitor_to_first_chunk_ms": monitorToFirstChunkMs,
      ])
    emitChunkStarted(backend, inputRoute, monitorToFirstChunkMs)
  }

  /// Immediately after that await returns.
  func firstChunkCompleted(
    backend: String,
    inputRoute: String,
    chunkProcessingLatencyMs: Double,
    shouldStop: Bool
  ) {
    breadcrumb(
      "vad", "vad#first_chunk_completed",
      [
        "backend": backend,
        "input_route": inputRoute,
        "chunk_processing_latency_ms": chunkProcessingLatencyMs,
        "should_stop": shouldStop,
      ])
    emitChunkCompleted(backend, inputRoute, chunkProcessingLatencyMs, shouldStop)
  }
}
