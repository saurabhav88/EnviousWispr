import Foundation
import PostHog
import EnviousWisprCore

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
            metricPipelineE2E(seconds: e2e, inputMode: inputMode, asrBackend: t.backendType.rawValue, llmProvider: t.llmProvider, result: "success")
        }
        if let asrLat = m?.asrLatencySeconds {
            asrCompleted(backend: t.backendType.rawValue, result: "success", coldStart: m?.coldStart ?? false, latencySeconds: asrLat, charCount: t.text.count)
        }
        if let llmLat = m?.llmLatencySeconds, llmLat > 0, t.llmProvider != nil {
            llmPolishCompleted(provider: t.llmProvider ?? "unknown", model: t.llmModel, stylePreset: nil, result: t.polishedText != nil ? "success" : "skipped", latencySeconds: llmLat)
        }
        if let tier = m?.pasteTier, let ms = m?.pasteLatencyMs {
            pasteCompleted(tier: tier, targetApp: m?.targetApp, result: "success", latencyMs: ms)
        }
    }

    // MARK: - App Lifecycle

    public func appLaunched(version: String, build: String, osVersion: String, hardware: String, isFreshInstall: Bool, aiAvailable: Bool) {
        PostHogSDK.shared.capture("app.launched", properties: [
            "version": version,
            "build": build,
            "os_version": osVersion,
            "hardware": hardware,
            "is_fresh_install": isFreshInstall,
            "ai_available": aiAvailable,
        ])
    }

    public func providerChanged(from: String, to: String) {
        PostHogSDK.shared.capture("provider.changed", properties: [
            "from": from,
            "to": to,
        ])
    }

    // MARK: - Onboarding

    public func onboardingStarted() {
        PostHogSDK.shared.capture("onboarding.started")
    }

    public func onboardingStepCompleted(step: String, result: String, durationSeconds: Double? = nil) {
        var props: [String: Any] = ["step": step, "result": result]
        if let d = durationSeconds {
            props["duration_seconds"] = String(format: "%.3f", d)
            props["$value"] = d
        }
        PostHogSDK.shared.capture("onboarding.step_completed", properties: props)
    }

    public func onboardingCompleted(asrBackend: String, recordingMode: String) {
        PostHogSDK.shared.capture("onboarding.completed", properties: [
            "asr_backend": asrBackend,
            "recording_mode": recordingMode,
        ])
    }

    // MARK: - Permissions

    public func permissionStatus(permission: String, status: String, context: String) {
        PostHogSDK.shared.capture("permission.status", properties: [
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

    public func dictationCompleted(result: String, inputMode: String, asrBackend: String,
                                    llmProvider: String?, stylePreset: String?, fillerRemoval: Bool,
                                    targetApp: String?, pasteResult: String?,
                                    e2eSeconds: Double, asrSeconds: Double?, llmSeconds: Double?) {
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

    public func asrCompleted(backend: String, result: String, coldStart: Bool, latencySeconds: Double, charCount: Int) {
        PostHogSDK.shared.capture("asr.completed", properties: [
            "backend": backend,
            "result": result,
            "cold_start": coldStart,
            "latency_seconds": String(format: "%.3f", latencySeconds),
            "char_count": charCount,
            "$value": latencySeconds,
        ])
    }

    public func llmPolishCompleted(provider: String, model: String?, stylePreset: String?,
                                    result: String, latencySeconds: Double) {
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

    public func pipelineFailed(stage: String, errorCategory: String, errorCode: String,
                                recoverable: Bool, backend: String?) {
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

    public func settingsSnapshot(asrBackend: String, llmProvider: String, recordingMode: String,
                                  writingStyle: String, fillerRemoval: Bool, customWordsCount: Int,
                                  hasApiKeys: Bool, noiseSuppression: Bool) {
        PostHogSDK.shared.capture("settings.snapshot", properties: [
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
    public func aiDiagnosticsRunCompleted(report: AppleIntelligenceAvailabilityReport, trigger: String) {
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

    public func metricPipelineE2E(seconds: Double, inputMode: String, asrBackend: String,
                                   llmProvider: String?, result: String) {
        var props: [String: Any] = [
            "input_mode": inputMode,
            "asr_backend": asrBackend,
            "result": result,
            "$value": seconds,
        ]
        if let p = llmProvider { props["llm_provider"] = p }
        PostHogSDK.shared.capture("metric.pipeline.e2e_seconds", properties: props)
    }
}
