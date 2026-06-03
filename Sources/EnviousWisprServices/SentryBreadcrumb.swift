import EnviousWisprCore
import Foundation
import Sentry

/// Thin, type-safe Sentry breadcrumb + error helper for pipeline instrumentation.
/// Limb: all methods are fire-and-forget — a Sentry call failure never blocks the pipeline.
@MainActor
public enum SentryBreadcrumb {

  // MARK: - Recording Snapshot (for handled errors)

  /// Immutable point-in-time snapshot frozen before recording teardown.
  /// Attached directly to handled errors so post-recording events carry full context
  /// even after the global scope's recording_state is cleared.
  public struct RecordingSnapshot: Sendable {
    public let backend: String
    public let audioRoute: String
    public let wasStreaming: Bool
    public let startTime: Date
    public let durationMs: Int
    public let targetAppBundleID: String?
    public let transcriptCharCount: Int
    public let transcriptWordCount: Int

    public init(
      backend: String,
      audioRoute: String,
      wasStreaming: Bool,
      startTime: Date,
      durationMs: Int,
      targetAppBundleID: String?,
      transcriptCharCount: Int = 0,
      transcriptWordCount: Int = 0
    ) {
      self.backend = backend
      self.audioRoute = audioRoute
      self.wasStreaming = wasStreaming
      self.startTime = startTime
      self.durationMs = durationMs
      self.targetAppBundleID = targetAppBundleID
      self.transcriptCharCount = transcriptCharCount
      self.transcriptWordCount = transcriptWordCount
    }

    var sentryContext: [String: Any] {
      var ctx: [String: Any] = [
        "backend": backend,
        "audio_route": audioRoute,
        "was_streaming": wasStreaming,
        "start_time": ISO8601DateFormatter().string(from: startTime),
        "duration_ms": durationMs,
        "transcript_char_count": transcriptCharCount,
        "transcript_word_count": transcriptWordCount,
      ]
      if let targetAppBundleID {
        ctx["target_app_bundle_id"] = targetAppBundleID
      }
      return ctx
    }
  }

  // MARK: - Persistent Global Scope (crash-relevant state)

  /// Update the active ASR backend tag. Called when user switches backend or at pipeline start.
  public static func updateASRBackend(_ backend: String) {
    SentrySDK.configureScope { scope in
      scope.setTag(value: backend, key: "asr.backend")
    }
  }

  /// Update the audio route tag. Called when capture route is resolved or changes.
  /// Values are low-cardinality: built_in_mic, bt_headset, capture_session, audio_engine, unknown.
  public static func updateAudioRoute(_ route: String) {
    SentrySDK.configureScope { scope in
      scope.setTag(value: route, key: "audio.route")
    }
  }

  /// Update recording state on global scope. Present on fatal crashes.
  /// - Parameters:
  ///   - active: Whether recording is in progress.
  ///   - backend: "parakeet" or "whisperkit" (nil when stopping).
  ///   - isStreaming: Whether streaming ASR is active (nil when stopping).
  public static func updateRecordingState(
    active: Bool,
    backend: String? = nil,
    isStreaming: Bool? = nil
  ) {
    SentrySDK.configureScope { scope in
      scope.setTag(value: active ? "true" : "false", key: "recording.active")
      if active, let backend {
        scope.setContext(
          value: [
            "backend": backend,
            "start_time": ISO8601DateFormatter().string(from: Date()),
            "is_streaming": isStreaming ?? false,
          ], key: "recording_state")
      } else {
        scope.removeContext(key: "recording_state")
      }
    }
  }

  // MARK: - Breadcrumbs

  /// Add a structured breadcrumb at a pipeline stage boundary.
  /// - Parameters:
  ///   - stage: Pipeline stage (e.g. "recording", "asr", "polish", "paste")
  ///   - message: Human-readable description (no PII — no transcript text)
  ///   - level: Sentry level (default .info)
  ///   - data: Structured key-value pairs (provider, duration, outcome, etc.)
  public static func add(
    stage: String,
    message: String,
    level: SentryLevel = .info,
    data: [String: Any]? = nil
  ) {
    let crumb = Breadcrumb(level: level, category: "pipeline.\(stage)")
    crumb.message = message
    crumb.type = "default"
    if let data {
      crumb.data = data
    }
    SentrySDK.addBreadcrumb(crumb)
  }

  // MARK: - Handled Errors

  /// Capture a handled error with pipeline context tags.
  /// Use for failures that don't crash the app but should be diagnosable in Sentry.
  /// - Parameters:
  ///   - error: The error that occurred.
  ///   - category: Structured error category for filtering.
  ///   - stage: Pipeline stage where the error occurred.
  ///   - extra: Additional key-value pairs for this specific event.
  ///   - snapshot: Optional point-in-time recording state (attached via scope clone).
  public static func captureError(
    _ error: any Error,
    category: ErrorCategory,
    stage: String,
    extra: [String: Any]? = nil,
    snapshot: RecordingSnapshot? = nil,
    tags: [String: String] = [:]
  ) {
    let event = Event(level: .error)
    event.message = SentryMessage(formatted: "\(category.rawValue): \(error.localizedDescription)")
    var eventTags = [
      "pipeline.stage": stage,
      "error.category": category.rawValue,
    ]
    for (key, value) in tags {
      eventTags[key] = value
    }

    let eventExtra = mergedExtra(extra)

    // Test spy hooks — invoked synchronously before SDK dispatch. Production sets nil.
    Self.captureErrorTagsDelegate?(eventTags)
    Self.captureErrorDelegate?(error, category, stage, eventExtra)
    event.tags = eventTags
    if let eventExtra {
      event.extra = eventExtra
    }

    // Also add a breadcrumb so the error appears in the trail
    add(
      stage: stage,
      message: "ERROR: \(category.rawValue)",
      level: .error,
      data: eventExtra
    )

    if let snapshot {
      SentrySDK.capture(event: event) { scope in
        scope.setContext(value: snapshot.sentryContext, key: "recording_snapshot")
      }
    } else {
      SentrySDK.capture(event: event)
    }
  }

  private static func mergedExtra(_ extra: [String: Any]?) -> [String: Any]? {
    let providedEnvironment = Self.audioEnvironmentProvider?()
    guard let providedEnvironment, !providedEnvironment.isEmpty else { return extra }

    var merged = extra ?? [:]
    if merged["audio_environment"] == nil {
      merged["audio_environment"] = providedEnvironment
    }
    return merged
  }

  /// Capture a post-router Apple Intelligence polish failure with router
  /// fields on this event only. Do not write these to global Sentry scope:
  /// router attribution belongs to the failing polish event, not later
  /// unrelated errors.
  public static func captureAFMPolishError(
    _ error: any Error,
    routerMode: String,
    routerBasis: String
  ) {
    let fields: [String: Any] = [
      "polish_mode": routerMode,
      "polish_router_basis": routerBasis,
    ]
    captureError(
      error,
      category: .generationFailed,
      stage: "polish",
      extra: fields,
      tags: [
        "polish_mode": routerMode,
        "polish_router_basis": routerBasis,
      ]
    )
  }

  // MARK: - Apple Intelligence Diagnostics

  /// Attach an AI diagnostics report as persistent Sentry context + breadcrumb.
  /// Use at app launch — logs the state but does NOT fire a warning event.
  /// The report is included in every future crash/error event automatically.
  public static func attachAIDiagnostics(_ report: AppleIntelligenceAvailabilityReport) {
    add(
      stage: "ai_diagnostics", message: "AI availability check completed",
      data: report.sentryContext)

    SentrySDK.configureScope { scope in
      scope.setContext(value: report.sentryContext, key: "apple_intelligence")
    }
  }

  /// Report an AI failure that the user actually hit during dictation.
  /// Attaches a fresh diagnostics report AND fires a Sentry warning event
  /// so we can alert on real user-facing Apple Intelligence failures.
  public static func reportAIFailure(_ report: AppleIntelligenceAvailabilityReport) {
    // Update the persistent context with the fresh report
    attachAIDiagnostics(report)

    // Fire a warning event — this is a real user-facing failure, not just launch state
    let event = Event(level: .warning)
    event.message = SentryMessage(
      formatted:
        "Apple Intelligence failed during dictation: \(report.failureReasons.map(\.rawValue).joined(separator: ", "))"
    )
    event.tags = [
      "ai.overall_status": report.overallStatus.rawValue,
      "ai.failure_reasons": report.failureReasons.map(\.rawValue).joined(separator: ","),
    ]
    event.extra = report.sentryContext
    SentrySDK.capture(event: event)
  }

  // MARK: - Error Taxonomy

  /// Structured error categories for pipeline failures.
  /// Maps to Sentry tags for filtering and alerting.
  public enum ErrorCategory: String, Sendable {
    case availabilityCheckFailed = "availability_check_failed"
    case providerInitFailed = "provider_init_failed"
    case generationFailed = "generation_failed"
    case fallbackFailed = "fallback_failed"
    case pasteFailed = "paste_failed"
    case stateMismatch = "state_mismatch"
    case xpcServiceError = "xpc_service_error"
    case modelLoadFailed = "model_load_failed"
    case modelLoadWedged = "model_load_wedged"
    case audioCaptureFailed = "audio_capture_failed"
    case audioCaptureStalled = "audio_capture_stalled"
    case asrFailed = "asr_failed"
    case asrEmptyResult = "asr_empty_result"
    case heartPathFinalization = "heart_path_finalization"
    case pipelineDispatchFailed = "pipeline_dispatch_failed"
    case pipelinePostConditionFailed = "pipeline_post_condition_failed"
    /// #145: the deterministic ITN limb exceeded its 0.5s off-actor cap. Rare by
    /// construction (engine p95 ~0.1ms) — the user still gets pre-ITN text.
    case inverseNormalizationTimeout = "inverse_normalization_timeout"
  }
}

// MARK: - Test Delegate Hook

extension SentryBreadcrumb {
  public typealias AudioEnvironmentProvider = @MainActor @Sendable () -> [String: Any]?

  /// Cached audio-environment provider for handled Sentry errors.
  ///
  /// The provider must return already-collected plain data only. It must not
  /// query Core Audio, await work, or take locks on the Sentry capture path.
  public nonisolated(unsafe) static var audioEnvironmentProvider: AudioEnvironmentProvider?

  public static func withAudioEnvironmentProvider<T>(
    _ provider: AudioEnvironmentProvider?,
    _ body: () throws -> T
  ) rethrows -> T {
    let prior = audioEnvironmentProvider
    audioEnvironmentProvider = provider
    defer { audioEnvironmentProvider = prior }
    return try body()
  }

  /// Optional test-only delegate invoked synchronously on every `captureError` call
  /// before the real Sentry SDK is touched. Tests set this in `setUp`, nil in
  /// `tearDown`. Production code never reads it. Cheap alternative to a full
  /// protocol wrapper for SDK-less unit testing.
  public nonisolated(unsafe) static var captureErrorDelegate:
    (@Sendable (any Error, ErrorCategory, String, [String: Any]?) -> Void)?

  /// Optional test-only delegate for the exact tag payload that will be attached
  /// to the captured Sentry event.
  public nonisolated(unsafe) static var captureErrorTagsDelegate:
    (@Sendable ([String: String]) -> Void)?
}
