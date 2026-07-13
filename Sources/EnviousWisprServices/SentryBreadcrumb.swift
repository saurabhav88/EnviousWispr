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
  /// Values are low-cardinality: built_in_mic, hal_device_input, audio_engine, failed, unknown.
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
    // Test spy hook — invoked synchronously before SDK dispatch. Production sets nil.
    Self.breadcrumbDelegate?(stage, message, level, data)
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
  ///   - fingerprintDetail: Optional low-cardinality discriminator appended to the
  ///     grouping key. Use when a single error TYPE carries its real root cause in
  ///     an associated value the bridged `NSError` domain/code cannot see (e.g.
  ///     `LLMError.classified(reason)` — every reason shares one case index, so
  ///     without this they would all merge into one issue). Pass the stable reason
  ///     tag so each cause gets its own Sentry issue (#945).
  public static func captureError(
    _ error: any Error,
    category: ErrorCategory,
    stage: String,
    extra: [String: Any]? = nil,
    snapshot: RecordingSnapshot? = nil,
    tags: [String: String] = [:],
    fingerprintDetail: String? = nil
  ) {
    let event = Event(level: .error)
    event.message = SentryMessage(
      formatted: "\(category.rawValue): \(Self.structuredDescriptor(error))")
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

    // Group by category + underlying error signature so distinct defects that
    // share a broad category get their own stable, release-independent issue
    // instead of merging under one stacktrace bin (#1144).
    event.fingerprint = Self.handledErrorFingerprint(
      for: category, error: error, detail: fingerprintDetail)

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

  /// Structural, content-free descriptor for an error: `"<domain>#<code>"`.
  /// Used in the captured event's `message` instead of `error.localizedDescription`,
  /// which on framework errors can interpolate arbitrary OS strings. Domain and
  /// code are framework identifiers (e.g. `AVFoundationErrorDomain#-11800`), never
  /// user content — so dictation text can never reach the message surface, even if
  /// a future error type interpolated a transcript into its `localizedDescription`.
  /// See #1095. `internal` (not `private`) so the redaction tripwire can pin it.
  ///
  /// A `private` or file-scope-`private` Swift error type's bridged `NSError.domain`
  /// demangles to `…(unknown context at $<runtime-ptr>).TypeName` — long enough to trip
  /// the on-device redactor's `>100`-char heuristic (wiping the whole message to
  /// `[REDACTED]`), and the per-launch pointer fragments Sentry grouping. When the
  /// domain carries that artifact, fall back to the plain simple type name instead
  /// (#1229).
  nonisolated static func structuredDescriptor(_ error: any Error) -> String {
    let ns = error as NSError
    if ns.domain.contains("(unknown context at ") {
      return "\(type(of: error))#\(ns.code)"
    }
    return "\(ns.domain)#\(ns.code)"
  }

  /// Stable Sentry grouping key for a handled error: namespace + category + the
  /// underlying error signature (`domain#code`) + environment. The namespace avoids
  /// colliding with native-crash groups; the category is the defect class; the
  /// signature splits distinct root causes that share a broad category so they do
  /// not silently merge into one issue (#1144). The optional `detail` adds a further
  /// split for error types whose root cause lives in an associated value the
  /// bridged `domain#code` cannot distinguish (#945 — `LLMError.classified`). The
  /// trailing `environment` keeps dev-machine and real-user failures as separate,
  /// individually-alerting Sentry issues now that `structuredDescriptor` no longer
  /// carries a per-launch pointer to do that incidentally (#1229) — without it,
  /// stabilizing the descriptor would merge dev and prod into one issue, and the
  /// Sentry-triage worker only alerts on "issue created", so a real-user occurrence
  /// landing on an already-dev-created issue would never alert.
  /// `nonisolated` + pure so the non-`@MainActor` test suite calls it directly.
  /// `environment` defaults to the real bundle-derived value but is injectable so a
  /// single test process can assert both the dev and prod branches.
  nonisolated static func handledErrorFingerprint(
    for category: ErrorCategory, error: any Error, detail: String? = nil,
    environment: String = ObservabilityBootstrap.currentEnvironment
  ) -> [String] {
    var fingerprint = ["handled_error", category.rawValue, structuredDescriptor(error)]
    if let detail { fingerprint.append(detail) }
    fingerprint.append(environment)
    return fingerprint
  }

  /// Stable Sentry grouping key for the AI-availability failure event: namespace
  /// + the sorted failure-reason set (bare namespace when empty). Sorted so the
  /// key is order-independent across reports (#1144).
  nonisolated static func aiFailureFingerprint(for reasons: [AIFailureReason]) -> [String] {
    let sorted = reasons.map(\.rawValue).sorted()
    return sorted.isEmpty ? ["ai_failure"] : ["ai_failure"] + sorted
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

  /// Capture an Apple Intelligence polish generation failure on this event
  /// (#429; the router `polish_mode`/`polish_router_basis` fields were dropped in
  /// #1072 when the dual router was removed).
  ///
  /// A `CancellationError` is a clean unwind, not a failure: when the AFM polish
  /// budget expires, the task group cancels the in-flight generation, and
  /// `AppleIntelligenceConnector.polish()`'s catch-all wraps that cancellation as
  /// an `AFMPolishError`. The user still gets clean text via the runner's silent
  /// skip, so the cancellation earns a breadcrumb, never an alerting event (#1438).
  public static func captureAFMPolishError(_ error: any Error) {
    if error is CancellationError {
      add(
        stage: "polish",
        message: "AFM polish cancelled; treating as non-alerting unwind",
        level: .info
      )
      return
    }
    captureError(error, category: .generationFailed, stage: "polish")
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
    // Group by the sorted failure-reason set so this stays one stable issue
    // distinct from the handled-error groups (#1144).
    event.fingerprint = Self.aiFailureFingerprint(for: report.failureReasons)
    SentrySDK.capture(event: event)
  }

  // MARK: - Error Taxonomy

  /// Structured error categories for pipeline failures.
  /// Maps to Sentry tags for filtering and alerting.
  public enum ErrorCategory: String, Sendable {
    case availabilityCheckFailed = "availability_check_failed"
    case providerInitFailed = "provider_init_failed"
    case generationFailed = "generation_failed"
    /// #945: a cloud (OpenAI/Gemini) or local (Ollama) AI-cleanup attempt failed
    /// for a reason the user saw on screen. Carries a `polish.error_case` reason
    /// tag (the closed `PolishFailureReason` set) so a wave of expired keys or a
    /// provider outage is visible in triage. Apple Intelligence is excluded (its
    /// generation failures are captured via `generationFailed`).
    case polishProviderFailed = "polish_provider_failed"
    case fallbackFailed = "fallback_failed"
    case pasteFailed = "paste_failed"
    case stateMismatch = "state_mismatch"
    case xpcServiceError = "xpc_service_error"
    case modelLoadFailed = "model_load_failed"
    case modelLoadWedged = "model_load_wedged"
    case audioCaptureFailed = "audio_capture_failed"
    case audioCaptureStalled = "audio_capture_stalled"
    case asrFailed = "asr_failed"
    /// #979: retained as a historical Sentry tag — no longer emitted (ASR-empty
    /// on non-speech downgraded to a context-only breadcrumb in
    /// KernelLifecycleTelemetrySink). Kept so old `asr_empty_result` events stay
    /// documented; do not re-wire to an error without revisiting #979.
    case asrEmptyResult = "asr_empty_result"
    case heartPathFinalization = "heart_path_finalization"
    case pipelineDispatchFailed = "pipeline_dispatch_failed"
    case pipelinePostConditionFailed = "pipeline_post_condition_failed"
    /// #145: the deterministic ITN limb exceeded its 0.5s off-actor cap. Rare by
    /// construction (engine p95 ~0.1ms) — the user still gets pre-ITN text.
    case inverseNormalizationTimeout = "inverse_normalization_timeout"
    /// #1063 PR1: the crash-recovery limb could not arm because its per-session
    /// key failed to generate/persist. Non-crash — the recording is byte-identical;
    /// only the safety copy is absent for that take.
    case recoveryKeyStoreFailed = "recovery_key_store_failed"
    /// #1063 PR2: a recovered spool failed to decrypt (missing key, cipher
    /// mismatch, or an empty/torn prefix). Non-crash limb — the orphan is deleted
    /// and the user sees "couldn't recover."
    case recoveryDecryptFailed = "recovery_decrypt_failed"
    /// #1063 PR2: transcribing a recovered spool returned empty or threw. Non-crash
    /// limb (one attempt) — the orphan is deleted and the user sees "couldn't
    /// recover."
    case recoveryTranscribeFailed = "recovery_transcribe_failed"
    /// #1063 PR2: a spool whose attempt marker was already present on launch — a
    /// prior recovery attempt crashed the app — so it is abandoned (deleted, never
    /// retried) by the one-attempt crash-loop guard rather than risking a loop.
    case recoveryAbandonedAfterAttempt = "recovery_abandoned_after_attempt"
    /// #761: the deterministic post-polish emoji-restore guard re-inserted fewer
    /// glyphs than AFM dropped (`restored < dropped`). Impossible by construction
    /// — every dropped glyph is re-inserted — so this fires only on a regression.
    /// The user still got the polished text plus whatever was restored.
    case emojiRestoreIncomplete = "emoji_restore_incomplete"
    /// #1175 (Telemetry Bible Phase 6): a hotkey registration failed — Carbon
    /// `RegisterEventHotKey` returned non-`noErr`, or an `NSEvent` modifier
    /// monitor installed `nil`. The affected hotkey will not fire. Rare and
    /// actionable; carries `mechanism` / `hotkey_kind` / `os_status` / `key_shape`
    /// (metadata only — never the key codes).
    case hotkeyRegistrationFailed = "hotkey_registration_failed"
    /// #1177 (Telemetry Bible Phase 8): the on-device output-safety classifier
    /// failed to load at prewarm. Polish keeps working WITHOUT the extra safety net
    /// (fails open) — persistent because it retries on every provider switch, so a
    /// genuinely broken model surfaces as a recurring handled error. `fingerprintDetail`
    /// is the load-failure reason, so distinct reasons get distinct issues.
    case outputClassifierLoadFailed = "output_classifier_load_failed"
    /// #1177 (Telemetry Bible Phase 8): a legacy plaintext API-key file could not be
    /// deleted after migration to the Keychain. The user's polish is unaffected (the
    /// Keychain value works), but the security goal — no plaintext key on disk — is
    /// silently unmet until the next retrieve retries. Security-relevant + persistent,
    /// so it earns a handled error (never the key material — only the account name).
    case legacyKeyCleanupFailed = "legacy_key_cleanup_failed"
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

  // periphery:ignore - test seam
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

  /// Optional test-only delegate invoked synchronously on every `add` call before
  /// the real Sentry SDK is touched — including the trail entry `captureError`
  /// leaves alongside a captured event. Production code never reads it.
  public nonisolated(unsafe) static var breadcrumbDelegate:
    (@Sendable (String, String, SentryLevel, [String: Any]?) -> Void)?
}
