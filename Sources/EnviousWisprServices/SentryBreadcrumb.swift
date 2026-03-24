import Foundation
import Sentry
import EnviousWisprCore

/// Thin, type-safe Sentry breadcrumb + error helper for pipeline instrumentation.
/// Limb: all methods are fire-and-forget — a Sentry call failure never blocks the pipeline.
@MainActor
public enum SentryBreadcrumb {

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
    public static func captureError(
        _ error: any Error,
        category: ErrorCategory,
        stage: String,
        extra: [String: Any]? = nil
    ) {
        let event = Event(level: .error)
        event.message = SentryMessage(formatted: "\(category.rawValue): \(error.localizedDescription)")
        event.tags = [
            "pipeline.stage": stage,
            "error.category": category.rawValue,
        ]
        if let extra {
            event.extra = extra
        }

        // Also add a breadcrumb so the error appears in the trail
        add(
            stage: stage,
            message: "ERROR: \(category.rawValue)",
            level: .error,
            data: extra
        )

        SentrySDK.capture(event: event)
    }

    // MARK: - Apple Intelligence Diagnostics

    /// Attach an AI diagnostics report as persistent Sentry context + breadcrumb.
    /// Use at app launch — logs the state but does NOT fire a warning event.
    /// The report is included in every future crash/error event automatically.
    public static func attachAIDiagnostics(_ report: AppleIntelligenceAvailabilityReport) {
        add(stage: "ai_diagnostics", message: "AI availability check completed", data: [
            "overall_status": report.overallStatus.rawValue,
            "build_compiled_in": report.buildCompiledIn,
            "runtime_framework_present": report.runtimeFrameworkPresent,
            "device_eligibility": report.deviceEligibility.rawValue,
            "model_accessible": report.modelAccessible.rawValue,
            "failure_reasons": report.failureReasons.map(\.rawValue),
            "check_duration_ms": report.checkDurationMs,
        ])

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
        event.message = SentryMessage(formatted: "Apple Intelligence failed during dictation: \(report.failureReasons.map(\.rawValue).joined(separator: ", "))")
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
        case audioCaptureFailed = "audio_capture_failed"
        case asrFailed = "asr_failed"
        case asrEmptyResult = "asr_empty_result"
    }
}
