import EnviousWisprCore
import Foundation
import PostHog

#if DEBUG
  /// Captured-for-test snapshot of a top-level telemetry emission.
  ///
  /// Typed buckets (not `[String: Any]`) so the hook signature is Swift 6
  /// `Sendable`. Debug-only: the entire observation seam is compiled out of
  /// release builds, so the struct itself lives inside the same `#if DEBUG`
  /// region as `testEventHook`. Fields read by `@testable` tests — Periphery
  /// runs with `--exclude-tests` and can't see those reads; the annotations
  /// below declare the fields intentional test-facing surface.
  public struct CapturedTelemetryEvent: Sendable, Equatable {
    // periphery:ignore
    public let name: String
    // periphery:ignore
    public let stringProps: [String: String]
    // periphery:ignore
    public let intProps: [String: Int]
    // periphery:ignore
    public let doubleProps: [String: Double]
    // periphery:ignore
    public let boolProps: [String: Bool]

    public init(
      name: String,
      stringProps: [String: String] = [:],
      intProps: [String: Int] = [:],
      doubleProps: [String: Double] = [:],
      boolProps: [String: Bool] = [:]
    ) {
      self.name = name
      self.stringProps = stringProps
      self.intProps = intProps
      self.doubleProps = doubleProps
      self.boolProps = boolProps
    }
  }
#endif

/// Thin wrapper — type-safe event names, no business logic.
/// Limb: observes facts from domain objects, publishes to PostHog.
@MainActor
public final class TelemetryService {
  public static let shared = TelemetryService()
  private init() {}

  #if DEBUG
    /// Test-only observation seam. Fired at the entry of each top-level facade
    /// method selected for focused tests. Nil in release builds; tests set this
    /// to capture emissions without reaching PostHog.
    public var testEventHook: (@Sendable (CapturedTelemetryEvent) -> Void)?
  #endif

  // MARK: - Observation Layer (reads domain objects)

  /// Called by the former root state when a pipeline completes. Reads Transcript + ExecutionMetrics.
  public func reportDictationCompleted(
    transcript t: Transcript, inputMode: String,
    recordingSeconds: Double? = nil, stopReason: String? = nil
  ) {
    #if DEBUG
      testEventHook?(
        CapturedTelemetryEvent(
          name: "dictation.completed",
          stringProps: [
            "input_mode": inputMode,
            "asr_backend": t.backendType.rawValue,
          ]
        ))
    #endif
    let m = t.metrics
    dictationCompleted(
      result: "success",
      inputMode: inputMode,
      asrBackend: t.backendType.rawValue,
      llmProvider: t.llmProvider,
      fillerRemoval: false,
      targetApp: m?.targetApp,
      pasteResult: m?.pasteTier,
      e2eSeconds: m?.e2eSeconds ?? t.processingTime,
      asrSeconds: m?.asrLatencySeconds,
      llmSeconds: m?.llmLatencySeconds,
      itnRan: m?.itnRan,
      itnChanged: m?.itnChanged,
      itnFloorDelivered: m?.itnFloorDelivered,
      itnSkipReason: m?.itnSkipReason,
      itnLatencyMs: m?.itnLatencyMs,
      itnLenBefore: m?.itnLenBefore,
      itnLenAfter: m?.itnLenAfter,
      recordingSeconds: recordingSeconds,
      stopReason: stopReason
    )
    if let e2e = m?.e2eSeconds {
      metricPipelineE2E(
        seconds: e2e, inputMode: inputMode, asrBackend: t.backendType.rawValue,
        llmProvider: t.llmProvider, result: "success")
    }
    if let asrLat = m?.asrLatencySeconds {
      asrCompleted(
        backend: t.backendType.rawValue, result: "success", coldStart: m?.coldStart ?? false,
        latencySeconds: asrLat, charCount: t.text.count,
        tailDroppedMs: m?.tailDroppedMs, tailHadEnergy: m?.tailHadEnergy,
        usedTailPreservation: m?.usedTailPreservation, recoveredTailMs: m?.recoveredTailMs,
        tailVoicedFraction: m?.tailVoicedFraction, tailRefusedReason: m?.tailRefusedReason)
    }
    if let llmLat = m?.llmLatencySeconds, llmLat > 0, t.llmProvider != nil {
      llmPolishCompleted(
        provider: t.llmProvider ?? "unknown", model: t.llmModel,
        result: t.polishedText != nil ? "success" : "skipped", latencySeconds: llmLat,
        filterTripped: m?.polishFilterTripped,
        fellBackToRaw: m?.polishFellBackToRaw,
        fallbackReason: m?.polishFallbackReason
      )
    }
    if let tier = m?.pasteTier, let ms = m?.pasteLatencyMs {
      pasteCompleted(tier: tier, targetApp: m?.targetApp, result: "success", latencyMs: ms)
    }
  }

  // MARK: - App Lifecycle

  public func appLaunched(
    version: String, build: String, osVersion: String, hardware: String, isFreshInstall: Bool,
    aiCapable: Bool, aiEnabled: Bool
  ) {
    PostHogSDK.shared.capture(
      "app.launched",
      properties: [
        "version": version,
        "build": build,
        "os_version": osVersion,
        "hardware": hardware,
        "is_fresh_install": isFreshInstall,
        "ai_capable": aiCapable,
        "ai_enabled": aiEnabled,
      ])
  }

  public func providerChanged(from: String, to: String) {
    PostHogSDK.shared.capture(
      "provider.changed",
      properties: [
        "from": from,
        "to": to,
      ])
  }

  // MARK: - Onboarding

  public func onboardingStarted() {
    PostHogSDK.shared.capture("onboarding.started")
  }

  public func onboardingStepCompleted(step: String, result: String, durationSeconds: Double? = nil)
  {
    var props: [String: Any] = ["step": step, "result": result]
    if let d = durationSeconds {
      props["duration_seconds"] = String(format: "%.3f", d)
      props["$value"] = d
    }
    PostHogSDK.shared.capture("onboarding.step_completed", properties: props)
  }

  public func onboardingCompleted(asrBackend: String, recordingMode: String) {
    PostHogSDK.shared.capture(
      "onboarding.completed",
      properties: [
        "asr_backend": asrBackend,
        "recording_mode": recordingMode,
      ])
  }

  // MARK: - Audio System Events (issue #574)

  /// Fired when an OS-level audio event (default-device change, capture-device
  /// connect/disconnect) is observed during an active recording. Lets us
  /// correlate route changes with active heart-path activity in PostHog so
  /// future V2 Lane A scenarios are designed against actual user behavior.
  ///
  /// Idle-time events fire only as Sentry breadcrumbs (no PostHog event) so
  /// we do not flood the dashboard with background route churn.
  public func audioSystemEventDuringRecording(
    event: String, backend: String, transport: String
  ) {
    PostHogSDK.shared.capture(
      "audio.system_event_during_recording",
      properties: [
        "event": event,
        "backend": backend,
        "transport": transport,
      ])
  }

  // MARK: - Permissions

  public func permissionStatus(permission: String, status: String, context: String) {
    PostHogSDK.shared.capture(
      "permission.status",
      properties: [
        "permission": permission,
        "status": status,
        "context": context,
      ])
  }

  // MARK: - Dictation Lifecycle

  public func dictationInvoked(triggerSource: String, inputMode: String, targetApp: String?) {
    var props: [String: Any] = ["trigger_source": triggerSource, "input_mode": inputMode]
    if let app = targetApp { props["target_app"] = app }
    #if DEBUG
      var stringProps = ["trigger_source": triggerSource, "input_mode": inputMode]
      if let app = targetApp { stringProps["target_app"] = app }
      testEventHook?(
        CapturedTelemetryEvent(name: "dictation.invoked", stringProps: stringProps))
    #endif
    PostHogSDK.shared.capture("dictation.invoked", properties: props)
  }

  public func dictationCompleted(
    result: String, inputMode: String, asrBackend: String,
    llmProvider: String?, fillerRemoval: Bool,
    targetApp: String?, pasteResult: String?,
    e2eSeconds: Double, asrSeconds: Double?, llmSeconds: Double?,
    itnRan: Bool? = nil, itnChanged: Bool? = nil, itnFloorDelivered: Bool? = nil,
    itnSkipReason: String? = nil, itnLatencyMs: Double? = nil,
    itnLenBefore: Int? = nil, itnLenAfter: Int? = nil,
    recordingSeconds: Double? = nil, stopReason: String? = nil
  ) {
    var props: [String: Any] = [
      "result": result,
      "input_mode": inputMode,
      "asr_backend": asrBackend,
      "filler_removal": fillerRemoval,
      "e2e_seconds": String(format: "%.3f", e2eSeconds),
      "$value": e2eSeconds,
    ]
    // #1060: how long the user actually spoke (distinct from e2e processing time)
    // + why the recording stopped. Metadata only (telemetry-privacy-boundary).
    if let rec = recordingSeconds { props["recording_seconds"] = String(format: "%.3f", rec) }
    if let sr = stopReason { props["stop_reason"] = sr }
    if let p = llmProvider { props["llm_provider"] = p }
    if let a = targetApp { props["target_app"] = a }
    if let pr = pasteResult { props["paste_result"] = pr }
    if let asr = asrSeconds { props["asr_seconds"] = String(format: "%.3f", asr) }
    if let llm = llmSeconds { props["llm_seconds"] = String(format: "%.3f", llm) }
    // #145: deterministic ITN facts (metadata only — `telemetry-privacy-boundary`).
    if let r = itnRan { props["itn_ran"] = r }
    if let c = itnChanged { props["itn_changed"] = c }
    if let fd = itnFloorDelivered { props["itn_floor_delivered"] = fd }
    if let sr = itnSkipReason { props["itn_skip_reason"] = sr }
    if let lat = itnLatencyMs { props["itn_latency_ms"] = String(format: "%.3f", lat) }
    if let lb = itnLenBefore { props["itn_len_before"] = lb }
    if let la = itnLenAfter { props["itn_len_after"] = la }
    PostHogSDK.shared.capture("dictation.completed", properties: props)
  }

  public func dictationCanceled(stage: String, reason: String, durationSeconds: Double?) {
    var props: [String: Any] = ["stage": stage, "reason": reason]
    if let d = durationSeconds {
      props["duration_seconds"] = String(format: "%.3f", d)
      props["$value"] = d
    }
    PostHogSDK.shared.capture("dictation.canceled", properties: props)
  }

  /// #1060: the approaching-cap warning was shown to the user (~1 min before the
  /// recording-duration cap). Counts the population that records long enough to
  /// near the cap — near-zero today; a rising count is the signal to invest in
  /// full long-form mode (#344). Metadata only.
  public func recordingCapWarningShown(backend: String, capSeconds: Double) {
    PostHogSDK.shared.capture(
      "recording.cap_warning_shown",
      properties: ["asr_backend": backend, "cap_seconds": capSeconds])
  }

  // MARK: - Pipeline Steps

  /// Issue #445: emit a `wedge_detected` PostHog event when the pipeline
  /// watcher fires on a wedged model load. Companion to the Sentry event
  /// captured by `SentryBreadcrumb.captureError(category: .modelLoadWedged)`
  /// at the same call site. Sentry gives breadcrumb-chain diagnostic depth;
  /// PostHog gives population-level counting and per-user retention joins.
  ///
  /// Snapshot fields are optional and additive (sourced from
  /// `LoadProgressWatcher.snapshot`). Pre-snapshot callers omit them; the
  /// PostHog dashboard treats them as nullable.
  public func modelLoadWedged(
    backend: String,
    stage: String,
    silenceMs: Int? = nil,
    observedMaxGapMs: Int? = nil,
    observedPhase: String? = nil,
    signalCountTotal: Int? = nil,
    firstSignalLatencyMs: Int? = nil,
    totalAttemptDurationMs: Int? = nil
  ) {
    var properties: [String: Any] = [
      "backend": backend,
      "stage": stage,
    ]
    if let silenceMs { properties["silence_ms"] = silenceMs }
    if let observedMaxGapMs { properties["observed_max_gap_ms"] = observedMaxGapMs }
    if let observedPhase { properties["observed_phase"] = observedPhase }
    if let signalCountTotal { properties["signal_count_total"] = signalCountTotal }
    if let firstSignalLatencyMs { properties["first_signal_latency_ms"] = firstSignalLatencyMs }
    if let totalAttemptDurationMs {
      properties["total_attempt_duration_ms"] = totalAttemptDurationMs
    }
    PostHogSDK.shared.capture("wedge_detected", properties: properties)
  }

  /// #636: contacts import completed. Privacy-safe by construction — emits the
  /// COUNT of contacts added and the trigger only, NEVER a name. The
  /// `check-contacts-data-flow.sh` hook allow-lists this as the one permitted
  /// telemetry sink in the contacts code.
  public func contactsImported(count: Int, trigger: String) {
    PostHogSDK.shared.capture(
      "contacts_imported",
      properties: ["count": count, "$value": count, "trigger": trigger])
  }

  /// Issue #445 launch-time telemetry, now emitted by the shared
  /// `KernelDictationDriver.ensureEngineWarm(reason: .launch)` (#879) when it
  /// drives the launch warm-up — `result` is one of "success",
  /// "already_loaded", "joined_in_flight", or "failed". Keeps continuity of the
  /// `launch.model_preload_completed` dashboard after the launch warm-up entry
  /// moved off `loadModelSilently`.
  public func launchModelPreloadCompleted(
    backend: String, result: String, durationMs: Int
  ) {
    PostHogSDK.shared.capture(
      "launch.model_preload_completed",
      properties: [
        "backend": backend,
        "result": result,
        "duration_ms": durationMs,
        "$value": Double(durationMs) / 1000.0,
      ])
  }

  // MARK: - Cold-boot warm-up (#879)

  /// Cold-boot warm-up began for the active engine. `reason` tags the call site
  /// (launch / onboarding / engine_swap / cold_press); `warmupInFlight` is true
  /// when a prior warm-up was already running and this call joined it. Privacy:
  /// timing/state only, no audio or text (telemetry-privacy boundary).
  public func coldStartWarmupStarted(engine: String, reason: String, warmupInFlight: Bool) {
    PostHogSDK.shared.capture(
      "coldstart.warmup_started",
      properties: [
        "engine": engine,
        "reason": reason,
        "warmup_in_flight": warmupInFlight,
      ])
  }

  /// Cold-boot warm-up reached `.ready`. `durationMs` is `ready_at − warmup_started_at`.
  public func coldStartWarmupCompleted(engine: String, reason: String, durationMs: Int) {
    PostHogSDK.shared.capture(
      "coldstart.warmup_completed",
      properties: [
        "engine": engine,
        "reason": reason,
        "duration_ms": durationMs,
        "$value": Double(durationMs) / 1000.0,
      ])
  }

  /// Cold-boot warm-up failed — the engine stays not-ready and the next press
  /// re-kicks it. `error` is the error's description (no audio/text).
  public func coldStartWarmupFailed(engine: String, reason: String, error: String) {
    PostHogSDK.shared.capture(
      "coldstart.warmup_failed",
      properties: [
        "engine": engine,
        "reason": reason,
        "error": error,
      ])
  }

  /// A press landed on a not-yet-ready engine, so NO recording session was
  /// minted (no audio captured → none discarded). `warmupInFlight` distinguishes
  /// "joined an in-flight warm-up" from "kicked a fresh one." Pairs with the
  /// existing `launch.model_preload_completed`. Privacy: state only.
  public func coldStartPressBlocked(asrBackend: String, warmupInFlight: Bool) {
    PostHogSDK.shared.capture(
      "coldstart.press_blocked",
      properties: [
        "asr_backend": asrBackend,
        "warmup_in_flight": warmupInFlight,
      ])
  }

  /// #959 — the OS reaped the idle ASR XPC service while a resident model was
  /// loaded (readiness dropped to `.notReady` with no active session). This is
  /// the reclaim-frequency signal (per-user/hour → OS-fight watch). The reap
  /// cause (`xpc_interruption` / `xpc_invalidation`) is in the proxy's app.log
  /// `readiness ready→notReady (cause=…)` line; the router that emits this only
  /// observes "a resident model was lost while idle". Privacy: state only.
  public func serviceReclaimed(asrBackend: String) {
    PostHogSDK.shared.capture(
      "coldstart.service_reclaimed",
      properties: [
        "asr_backend": asrBackend,
        "was_idle": true,
      ])
  }

  /// #959 — a press took the warm-respawn branch (idle-reaped warm model): the
  /// press proceeds to record instead of showing the cold pill. Pairs with
  /// `service_respawn_completed` to measure the avoided-pill rate.
  public func serviceRespawnStarted(asrBackend: String) {
    PostHogSDK.shared.capture(
      "coldstart.service_respawn_started",
      properties: ["asr_backend": asrBackend])
  }

  /// #959 — the warm-respawn press reached `.recording`. `durationMs` is
  /// press→recording; p95/p99 is the slow-warm / memory-pressure watch.
  public func serviceRespawnCompleted(engine: String, durationMs: Int) {
    PostHogSDK.shared.capture(
      "coldstart.service_respawn_completed",
      properties: [
        "engine": engine,
        "duration_ms": durationMs,
        "$value": Double(durationMs) / 1000.0,
      ])
  }

  public func asrCompleted(
    backend: String, result: String, coldStart: Bool, latencySeconds: Double, charCount: Int,
    // #950 tail-trim diagnostic — eligible Parakeet batch only; nil omitted.
    // Metadata only (Int ms + Bool); no audio/content. `tailDroppedMs` always set
    // (incl. 0) when eligible so the denominator holds; `tailHadEnergy` only when
    // a tail was actually dropped.
    tailDroppedMs: Int? = nil, tailHadEnergy: Bool? = nil,
    // #950 tail-preserve recovery + tuning signals (omit-on-nil). `tailPreserved`
    // nil=ineligible / false=eligible-not-preserved / true=recovered;
    // `tailPreservedMs` = ms appended back; `tailVoicedFraction` = sustained-voice
    // ratio; `tailRefusedReason` = why an eligible tail was refused. Metadata only.
    usedTailPreservation: Bool? = nil, recoveredTailMs: Int? = nil,
    tailVoicedFraction: Double? = nil, tailRefusedReason: String? = nil
  ) {
    var properties: [String: Any] = [
      "backend": backend,
      "result": result,
      "cold_start": coldStart,
      "latency_seconds": String(format: "%.3f", latencySeconds),
      "char_count": charCount,
      "$value": latencySeconds,
    ]
    if let tailDroppedMs { properties["tail_dropped_ms"] = tailDroppedMs }
    if let tailHadEnergy { properties["tail_had_energy"] = tailHadEnergy }
    if let usedTailPreservation { properties["tail_preserved"] = usedTailPreservation }
    if let recoveredTailMs { properties["tail_preserved_ms"] = recoveredTailMs }
    if let tailVoicedFraction { properties["tail_voiced_fraction"] = tailVoicedFraction }
    if let tailRefusedReason { properties["tail_refused_reason"] = tailRefusedReason }
    PostHogSDK.shared.capture("asr.completed", properties: properties)
  }

  public func llmPolishCompleted(
    provider: String, model: String?,
    result: String, latencySeconds: Double,
    filterTripped: String? = nil,
    fellBackToRaw: Bool? = nil,
    fallbackReason: String? = nil
  ) {
    var props: [String: Any] = [
      "provider": provider,
      "result": result,
      "latency_seconds": String(format: "%.3f", latencySeconds),
      "$value": latencySeconds,
    ]
    if let m = model { props["model"] = m }
    if let ft = filterTripped { props["filter_tripped"] = ft }
    if let fb = fellBackToRaw { props["fell_back_to_raw"] = fb }
    if let fr = fallbackReason { props["fallback_reason"] = fr }
    #if DEBUG
      var stringProps: [String: String] = [
        "provider": provider, "result": result,
      ]
      if let m = model { stringProps["model"] = m }
      if let ft = filterTripped { stringProps["filter_tripped"] = ft }
      if let fr = fallbackReason { stringProps["fallback_reason"] = fr }
      var boolProps: [String: Bool] = [:]
      if let fb = fellBackToRaw { boolProps["fell_back_to_raw"] = fb }
      testEventHook?(
        CapturedTelemetryEvent(
          name: "llm.polish_completed",
          stringProps: stringProps,
          boolProps: boolProps))
    #endif
    PostHogSDK.shared.capture("llm.polish_completed", properties: props)
  }

  /// #1055: AI polish was intentionally skipped (not failed). Dedicated event —
  /// NOT `llm.polish_completed`, which requires a provider stamp and would
  /// wrongly mark a skipped transcript as AI-polished. `reason` is one of the
  /// AFM-long-dictation skip modes (shared `context_window_` prefix):
  /// `context_window_predicted` (preflight), `context_window_caught` (generation
  /// overflow), or `context_window_timeout` (the 10 s on-device budget stalled).
  public func polishSkipped(provider: String, reason: String) {
    let props: [String: Any] = [
      "provider": provider,
      "skip_reason": reason,
    ]
    #if DEBUG
      testEventHook?(
        CapturedTelemetryEvent(
          name: "llm.polish_skipped",
          stringProps: ["provider": provider, "skip_reason": reason],
          boolProps: [:]))
    #endif
    PostHogSDK.shared.capture("llm.polish_skipped", properties: props)
  }

  public func pasteCompleted(tier: String, targetApp: String?, result: String, latencyMs: Int) {
    var props: [String: Any] = [
      "tier": tier,
      "result": result,
      "latency_ms": latencyMs,
      "$value": Double(latencyMs),
    ]
    if let a = targetApp { props["target_app"] = a }
    PostHogSDK.shared.capture("paste.completed", properties: props)
  }

  // MARK: - Errors

  public func pipelineFailed(
    stage: String, errorCategory: String, errorCode: String,
    recoverable: Bool, backend: String?
  ) {
    #if DEBUG
      var hookStrings: [String: String] = [
        "stage": stage,
        "error_category": errorCategory,
        "error_code": errorCode,
      ]
      if let b = backend { hookStrings["backend"] = b }
      testEventHook?(
        CapturedTelemetryEvent(
          name: "pipeline.failed",
          stringProps: hookStrings,
          boolProps: ["recoverable": recoverable]
        ))
    #endif
    var props: [String: Any] = [
      "stage": stage,
      "error_category": errorCategory,
      "error_code": errorCode,
      "recoverable": recoverable,
    ]
    if let b = backend { props["backend"] = b }
    PostHogSDK.shared.capture("pipeline.failed", properties: props)
  }

  // MARK: - Settings Snapshot

  public func settingsSnapshot(
    asrBackend: String, llmProvider: String, recordingMode: String,
    fillerRemoval: Bool, customWordsCount: Int,
    hasApiKeys: Bool, noiseSuppression: Bool
  ) {
    PostHogSDK.shared.capture(
      "settings.snapshot",
      properties: [
        "asr_backend": asrBackend,
        "llm_provider": llmProvider,
        "recording_mode": recordingMode,
        "filler_removal": fillerRemoval,
        "custom_words_count": customWordsCount,
        "has_api_keys": hasApiKeys,
        "noise_suppression": noiseSuppression,
      ])
  }

  // MARK: - AI Diagnostics

  /// One summary event per diagnostics check run.
  /// Trigger: "app_launch", "delayed_recheck", "manual_refresh", "provider_switch"
  public func aiDiagnosticsRunCompleted(
    report: AppleIntelligenceAvailabilityReport, trigger: String
  ) {
    var props: [String: Any] = [
      "overall_status": report.overallStatus.rawValue,
      "failure_reasons": report.failureReasons.map(\.rawValue).joined(separator: ","),
      "check_duration_ms": report.checkDurationMs,
      "os_version": report.osVersion,
      "hardware_class": report.hardwareClass,
      "trigger": trigger,
    ]
    for (name, result) in report.gates.allGates {
      let key = name.lowercased().replacingOccurrences(of: " ", with: "_")
      props["gate_\(key)_status"] = result.status.rawValue
      if let ms = result.durationMs { props["gate_\(key)_ms"] = ms }
    }
    PostHogSDK.shared.capture("ai_diagnostics.run_completed", properties: props)
  }

  // MARK: - Metrics

  public func metricPipelineE2E(
    seconds: Double, inputMode: String, asrBackend: String,
    llmProvider: String?, result: String
  ) {
    var props: [String: Any] = [
      "input_mode": inputMode,
      "asr_backend": asrBackend,
      "result": result,
      "$value": seconds,
    ]
    if let p = llmProvider { props["llm_provider"] = p }
    PostHogSDK.shared.capture("metric.pipeline.e2e_seconds", properties: props)
  }

  // MARK: - Multilingual v1 (language detection lifecycle)
  //
  // Events per docs/feature-requests/multilingual-v1.md § Telemetry.
  // All methods are fire-and-forget and PII-free (lang codes + numeric stats only).
  // The `environment` property (production/development) is globally registered on
  // PostHog init (see ObservabilityBootstrap) so every capture below inherits it.

  /// Emitted after `LanguageDetector.detect` completes for any outcome (accepted or abstained).
  public func trackLanguageDetected(
    lang: String?,
    confidence: Double,
    margin: Double,
    voicedDuration: TimeInterval,
    abstained: Bool,
    sessionPreferredLang: String?,
    usedSticky: Bool,
    lidWindowCount: Int
  ) {
    var props: [String: Any] = [
      "lang": lang ?? "nil",
      "confidence": String(format: "%.3f", confidence),
      "margin": String(format: "%.3f", margin),
      "duration_bucket": Self.durationBucket(voicedDuration),
      "voiced_duration_s": String(format: "%.2f", voicedDuration),
      "abstained": abstained,
      "used_sticky": usedSticky,
      "lid_window_count": lidWindowCount,
    ]
    if let pref = sessionPreferredLang {
      props["session_preferred_lang"] = pref
    }
    PostHogSDK.shared.capture("language.detected", properties: props)
  }

  /// Emitted when the user confirms a language in the Lock language sheet.
  /// `fromLang` is the prior mode ("auto" if unlocked, else prior ISO code).
  /// `reason` is one of: "first_time", "after_bad_detect", "preference".
  public func trackManualLockUsed(fromLang: String, toLang: String, reason: String) {
    PostHogSDK.shared.capture(
      "language.manual_lock_used",
      properties: [
        "from_lang": fromLang,
        "to_lang": toLang,
        "reason": reason,
      ])
  }

  /// Emitted when two different languages are accepted in the same session within 5 minutes.
  /// Fired from the detector's flip-flop path (piggybacks on the passive-chip trigger).
  public func trackLanguageFlip(fromLang: String, toLang: String, confidenceBoth: Double) {
    PostHogSDK.shared.capture(
      "language.flip",
      properties: [
        "from_lang": fromLang,
        "to_lang": toLang,
        "confidence_both": String(format: "%.3f", confidenceBoth),
      ])
  }

  /// Emitted when the user deletes more than 50% of pasted text within 5s of insert.
  /// `lang` is the language detected for the failed transcript.
  ///
  /// TODO (W6/#248 follow-up): no call site yet. v1 ships with this method
  /// available so the analytics schema is ready, but the paste-cascade does
  /// not observe post-insert user edits. Implementing this requires either
  /// an AX observer on the focused text field or a clipboard diff heuristic
  /// that ignores our own restore-clipboard writes. Deferred pending review
  /// of whether real-world correction rates justify the AX surface.
  public func trackCorrectionAfterInsert(lang: String?, confidence: Double, charCount: Int) {
    var props: [String: Any] = [
      "confidence": String(format: "%.3f", confidence),
      "char_count": charCount,
    ]
    if let l = lang { props["lang"] = l }
    PostHogSDK.shared.capture("language.correction_after_insert", properties: props)
  }

  /// Emitted when LID abstains (returned nil language).
  /// `reason` is one of: "too_short", "low_confidence", "narrow_margin".
  public func trackLIDAbstained(
    voicedDuration: TimeInterval,
    top1Prob: Double,
    top1Lang: String?,
    reason: String
  ) {
    var props: [String: Any] = [
      "voiced_duration": String(format: "%.2f", voicedDuration),
      "top1_prob": String(format: "%.3f", top1Prob),
      "reason": reason,
    ]
    if let l = top1Lang { props["top1_lang"] = l }
    PostHogSDK.shared.capture("language.lid_abstained", properties: props)
  }

  /// Emitted per transcription: surfaces real-time factor per language+model for
  /// per-language perf dashboards. Kept separate from `asr.completed` (generic) so
  /// the multilingual dashboard can slice by lang without schema churn elsewhere.
  public func trackTranscriptionLatency(
    lang: String?,
    model: String,
    durationSeconds: Double,
    msPerAudioSecond: Double
  ) {
    var props: [String: Any] = [
      "model": model,
      "duration_s": String(format: "%.3f", durationSeconds),
      "ms_per_audio_s": String(format: "%.1f", msPerAudioSecond),
      "$value": msPerAudioSecond,
    ]
    if let l = lang { props["lang"] = l }
    PostHogSDK.shared.capture("language.transcription_latency", properties: props)
  }

  // MARK: - Multilingual helpers

  /// Spec-defined voiced-duration buckets. Single source of truth so the
  /// detector call site and UI debug views agree on labels.
  private static func durationBucket(_ seconds: TimeInterval) -> String {
    switch seconds {
    case ..<1.0: return "<1s"
    case ..<2.5: return "1-2.5s"
    case ..<5.0: return "2.5-5s"
    case ..<10.0: return "5-10s"
    case ..<15.0: return "10-15s"
    default: return "15s+"
    }
  }

  // MARK: - Update banner (issue #343)

  public func updateBannerShown(
    version: String,
    isCritical: Bool,
    dismissedPreviously: Bool,
    secondsSinceAvailable: Int
  ) {
    PostHogSDK.shared.capture(
      "update.banner_shown",
      properties: [
        "version": version,
        "is_critical": isCritical,
        "dismissed_for_version_previously": dismissedPreviously,
        "seconds_since_available": secondsSinceAvailable,
      ]
    )
  }

  public func updateBannerClicked(version: String, isCritical: Bool, secondsVisible: Int) {
    PostHogSDK.shared.capture(
      "update.banner_clicked",
      properties: [
        "version": version,
        "is_critical": isCritical,
        "seconds_visible": secondsVisible,
      ]
    )
  }

  /// Issue #958: a proactive launch/foreground trigger evaluated, whether it
  /// actually fired a background check, and why. Emitted on EVERY return path.
  /// Bounded cardinality: `trigger ∈ {launch, foreground}`, `fired ∈ {true,false}`,
  /// `reason ∈ {fired, cooldown, auto_checks_off, no_updater, session_in_progress}`.
  /// The non-fired cases are what the existing `update.sparkle_cycle_finished`
  /// cannot show.
  public func updateProactiveCheckTriggered(trigger: String, fired: Bool, reason: String) {
    #if DEBUG
      testEventHook?(
        CapturedTelemetryEvent(
          name: "update.proactive_check_triggered",
          stringProps: ["trigger": trigger, "reason": reason],
          boolProps: ["fired": fired]
        ))
    #endif
    PostHogSDK.shared.capture(
      "update.proactive_check_triggered",
      properties: [
        "trigger": trigger,
        "fired": fired,
        "reason": reason,
      ]
    )
  }

  public func updateSparkleDefaultShown(version: String, isCritical: Bool, reason: String) {
    #if DEBUG
      testEventHook?(
        CapturedTelemetryEvent(
          name: "update.sparkle_default_shown",
          stringProps: ["version": version, "reason": reason],
          boolProps: ["is_critical": isCritical]
        ))
    #endif
    PostHogSDK.shared.capture(
      "update.sparkle_default_shown",
      properties: [
        "version": version,
        "is_critical": isCritical,
        "reason": reason,
      ]
    )
  }

  public func updateInstallStarted(version: String, isCritical: Bool, source: String) {
    #if DEBUG
      testEventHook?(
        CapturedTelemetryEvent(
          name: "update.install_started",
          stringProps: ["version": version, "source": source],
          boolProps: ["is_critical": isCritical]
        ))
    #endif
    PostHogSDK.shared.capture(
      "update.install_started",
      properties: [
        "version": version,
        "is_critical": isCritical,
        "source": source,
      ]
    )
  }

  public func updateSparkleCycleFinished(
    version: String,
    isCritical: Bool,
    source: String,
    errorCode: String?,
    noUpdateReason: String?,
    checkKind: String,
    currentAppVersion: String
  ) {
    #if DEBUG
      var hookStringProps: [String: String] = [
        "version": version,
        "source": source,
        "check_kind": checkKind,
        "current_app_version": currentAppVersion,
      ]
      if let errorCode { hookStringProps["error_code"] = errorCode }
      if let noUpdateReason { hookStringProps["no_update_reason"] = noUpdateReason }
      testEventHook?(
        CapturedTelemetryEvent(
          name: "update.sparkle_cycle_finished",
          stringProps: hookStringProps,
          boolProps: ["is_critical": isCritical]
        ))
    #endif
    var props: [String: Any] = [
      "version": version,
      "is_critical": isCritical,
      "source": source,
      "check_kind": checkKind,
      "current_app_version": currentAppVersion,
    ]
    if let errorCode { props["error_code"] = errorCode }
    if let noUpdateReason { props["no_update_reason"] = noUpdateReason }
    PostHogSDK.shared.capture("update.sparkle_cycle_finished", properties: props)
  }

  public func updateInstallCompleted(version: String, isCritical: Bool, source: String) {
    #if DEBUG
      testEventHook?(
        CapturedTelemetryEvent(
          name: "update.install_completed",
          stringProps: ["version": version, "source": source],
          boolProps: ["is_critical": isCritical]
        ))
    #endif
    PostHogSDK.shared.capture(
      "update.install_completed",
      properties: [
        "version": version,
        "is_critical": isCritical,
        "source": source,
      ]
    )
  }

  public func updateInstallFailed(
    version: String,
    isCritical: Bool,
    source: String,
    errorCode: String,
    noUpdateReason: String?,
    checkKind: String,
    currentAppVersion: String
  ) {
    #if DEBUG
      var hookStringProps: [String: String] = [
        "version": version,
        "source": source,
        "error_code": errorCode,
        "check_kind": checkKind,
        "current_app_version": currentAppVersion,
      ]
      if let noUpdateReason { hookStringProps["no_update_reason"] = noUpdateReason }
      testEventHook?(
        CapturedTelemetryEvent(
          name: "update.install_failed",
          stringProps: hookStringProps,
          boolProps: ["is_critical": isCritical]
        ))
    #endif
    var props: [String: Any] = [
      "version": version,
      "is_critical": isCritical,
      "source": source,
      "error_code": errorCode,
      "check_kind": checkKind,
      "current_app_version": currentAppVersion,
    ]
    if let noUpdateReason { props["no_update_reason"] = noUpdateReason }
    PostHogSDK.shared.capture("update.install_failed", properties: props)
  }

  public func updateInstallCancelled(version: String, isCritical: Bool, source: String) {
    #if DEBUG
      testEventHook?(
        CapturedTelemetryEvent(
          name: "update.install_cancelled",
          stringProps: ["version": version, "source": source],
          boolProps: ["is_critical": isCritical]
        ))
    #endif
    PostHogSDK.shared.capture(
      "update.install_cancelled",
      properties: [
        "version": version,
        "is_critical": isCritical,
        "source": source,
      ]
    )
  }

  public func updateWatchdogFired(version: String, isCritical: Bool) {
    PostHogSDK.shared.capture(
      "update.watchdog_fired",
      properties: [
        "version": version,
        "is_critical": isCritical,
      ]
    )
  }

  /// Synchronously flushes buffered events. Called before triggering install
  /// so click/start events survive Sparkle's relaunch.
  public func flushTelemetry() {
    PostHogSDK.shared.flush()
  }

  // MARK: - Custom Words v2 (Phase 8a — distributed event backfill, bible §14.1)
  //
  // Privacy: NEVER include term strings, alias strings, or any contact-derived
  // data in these events. Only counts, booleans, category labels, latency
  // buckets. Bible §14.3.

  /// Phase 0 (#640) — fired by `CustomWordsPropagator.update(corrector:polish:)`
  /// once per atomic broadcast. `lane` is "corrector" or "polish".
  public func customWordsPropagatorBroadcast(
    lane: String, generation: UInt64, consumerCount: Int, termCount: Int
  ) {
    PostHogSDK.shared.capture(
      "custom_words.propagator_broadcast",
      properties: [
        "lane": lane,
        "generation": Int(generation),
        "consumer_count": consumerCount,
        "term_count": termCount,
      ]
    )
  }

  /// Phase 1 (#637) — fired by `WordSuggestionService.suggest(for:)` after
  /// the degeneration filter. `degenerated == true` means raw was non-empty
  /// but post-filter list was empty (model returned only self-echoes).
  /// `categorySuggested` is the category enum raw value or nil if call failed.
  public func customWordsAfmAliasFilled(
    resultCount: Int, degenerated: Bool, categorySuggested: String?
  ) {
    var props: [String: Any] = [
      "result_count": resultCount,
      "degenerated": degenerated,
    ]
    if let category = categorySuggested {
      props["category_suggested"] = category
    }
    PostHogSDK.shared.capture("custom_words.afm_alias_filled", properties: props)
  }

  /// Phase 2 (#638) — fired by `WordCorrectionStep.process(...)` after a
  /// successful correction batch. Single summary event per process() call;
  /// per-replacement breakdown deferred to full Phase 8 (bible v1.3 will note
  /// this scope reduction). `latencyBucket` quantizes wall-clock duration.
  public func customWordsReplacementBatch(
    replacementCount: Int,
    vocabSize: Int,
    hadPackTerm: Bool,
    hadUserTerm: Bool,
    hadBuiltinTerm: Bool,
    latencyBucket: String
  ) {
    PostHogSDK.shared.capture(
      "custom_words.replacement_applied",
      properties: [
        "replacement_count": replacementCount,
        "vocab_size": vocabSize,
        "had_pack_term": hadPackTerm,
        "had_user_term": hadUserTerm,
        "had_builtin_term": hadBuiltinTerm,
        "latency_bucket": latencyBucket,
      ]
    )
  }

  /// #657 (2026-05-05) — fired by `TextProcessingRunner` when the
  /// `WordCorrectionStep` exceeds its 3-second `maxDuration` cap and the
  /// corrector result is discarded. Properties expanded from the prior
  /// vocab-only shape so dashboards can slice cap-trips by input size.
  public func customWordsTimeoutFired(
    vocabSize: Int,
    elapsedMs: Double,
    inputChars: Int
  ) {
    PostHogSDK.shared.capture(
      "custom_words.timeout_fired",
      properties: [
        "vocab_size": vocabSize,
        "elapsed_ms": elapsedMs,
        "input_chars": inputChars,
      ]
    )
  }
}

// MARK: - Latency bucket helper (Phase 8a)

/// Quantize a wall-clock latency into a coarse bucket for telemetry.
/// Buckets are chosen to surface the heart-path 10ms boundary.
public enum LatencyBucket {
  public static func of(milliseconds: Double) -> String {
    switch milliseconds {
    case ..<1: return "under_1ms"
    case 1..<5: return "1_to_5ms"
    case 5..<10: return "5_to_10ms"
    case 10..<25: return "10_to_25ms"
    case 25..<50: return "25_to_50ms"
    case 50..<100: return "50_to_100ms"
    default: return "over_100ms"
    }
  }
}
