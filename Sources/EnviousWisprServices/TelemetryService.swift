import EnviousWisprCore
import Foundation
import PostHog

/// Thin wrapper — type-safe event names, no business logic.
/// Limb: observes facts from domain objects, publishes to PostHog.
@MainActor
public final class TelemetryService {
  public static let shared = TelemetryService()
  private init() {}

  // MARK: - Observation Layer (reads domain objects)

  /// Called by AppState when a pipeline completes. Reads Transcript + ExecutionMetrics.
  public func reportDictationCompleted(transcript t: Transcript, inputMode: String) {
    let m = t.metrics
    dictationCompleted(
      result: "success",
      inputMode: inputMode,
      asrBackend: t.backendType.rawValue,
      llmProvider: t.llmProvider,
      stylePreset: nil,
      fillerRemoval: false,
      targetApp: m?.targetApp,
      pasteResult: m?.pasteTier,
      e2eSeconds: m?.e2eSeconds ?? t.processingTime,
      asrSeconds: m?.asrLatencySeconds,
      llmSeconds: m?.llmLatencySeconds
    )
    if let e2e = m?.e2eSeconds {
      metricPipelineE2E(
        seconds: e2e, inputMode: inputMode, asrBackend: t.backendType.rawValue,
        llmProvider: t.llmProvider, result: "success")
    }
    if let asrLat = m?.asrLatencySeconds {
      asrCompleted(
        backend: t.backendType.rawValue, result: "success", coldStart: m?.coldStart ?? false,
        latencySeconds: asrLat, charCount: t.text.count)
    }
    if let llmLat = m?.llmLatencySeconds, llmLat > 0, t.llmProvider != nil {
      llmPolishCompleted(
        provider: t.llmProvider ?? "unknown", model: t.llmModel, stylePreset: nil,
        result: t.polishedText != nil ? "success" : "skipped", latencySeconds: llmLat)
    }
    if let tier = m?.pasteTier, let ms = m?.pasteLatencyMs {
      pasteCompleted(tier: tier, targetApp: m?.targetApp, result: "success", latencyMs: ms)
    }
  }

  // MARK: - App Lifecycle

  public func appLaunched(
    version: String, build: String, osVersion: String, hardware: String, isFreshInstall: Bool,
    aiAvailable: Bool
  ) {
    PostHogSDK.shared.capture(
      "app.launched",
      properties: [
        "version": version,
        "build": build,
        "os_version": osVersion,
        "hardware": hardware,
        "is_fresh_install": isFreshInstall,
        "ai_available": aiAvailable,
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
    PostHogSDK.shared.capture("dictation.invoked", properties: props)
  }

  public func dictationCompleted(
    result: String, inputMode: String, asrBackend: String,
    llmProvider: String?, stylePreset: String?, fillerRemoval: Bool,
    targetApp: String?, pasteResult: String?,
    e2eSeconds: Double, asrSeconds: Double?, llmSeconds: Double?
  ) {
    var props: [String: Any] = [
      "result": result,
      "input_mode": inputMode,
      "asr_backend": asrBackend,
      "filler_removal": fillerRemoval,
      "e2e_seconds": String(format: "%.3f", e2eSeconds),
      "$value": e2eSeconds,
    ]
    if let p = llmProvider { props["llm_provider"] = p }
    if let s = stylePreset { props["style_preset"] = s }
    if let a = targetApp { props["target_app"] = a }
    if let pr = pasteResult { props["paste_result"] = pr }
    if let asr = asrSeconds { props["asr_seconds"] = String(format: "%.3f", asr) }
    if let llm = llmSeconds { props["llm_seconds"] = String(format: "%.3f", llm) }
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

  // MARK: - Pipeline Steps

  public func asrCompleted(
    backend: String, result: String, coldStart: Bool, latencySeconds: Double, charCount: Int
  ) {
    PostHogSDK.shared.capture(
      "asr.completed",
      properties: [
        "backend": backend,
        "result": result,
        "cold_start": coldStart,
        "latency_seconds": String(format: "%.3f", latencySeconds),
        "char_count": charCount,
        "$value": latencySeconds,
      ])
  }

  public func llmPolishCompleted(
    provider: String, model: String?, stylePreset: String?,
    result: String, latencySeconds: Double
  ) {
    var props: [String: Any] = [
      "provider": provider,
      "result": result,
      "latency_seconds": String(format: "%.3f", latencySeconds),
      "$value": latencySeconds,
    ]
    if let m = model { props["model"] = m }
    if let s = stylePreset { props["style_preset"] = s }
    PostHogSDK.shared.capture("llm.polish_completed", properties: props)
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
    writingStyle: String, fillerRemoval: Bool, customWordsCount: Int,
    hasApiKeys: Bool, noiseSuppression: Bool
  ) {
    PostHogSDK.shared.capture(
      "settings.snapshot",
      properties: [
        "asr_backend": asrBackend,
        "llm_provider": llmProvider,
        "recording_mode": recordingMode,
        "writing_style": writingStyle,
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
    usedSticky: Bool
  ) {
    var props: [String: Any] = [
      "lang": lang ?? "nil",
      "confidence": String(format: "%.3f", confidence),
      "margin": String(format: "%.3f", margin),
      "duration_bucket": Self.durationBucket(voicedDuration),
      "voiced_duration_s": String(format: "%.2f", voicedDuration),
      "abstained": abstained,
      "used_sticky": usedSticky,
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
}
