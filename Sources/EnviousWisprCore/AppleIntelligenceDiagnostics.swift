import Foundation

// MARK: - Apple Intelligence Availability Report

/// Structured diagnostic report for Apple Intelligence availability.
/// Produced by the diagnostics service, consumed by UI and observability.
public struct AppleIntelligenceAvailabilityReport: Sendable {
    public let overallStatus: AIAvailabilityStatus
    public let buildCompiledIn: Bool
    public let osVersion: String
    public let hardwareClass: String
    public let runtimeFrameworkPresent: Bool
    public let deviceEligibility: AITriState
    public let modelAccessible: AITriState
    public let failureReasons: [AIFailureReason]
    public let userVisibleMessage: String
    public let debugSummary: String
    public let generatedAt: Date
    public let checkDurationMs: Int

    public init(
        overallStatus: AIAvailabilityStatus,
        buildCompiledIn: Bool,
        osVersion: String,
        hardwareClass: String,
        runtimeFrameworkPresent: Bool,
        deviceEligibility: AITriState,
        modelAccessible: AITriState,
        failureReasons: [AIFailureReason],
        userVisibleMessage: String,
        debugSummary: String,
        generatedAt: Date = Date(),
        checkDurationMs: Int = 0
    ) {
        self.overallStatus = overallStatus
        self.buildCompiledIn = buildCompiledIn
        self.osVersion = osVersion
        self.hardwareClass = hardwareClass
        self.runtimeFrameworkPresent = runtimeFrameworkPresent
        self.deviceEligibility = deviceEligibility
        self.modelAccessible = modelAccessible
        self.failureReasons = failureReasons
        self.userVisibleMessage = userVisibleMessage
        self.debugSummary = debugSummary
        self.generatedAt = generatedAt
        self.checkDurationMs = checkDurationMs
    }

    /// Compact dictionary for Sentry context attachment — no PII, no user content.
    public var sentryContext: [String: Any] {
        [
            "overall_status": overallStatus.rawValue,
            "build_compiled_in": buildCompiledIn,
            "os_version": osVersion,
            "hardware_class": hardwareClass,
            "runtime_framework_present": runtimeFrameworkPresent,
            "device_eligibility": deviceEligibility.rawValue,
            "model_accessible": modelAccessible.rawValue,
            "failure_reasons": failureReasons.map(\.rawValue),
            "check_duration_ms": checkDurationMs,
        ]
    }
}

// MARK: - Enums

/// Overall availability status for Apple Intelligence.
public enum AIAvailabilityStatus: String, Sendable {
    case available
    case unavailable
    case degraded
    case unknown
}

/// Three-state value for gate checks that may not be deterministic.
public enum AITriState: String, Sendable {
    case yes
    case no
    case unknown
}

/// Explicit, stable failure reasons for Apple Intelligence availability.
/// Each maps to a specific diagnostic condition — not freeform strings.
public enum AIFailureReason: String, Sendable, CaseIterable {
    case notCompiledIn
    case unsupportedOS
    case unsupportedHardware
    case frameworkMissingAtRuntime
    case deviceNotEligible
    case appleIntelligenceDisabled
    case modelNotReady
    case modelAccessFailed
    case sessionInitFailed
    case generationFailed
    case unknownError
}
