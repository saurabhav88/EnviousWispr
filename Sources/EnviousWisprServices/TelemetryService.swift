import Foundation
import TelemetryDeck
import EnviousWisprCore

/// Thin wrapper — type-safe signal names, no business logic.
/// Limb: observes facts from domain objects, publishes to TelemetryDeck.
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

    // MARK: - Onboarding

    public func onboardingStarted() {
        TelemetryDeck.signal("Onboarding.started")
    }

    public func onboardingStepCompleted(step: String, result: String, durationSeconds: Double? = nil) {
        var params: [String: String] = ["step": step, "result": result]
        if let d = durationSeconds { params["durationSeconds"] = String(format: "%.3f", d) }
        TelemetryDeck.signal("Onboarding.stepCompleted", parameters: params, floatValue: durationSeconds ?? 0)
    }

    public func onboardingCompleted(asrBackend: String, recordingMode: String) {
        TelemetryDeck.signal("Onboarding.completed", parameters: [
            "asrBackend": asrBackend,
            "recordingMode": recordingMode,
        ])
    }

    // MARK: - Permissions

    public func permissionStatus(permission: String, status: String, context: String) {
        TelemetryDeck.signal("Permission.status", parameters: [
            "permission": permission,
            "status": status,
            "context": context,
        ])
    }

    // MARK: - Dictation Lifecycle

    public func dictationInvoked(triggerSource: String, inputMode: String, targetApp: String?) {
        var params: [String: String] = ["triggerSource": triggerSource, "inputMode": inputMode]
        if let app = targetApp { params["targetApp"] = app }
        TelemetryDeck.signal("Dictation.invoked", parameters: params)
    }

    public func dictationCompleted(result: String, inputMode: String, asrBackend: String,
                                    llmProvider: String?, stylePreset: String?, fillerRemoval: Bool,
                                    targetApp: String?, pasteResult: String?,
                                    e2eSeconds: Double, asrSeconds: Double?, llmSeconds: Double?) {
        var params: [String: String] = [
            "result": result,
            "inputMode": inputMode,
            "asrBackend": asrBackend,
            "fillerRemoval": String(fillerRemoval),
            "e2eSeconds": String(format: "%.3f", e2eSeconds),
        ]
        if let p = llmProvider { params["llmProvider"] = p }
        if let s = stylePreset { params["stylePreset"] = s }
        if let a = targetApp { params["targetApp"] = a }
        if let pr = pasteResult { params["pasteResult"] = pr }
        if let asr = asrSeconds { params["asrSeconds"] = String(format: "%.3f", asr) }
        if let llm = llmSeconds { params["llmSeconds"] = String(format: "%.3f", llm) }
        TelemetryDeck.signal("Dictation.completed", parameters: params, floatValue: e2eSeconds)
    }

    public func dictationCanceled(stage: String, reason: String, durationSeconds: Double?) {
        var params: [String: String] = ["stage": stage, "reason": reason]
        if let d = durationSeconds { params["durationSeconds"] = String(format: "%.3f", d) }
        TelemetryDeck.signal("Dictation.canceled", parameters: params, floatValue: durationSeconds ?? 0)
    }

    // MARK: - Pipeline Steps

    public func asrCompleted(backend: String, result: String, coldStart: Bool, latencySeconds: Double, charCount: Int) {
        TelemetryDeck.signal("ASR.completed", parameters: [
            "backend": backend,
            "result": result,
            "coldStart": String(coldStart),
            "latencySeconds": String(format: "%.3f", latencySeconds),
            "charCount": String(charCount),
        ], floatValue: latencySeconds)
    }

    public func llmPolishCompleted(provider: String, model: String?, stylePreset: String?,
                                    result: String, latencySeconds: Double) {
        var params: [String: String] = [
            "provider": provider,
            "result": result,
            "latencySeconds": String(format: "%.3f", latencySeconds),
        ]
        if let m = model { params["model"] = m }
        if let s = stylePreset { params["stylePreset"] = s }
        TelemetryDeck.signal("LLM.polishCompleted", parameters: params, floatValue: latencySeconds)
    }

    public func pasteCompleted(tier: String, targetApp: String?, result: String, latencyMs: Int) {
        var params: [String: String] = [
            "tier": tier,
            "result": result,
            "latencyMs": String(latencyMs),
        ]
        if let a = targetApp { params["targetApp"] = a }
        TelemetryDeck.signal("Paste.completed", parameters: params, floatValue: Double(latencyMs))
    }

    // MARK: - Errors

    public func pipelineFailed(stage: String, errorCategory: String, errorCode: String,
                                recoverable: Bool, backend: String?) {
        var params: [String: String] = [
            "stage": stage,
            "errorCategory": errorCategory,
            "errorCode": errorCode,
            "recoverable": String(recoverable),
        ]
        if let b = backend { params["backend"] = b }
        TelemetryDeck.signal("Pipeline.failed", parameters: params)
    }

    // MARK: - Settings Snapshot

    public func settingsSnapshot(asrBackend: String, llmProvider: String, recordingMode: String,
                                  writingStyle: String, fillerRemoval: Bool, customWordsCount: Int,
                                  hasApiKeys: Bool, noiseSuppression: Bool) {
        TelemetryDeck.signal("Settings.snapshot", parameters: [
            "asrBackend": asrBackend,
            "llmProvider": llmProvider,
            "recordingMode": recordingMode,
            "writingStyle": writingStyle,
            "fillerRemoval": String(fillerRemoval),
            "customWordsCount": String(customWordsCount),
            "hasApiKeys": String(hasApiKeys),
            "noiseSuppression": String(noiseSuppression),
        ])
    }

    // MARK: - Metrics

    public func metricPipelineE2E(seconds: Double, inputMode: String, asrBackend: String,
                                   llmProvider: String?, result: String) {
        var params: [String: String] = [
            "inputMode": inputMode,
            "asrBackend": asrBackend,
            "result": result,
        ]
        if let p = llmProvider { params["llmProvider"] = p }
        TelemetryDeck.signal("Metric.pipeline.e2eSeconds", parameters: params, floatValue: seconds)
    }
}
