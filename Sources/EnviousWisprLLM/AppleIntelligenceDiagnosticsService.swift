import Foundation
import EnviousWisprCore

#if canImport(FoundationModels)
import FoundationModels
#endif

/// Runs layered gate checks to produce a structured Apple Intelligence availability report.
/// Each gate returns pass/fail/unknown with explicit failure reasons.
///
/// Gate stages:
/// 1. Build/Binary — was FoundationModels compiled in?
/// 2. OS/Runtime — is macOS version sufficient? Is the framework loadable?
/// 3. Device Eligibility — is this device eligible for Apple Intelligence?
/// 4. Model Access — can the system language model be accessed?
///
/// Limb: never throws, never blocks. Returns a report regardless of outcome.
public enum AppleIntelligenceDiagnosticsService {

    /// Run all gate checks and produce a structured report.
    @MainActor
    public static func runDiagnostics() -> AppleIntelligenceAvailabilityReport {
        let start = CFAbsoluteTimeGetCurrent()
        let osVersion = Self.currentOSVersion()
        let hardwareClass = Self.currentHardwareClass()

        var failureReasons: [AIFailureReason] = []
        var debugLines: [String] = []

        // Stage 1: Build / Binary Gate
        let buildCompiledIn = Self.checkBuildGate()
        debugLines.append("Stage 1 (Build): compiled_in=\(buildCompiledIn)")
        if !buildCompiledIn {
            failureReasons.append(.notCompiledIn)
        }

        // Stage 2: OS / Runtime Environment Gate
        let (runtimePresent, osGateReasons) = Self.checkOSRuntimeGate(osVersion: osVersion)
        debugLines.append("Stage 2 (OS/Runtime): framework_present=\(runtimePresent)")
        failureReasons.append(contentsOf: osGateReasons)

        // Stage 3 + 4: Device Eligibility + Model Access Gates
        // These require FoundationModels to be compiled in and macOS 26+
        var deviceEligibility: AITriState = .unknown
        var modelAccessible: AITriState = .unknown

        if buildCompiledIn && runtimePresent {
            let (eligibility, modelAccess, deviceReasons) = Self.checkDeviceAndModelGates()
            deviceEligibility = eligibility
            modelAccessible = modelAccess
            debugLines.append("Stage 3 (Device): eligibility=\(eligibility.rawValue)")
            debugLines.append("Stage 4 (Model): accessible=\(modelAccess.rawValue)")
            failureReasons.append(contentsOf: deviceReasons)
        } else {
            debugLines.append("Stage 3 (Device): skipped (build/runtime gate failed)")
            debugLines.append("Stage 4 (Model): skipped (build/runtime gate failed)")
        }

        // Determine overall status
        let overallStatus: AIAvailabilityStatus
        let userMessage: String

        if failureReasons.isEmpty {
            overallStatus = .available
            userMessage = "Apple Intelligence is available and ready to use."
        } else if failureReasons.contains(.notCompiledIn) {
            overallStatus = .unavailable
            userMessage = "This build was compiled without Apple Intelligence support."
        } else if failureReasons.contains(.unsupportedOS) {
            overallStatus = .unavailable
            userMessage = "Apple Intelligence requires macOS 26 or later."
        } else if failureReasons.contains(.unsupportedHardware) || failureReasons.contains(.deviceNotEligible) {
            overallStatus = .unavailable
            userMessage = "This Mac does not support Apple Intelligence. Requires Apple Silicon (M1 or later)."
        } else if failureReasons.contains(.appleIntelligenceDisabled) {
            overallStatus = .unavailable
            userMessage = "Apple Intelligence is not enabled. Turn it on in System Settings > Apple Intelligence & Siri."
        } else if failureReasons.contains(.modelNotReady) {
            overallStatus = .degraded
            userMessage = "The on-device model is not ready — it may still be downloading. Try again later."
        } else if failureReasons.contains(.modelAccessFailed) || failureReasons.contains(.sessionInitFailed) {
            overallStatus = .degraded
            userMessage = "Apple Intelligence is available but model initialization failed."
        } else {
            overallStatus = .unknown
            userMessage = "Apple Intelligence availability could not be determined."
        }

        let durationMs = Int((CFAbsoluteTimeGetCurrent() - start) * 1000)
        let debugSummary = debugLines.joined(separator: " | ")

        return AppleIntelligenceAvailabilityReport(
            overallStatus: overallStatus,
            buildCompiledIn: buildCompiledIn,
            osVersion: osVersion,
            hardwareClass: hardwareClass,
            runtimeFrameworkPresent: runtimePresent,
            deviceEligibility: deviceEligibility,
            modelAccessible: modelAccessible,
            failureReasons: failureReasons,
            userVisibleMessage: userMessage,
            debugSummary: debugSummary,
            checkDurationMs: durationMs
        )
    }

    // MARK: - Stage 1: Build / Binary Gate

    private static func checkBuildGate() -> Bool {
#if canImport(FoundationModels)
        return true
#else
        return false
#endif
    }

    // MARK: - Stage 2: OS / Runtime Environment Gate

    private static func checkOSRuntimeGate(osVersion: String) -> (frameworkPresent: Bool, reasons: [AIFailureReason]) {
        var reasons: [AIFailureReason] = []

#if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            return (true, [])
        } else {
            reasons.append(.unsupportedOS)
            return (false, reasons)
        }
#else
        reasons.append(.frameworkMissingAtRuntime)
        return (false, reasons)
#endif
    }

    // MARK: - Stage 3 + 4: Device Eligibility + Model Access

    private static func checkDeviceAndModelGates() -> (eligibility: AITriState, modelAccess: AITriState, reasons: [AIFailureReason]) {
#if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            return checkDeviceAndModelGatesImpl()
        }
#endif
        return (.unknown, .unknown, [.unknownError])
    }

#if canImport(FoundationModels)
    @available(macOS 26.0, *)
    private static func checkDeviceAndModelGatesImpl() -> (eligibility: AITriState, modelAccess: AITriState, reasons: [AIFailureReason]) {
        let model = SystemLanguageModel.default

        switch model.availability {
        case .available:
            return (.yes, .yes, [])

        case .unavailable(let reason):
            var reasons: [AIFailureReason] = []

            switch reason {
            case .deviceNotEligible:
                reasons.append(.deviceNotEligible)
                return (.no, .no, reasons)
            case .appleIntelligenceNotEnabled:
                reasons.append(.appleIntelligenceDisabled)
                return (.yes, .no, reasons)
            case .modelNotReady:
                reasons.append(.modelNotReady)
                return (.yes, .no, reasons)
            @unknown default:
                reasons.append(.unknownError)
                return (.unknown, .unknown, reasons)
            }
        }
    }
#endif

    // MARK: - Environment Helpers

    private static func currentOSVersion() -> String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }

    private static func currentHardwareClass() -> String {
        var size: size_t = 0
        sysctlbyname("hw.machine", nil, &size, nil, 0)
        var machine = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.machine", &machine, &size, nil, 0)
        return String(cString: machine)
    }
}
