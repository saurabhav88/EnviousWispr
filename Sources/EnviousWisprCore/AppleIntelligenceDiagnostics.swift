import Foundation

// MARK: - Enums

/// Overall availability status for Apple Intelligence.
public enum AIAvailabilityStatus: String, Sendable, Codable {
    case available
    case unavailable
    case degraded
    case unknown
}

/// Per-gate result status.
public enum AIGateStatus: String, Sendable, Codable {
    case passed
    case failed
    case skipped      // upstream gate failed, this gate was not run
    case timedOut
    case unknown
}

/// Three-state value for leaf observations that may not be deterministic.
public enum AITriState: String, Sendable {
    case yes
    case no
    case unknown
}

/// Explicit, stable failure reasons for Apple Intelligence availability.
/// Each maps to a specific diagnostic condition — not freeform strings.
public enum AIFailureReason: String, Sendable, CaseIterable, Codable {
    case notCompiledIn
    case unsupportedOS
    case unsupportedHardware           // Reserved: deviceNotEligible covers this via Apple's API
    case frameworkMissingAtRuntime      // Reserved: compile-time gate only (no runtime dynamic load check)
    case deviceNotEligible
    case appleIntelligenceDisabled
    case modelNotReady
    case modelAccessFailed
    case sessionInitFailed             // Reserved: LanguageModelSession init is non-throwing
    case generationFailed
    case unknownError
}

// MARK: - Gate Result

/// Result of a single diagnostic gate check.
public struct AIGateResult: Sendable, Codable {
    public let status: AIGateStatus
    public let reasons: [AIFailureReason]
    public let durationMs: Int?
    public let summary: String

    public init(status: AIGateStatus, reasons: [AIFailureReason] = [], durationMs: Int? = nil, summary: String) {
        self.status = status
        self.reasons = reasons
        self.durationMs = durationMs
        self.summary = summary
    }

    /// Convenience for a passed gate.
    public static func passed(summary: String, durationMs: Int? = nil) -> AIGateResult {
        AIGateResult(status: .passed, durationMs: durationMs, summary: summary)
    }

    /// Convenience for a failed gate.
    public static func failed(reasons: [AIFailureReason], summary: String, durationMs: Int? = nil) -> AIGateResult {
        AIGateResult(status: .failed, reasons: reasons, durationMs: durationMs, summary: summary)
    }

    /// Convenience for a skipped gate.
    public static func skipped(summary: String) -> AIGateResult {
        AIGateResult(status: .skipped, summary: summary)
    }

    /// Convenience for a timed-out gate.
    public static func timedOut(summary: String, durationMs: Int? = nil) -> AIGateResult {
        AIGateResult(status: .timedOut, durationMs: durationMs, summary: summary)
    }
}

// MARK: - Gate Set

/// The full ordered set of diagnostic gates for one availability check run.
public struct AIGateSet: Sendable, Codable {
    public let build: AIGateResult
    public let runtime: AIGateResult
    public let eligibility: AIGateResult
    public let modelAccess: AIGateResult
    public let functionalProbe: AIGateResult

    public init(build: AIGateResult, runtime: AIGateResult, eligibility: AIGateResult, modelAccess: AIGateResult, functionalProbe: AIGateResult) {
        self.build = build
        self.runtime = runtime
        self.eligibility = eligibility
        self.modelAccess = modelAccess
        self.functionalProbe = functionalProbe
    }

    /// All gate results as an ordered array for iteration.
    public var allGates: [(name: String, result: AIGateResult)] {
        [
            ("Build", build),
            ("Runtime", runtime),
            ("Eligibility", eligibility),
            ("Model Access", modelAccess),
            ("Functional Probe", functionalProbe)
        ]
    }
}

// MARK: - Availability Report

/// Structured diagnostic report for Apple Intelligence availability.
/// Produced by the diagnostics service, consumed by UI and observability.
public struct AppleIntelligenceAvailabilityReport: Sendable, Codable {
    public static let currentReportVersion = 2

    public let reportVersion: Int
    public let overallStatus: AIAvailabilityStatus
    public let gates: AIGateSet
    public let failureReasons: [AIFailureReason]
    public let osVersion: String
    public let hardwareClass: String
    public let generatedAt: Date
    public let checkDurationMs: Int

    public init(
        overallStatus: AIAvailabilityStatus,
        gates: AIGateSet,
        failureReasons: [AIFailureReason],
        osVersion: String,
        hardwareClass: String,
        generatedAt: Date = Date(),
        checkDurationMs: Int = 0
    ) {
        self.reportVersion = Self.currentReportVersion
        self.overallStatus = overallStatus
        self.gates = gates
        self.failureReasons = failureReasons
        self.osVersion = osVersion
        self.hardwareClass = hardwareClass
        self.generatedAt = generatedAt
        self.checkDurationMs = checkDurationMs
    }

    // MARK: - Derived Presentation Fields

    /// User-facing message derived from failure reasons. NOT stored, always computed.
    public var userVisibleMessage: String {
        if failureReasons.isEmpty {
            return "Apple Intelligence is available and ready to use."
        }
        if failureReasons.contains(.notCompiledIn) {
            return "This build was compiled without Apple Intelligence support."
        }
        if failureReasons.contains(.unsupportedOS) {
            return "Apple Intelligence requires macOS 26 or later."
        }
        if failureReasons.contains(.unsupportedHardware) || failureReasons.contains(.deviceNotEligible) {
            return "This Mac does not support Apple Intelligence. Requires Apple Silicon (M1 or later)."
        }
        if failureReasons.contains(.appleIntelligenceDisabled) {
            return "Apple Intelligence is not enabled. Turn it on in System Settings > Apple Intelligence & Siri."
        }
        if failureReasons.contains(.modelNotReady) {
            return "The on-device model is not ready — it may still be downloading. Try again later."
        }
        if failureReasons.contains(.modelAccessFailed) || failureReasons.contains(.sessionInitFailed) {
            return "Apple Intelligence is available but model initialization failed."
        }
        if failureReasons.contains(.generationFailed) {
            return "Apple Intelligence model access works but generation failed. Try again later."
        }
        return "Apple Intelligence availability could not be determined."
    }

    /// Debug summary derived from gate results. For dev builds and support.
    public var debugSummary: String {
        gates.allGates.map { "\($0.name): \($0.result.status.rawValue) — \($0.result.summary)" }.joined(separator: " | ")
    }

    /// Compact dictionary for Sentry context attachment — no PII, no user content.
    public var sentryContext: [String: Any] {
        var ctx: [String: Any] = [
            "report_version": reportVersion,
            "overall_status": overallStatus.rawValue,
            "os_version": osVersion,
            "hardware_class": hardwareClass,
            "failure_reasons": failureReasons.map(\.rawValue),
            "check_duration_ms": checkDurationMs,
        ]
        for (name, result) in gates.allGates {
            ctx["gate_\(name.lowercased().replacingOccurrences(of: " ", with: "_"))"] = result.status.rawValue
        }
        return ctx
    }

    // MARK: - History Entry

    /// Lightweight snapshot for rolling history. Stores only what matters for trendability.
    public struct HistoryEntry: Sendable, Codable {
        public let timestamp: Date
        public let trigger: String
        public let overallStatus: AIAvailabilityStatus
        public let failureReasons: [AIFailureReason]
        public let gateStatuses: [String: AIGateStatus]
        public let totalDurationMs: Int
        public let probeDurationMs: Int?

        public init(from report: AppleIntelligenceAvailabilityReport, trigger: String) {
            self.timestamp = report.generatedAt
            self.trigger = trigger
            self.overallStatus = report.overallStatus
            self.failureReasons = report.failureReasons
            var statuses: [String: AIGateStatus] = [:]
            for (name, result) in report.gates.allGates {
                statuses[name] = result.status
            }
            self.gateStatuses = statuses
            self.totalDurationMs = report.checkDurationMs
            self.probeDurationMs = report.gates.functionalProbe.durationMs
        }
    }

    /// Convenience accessor for Stage 5 probe latency.
    public var probeLatencyMs: Int? {
        gates.functionalProbe.durationMs
    }

    // MARK: - Meaningful Comparison

    /// Compare two reports by meaningful fields only (ignores generatedAt, durations, summaries).
    /// Used for first-launch re-check to detect if availability state actually changed.
    /// Checks: overallStatus, failureReasons, and per-gate statuses.
    public func hasMeaningfulDifference(from other: AppleIntelligenceAvailabilityReport) -> Bool {
        if overallStatus != other.overallStatus { return true }
        if failureReasons != other.failureReasons { return true }
        let myStatuses = gates.allGates.map { $0.result.status }
        let otherStatuses = other.gates.allGates.map { $0.result.status }
        return myStatuses != otherStatuses
    }

    // MARK: - Overall Status Derivation

    /// Derive overallStatus from gate results.
    /// Rules:
    /// - Build, Runtime, or Eligibility fail → unavailable
    /// - Model Access fails → unavailable (can't use AI at all)
    /// - Model Access times out or unknown → degraded
    /// - Functional Probe fails or times out (all else passing) → degraded
    /// - All pass (or probe skipped with everything else passing) → available
    /// - Otherwise → unknown
    public static func deriveOverallStatus(from gates: AIGateSet) -> AIAvailabilityStatus {
        // Any critical gate failure = unavailable
        if gates.build.status == .failed || gates.runtime.status == .failed || gates.eligibility.status == .failed {
            return .unavailable
        }
        // Model access failure = unavailable (can't use AI at all)
        if gates.modelAccess.status == .failed {
            return .unavailable
        }
        // Model access degraded states
        if gates.modelAccess.status == .timedOut || gates.modelAccess.status == .unknown {
            return .degraded
        }
        // Probe failure/timeout with everything else passing = degraded
        if gates.functionalProbe.status == .failed || gates.functionalProbe.status == .timedOut {
            return .degraded
        }
        // All passed — probe .skipped branch is currently unreachable (probe only skips
        // when model access fails), but kept for forward compatibility if probe becomes optional.
        if gates.build.status == .passed && gates.runtime.status == .passed && gates.eligibility.status == .passed && gates.modelAccess.status == .passed {
            if gates.functionalProbe.status == .passed || gates.functionalProbe.status == .skipped {
                return .available
            }
        }
        return .unknown
    }
}
