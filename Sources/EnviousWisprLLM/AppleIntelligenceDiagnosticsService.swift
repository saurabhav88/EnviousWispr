import EnviousWisprCore
import Foundation

#if canImport(FoundationModels)
  import FoundationModels
#endif

/// Runs layered gate checks to produce a structured Apple Intelligence availability report.
/// Each gate returns an AIGateResult with explicit status and failure reasons.
///
/// Gate stages:
/// 1. Build/Binary — was FoundationModels compiled in?
/// 2. OS/Runtime Preconditions — is macOS version sufficient? (compile-time framework gate)
/// 3. Device Eligibility — is this device eligible for Apple Intelligence? (locale deferred)
/// 4. Model Access — can a LanguageModelSession be created?
/// 5. Functional Probe — can a minimal generation succeed? (timeout-bounded)
///
/// Limb: never throws, never blocks indefinitely. Returns a report regardless of outcome.
/// Telemetry/breadcrumbs are NOT emitted here — the coordinator owns that responsibility.
public enum AppleIntelligenceDiagnosticsService {

  /// Timeout budget for the functional probe (Stage 5).
  private static let probeTimeoutSeconds: TimeInterval = 3.0

  /// Overall timeout budget for the entire diagnostics run (default 10s).
  /// If elapsed time exceeds this, remaining gates get .timedOut status.
  private static let totalTimeoutSeconds: TimeInterval = 10.0

  /// Stage 4 timeout budget (session creation).
  private static let sessionTimeoutSeconds: TimeInterval = 2.0

  /// Run all gate checks and produce a structured report.
  /// Async because stages 4-5 may need to create sessions / run generation.
  public static func runDiagnostics() async -> AppleIntelligenceAvailabilityReport {
    let start = CFAbsoluteTimeGetCurrent()
    let osVersion = currentOSVersion()
    let hardwareClass = currentHardwareClass()

    // Stage 1: Build / Binary Gate
    let buildResult = checkBuildGate()

    // Stage 2: OS / Runtime Preconditions Gate
    let runtimeResult: AIGateResult
    if elapsedMs(since: start) < totalTimeoutMs() {
      runtimeResult = checkOSRuntimeGate()
    } else {
      runtimeResult = .timedOut(summary: "Not run — total budget expired")
    }

    // Stage 3: Device Eligibility Gate
    let eligibilityResult: AIGateResult
    if buildResult.status == .passed && runtimeResult.status == .passed {
      if elapsedMs(since: start) < totalTimeoutMs() {
        eligibilityResult = checkEligibilityGate()
      } else {
        eligibilityResult = .timedOut(summary: "Not run — total budget expired")
      }
    } else {
      eligibilityResult = .skipped(summary: "Skipped — build or runtime gate failed")
    }

    // Stage 4: Model Access Gate (with per-stage timeout)
    let modelAccessResult: AIGateResult
    if eligibilityResult.status == .passed {
      if elapsedMs(since: start) < totalTimeoutMs() {
        modelAccessResult = await checkModelAccessGateWithTimeout()
      } else {
        modelAccessResult = .timedOut(summary: "Not run — total budget expired")
      }
    } else {
      modelAccessResult = .skipped(summary: "Skipped — eligibility gate did not pass")
    }

    // Stage 5: Functional Probe Gate (async, timeout-bounded)
    let probeResult: AIGateResult
    if modelAccessResult.status == .passed {
      if elapsedMs(since: start) < totalTimeoutMs() {
        probeResult = await checkFunctionalProbeGate()
      } else {
        probeResult = .timedOut(summary: "Not run — total budget expired")
      }
    } else {
      probeResult = .skipped(summary: "Skipped — model access gate did not pass")
    }

    let gates = AIGateSet(
      build: buildResult,
      runtime: runtimeResult,
      eligibility: eligibilityResult,
      modelAccess: modelAccessResult,
      functionalProbe: probeResult
    )

    // Dedupe while preserving order — prevents noisy telemetry from duplicate reasons
    var seen = Set<AIFailureReason>()
    let failureReasons = gates.allGates.flatMap { $0.result.reasons }.filter {
      seen.insert($0).inserted
    }

    let overallStatus = AppleIntelligenceAvailabilityReport.deriveOverallStatus(from: gates)
    let durationMs = Int((CFAbsoluteTimeGetCurrent() - start) * 1000)

    return AppleIntelligenceAvailabilityReport(
      overallStatus: overallStatus,
      gates: gates,
      failureReasons: failureReasons,
      osVersion: osVersion,
      hardwareClass: hardwareClass,
      checkDurationMs: durationMs
    )
  }

  // MARK: - Timeout Helpers

  private static func totalTimeoutMs() -> Int {
    Int(totalTimeoutSeconds * 1000)
  }

  private static func elapsedMs(since start: CFAbsoluteTime) -> Int {
    Int((CFAbsoluteTimeGetCurrent() - start) * 1000)
  }

  // MARK: - Stage 1: Build / Binary Gate

  private static func checkBuildGate() -> AIGateResult {
    let start = CFAbsoluteTimeGetCurrent()
    #if canImport(FoundationModels)
      let ms = Int((CFAbsoluteTimeGetCurrent() - start) * 1000)
      return .passed(summary: "FoundationModels compiled in", durationMs: ms)
    #else
      let ms = Int((CFAbsoluteTimeGetCurrent() - start) * 1000)
      return .failed(
        reasons: [.notCompiledIn], summary: "FoundationModels not compiled in", durationMs: ms)
    #endif
  }

  // MARK: - Stage 2: OS / Runtime Preconditions Gate

  private static func checkOSRuntimeGate() -> AIGateResult {
    let start = CFAbsoluteTimeGetCurrent()
    #if canImport(FoundationModels)
      if #available(macOS 26.0, *) {
        let ms = Int((CFAbsoluteTimeGetCurrent() - start) * 1000)
        return .passed(summary: "macOS 26+ runtime available", durationMs: ms)
      } else {
        let ms = Int((CFAbsoluteTimeGetCurrent() - start) * 1000)
        return .failed(reasons: [.unsupportedOS], summary: "macOS 26+ required", durationMs: ms)
      }
    #else
      let ms = Int((CFAbsoluteTimeGetCurrent() - start) * 1000)
      return .failed(
        reasons: [.frameworkMissingAtRuntime],
        summary: "FoundationModels framework missing at runtime", durationMs: ms)
    #endif
  }

  // MARK: - Stage 3: Device Eligibility Gate

  private static func checkEligibilityGate() -> AIGateResult {
    #if canImport(FoundationModels)
      if #available(macOS 26.0, *) {
        return checkEligibilityGateImpl()
      }
    #endif
    return .failed(
      reasons: [.unknownError], summary: "Unexpected: eligibility check reached without framework")
  }

  #if canImport(FoundationModels)
    @available(macOS 26.0, *)
    private static func checkEligibilityGateImpl() -> AIGateResult {
      let start = CFAbsoluteTimeGetCurrent()
      let model = SystemLanguageModel.default

      switch model.availability {
      case .available:
        let ms = Int((CFAbsoluteTimeGetCurrent() - start) * 1000)
        return .passed(summary: "Device eligible, Apple Intelligence enabled", durationMs: ms)

      case .unavailable(let reason):
        let ms = Int((CFAbsoluteTimeGetCurrent() - start) * 1000)
        switch reason {
        case .deviceNotEligible:
          return .failed(
            reasons: [.deviceNotEligible], summary: "Device not eligible for Apple Intelligence",
            durationMs: ms)
        case .appleIntelligenceNotEnabled:
          return .failed(
            reasons: [.appleIntelligenceDisabled],
            summary: "Apple Intelligence not enabled in System Settings", durationMs: ms)
        case .modelNotReady:
          return .failed(
            reasons: [.modelNotReady], summary: "Model not ready (may still be downloading)",
            durationMs: ms)
        @unknown default:
          return .failed(
            reasons: [.unknownError], summary: "Unknown unavailability reason from system",
            durationMs: ms)
        }
      }
    }
  #endif

  // MARK: - Stage 4: Model Access Gate

  private static func checkModelAccessGateWithTimeout() async -> AIGateResult {
    #if canImport(FoundationModels)
      if #available(macOS 26.0, *) {
        return await checkModelAccessGateWithTimeoutImpl()
      }
    #endif
    return .failed(
      reasons: [.modelAccessFailed],
      summary: "Unexpected: model access check reached without framework")
  }

  #if canImport(FoundationModels)
    @available(macOS 26.0, *)
    private static func checkModelAccessGateWithTimeoutImpl() async -> AIGateResult {
      let start = CFAbsoluteTimeGetCurrent()

      // Race session creation against a timeout
      do {
        let result = try await withThrowingTaskGroup(of: AIGateResult.self) { group in
          group.addTask { @Sendable in
            _ = LanguageModelSession(
              model: .default,
              instructions: "You are a diagnostic probe."
            )
            let ms = Int((CFAbsoluteTimeGetCurrent() - start) * 1000)
            return .passed(summary: "Session created successfully", durationMs: ms)
          }

          group.addTask { @Sendable in
            try await Task.sleep(for: .seconds(sessionTimeoutSeconds))
            let ms = Int((CFAbsoluteTimeGetCurrent() - start) * 1000)
            return .timedOut(
              summary: "Session creation timed out after \(Int(sessionTimeoutSeconds))s",
              durationMs: ms)
          }

          let first = try await group.next()!
          group.cancelAll()
          return first
        }
        return result
      } catch {
        let ms = Int((CFAbsoluteTimeGetCurrent() - start) * 1000)
        return .failed(
          reasons: [.sessionInitFailed],
          summary: "Session creation error: \(error.localizedDescription)", durationMs: ms)
      }
    }
  #endif

  // MARK: - Stage 5: Functional Probe Gate

  private static func checkFunctionalProbeGate() async -> AIGateResult {
    #if canImport(FoundationModels)
      if #available(macOS 26.0, *) {
        return await checkFunctionalProbeGateImpl()
      }
    #endif
    return .skipped(summary: "Functional probe not available without framework")
  }

  #if canImport(FoundationModels)
    @available(macOS 26.0, *)
    private static func checkFunctionalProbeGateImpl() async -> AIGateResult {
      let start = CFAbsoluteTimeGetCurrent()

      // Race the probe against a timeout
      do {
        let result = try await withThrowingTaskGroup(of: AIGateResult.self) { group in
          group.addTask { @Sendable in
            do {
              let session = LanguageModelSession(
                model: .default,
                instructions: "Respond with exactly the word OK."
              )
              let response = try await session.respond(to: "Probe")
              let text = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
              let ms = Int((CFAbsoluteTimeGetCurrent() - start) * 1000)
              if text.isEmpty {
                return .failed(
                  reasons: [.generationFailed], summary: "Probe returned empty response",
                  durationMs: ms)
              }
              let normalized = text.lowercased()
              let isValidProbe =
                normalized == "ok" || normalized == "ok." || normalized.hasPrefix("ok")
              if isValidProbe {
                return .passed(summary: "Probe succeeded", durationMs: ms)
              } else {
                return .passed(
                  summary: "Probe returned unexpected content: \(text.prefix(30))", durationMs: ms)
              }
            } catch {
              let ms = Int((CFAbsoluteTimeGetCurrent() - start) * 1000)
              return .failed(
                reasons: [.generationFailed],
                summary: "Probe generation failed: \(error.localizedDescription)", durationMs: ms)
            }
          }

          group.addTask { @Sendable in
            try await Task.sleep(for: .seconds(probeTimeoutSeconds))
            let ms = Int((CFAbsoluteTimeGetCurrent() - start) * 1000)
            return .timedOut(
              summary: "Probe timed out after \(Int(probeTimeoutSeconds))s", durationMs: ms)
          }

          let first = try await group.next()!
          group.cancelAll()
          return first
        }
        return result
      } catch {
        let ms = Int((CFAbsoluteTimeGetCurrent() - start) * 1000)
        return .failed(
          reasons: [.generationFailed], summary: "Probe task error: \(error.localizedDescription)",
          durationMs: ms)
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
    return String(
      decoding: machine.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self)
  }
}
