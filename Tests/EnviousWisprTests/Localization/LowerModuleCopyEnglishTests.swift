import EnviousWisprASR
import Foundation
import Testing

@testable import EnviousWisprAppKit
@testable import EnviousWisprCore
@testable import EnviousWisprLLM
@testable import EnviousWisprPostProcessing

/// #3142: names and messages defined below the app layer are now `String(localized:)`. English
/// must stay exactly as it was. Each oracle is the old literal, typed out. Unit tests run
/// outside the app bundle, so they read English.
@Suite("Lower-module copy keeps its English", .tags(.productOutcome))
struct LowerModuleCopyEnglishTests {

  @Test("vocabulary pack names and lines")
  func packs() {
    let expected: [VocabularyPackID: (String, String)] = [
      .tech: ("Tech", "Programming, cloud, and developer tools."),
      .medical: ("Medical", "Medications, conditions, and clinical terms."),
      .legal: ("Legal", "Litigation, contract, and court terminology."),
      .brands: ("Brands", "Company, product, and app names."),
      .names: ("Names", "Common first names and surnames."),
    ]
    #expect(Set(expected.keys) == Set(VocabularyPackID.allCases))
    for (id, pair) in expected {
      #expect(id.displayName == pair.0)
      #expect(id.blurb == pair.1)
    }
  }

  @Test("Apple Intelligence availability messages")
  func appleIntelligenceMessages() {
    func message(_ reasons: [AIFailureReason], status: AIAvailabilityStatus? = nil) -> String {
      let gate = AIGateResult.passed(summary: "synthetic")
      let gates = AIGateSet(
        build: gate, runtime: gate, eligibility: gate, modelAccess: gate, functionalProbe: gate)
      return AppleIntelligenceAvailabilityReport(
        overallStatus: status ?? (reasons.isEmpty ? .available : .unavailable), gates: gates,
        failureReasons: reasons, osVersion: "synthetic", hardwareClass: "arm64"
      ).userVisibleMessage
    }
    #expect(message([]) == "Apple Intelligence is available and ready to use.")
    #expect(
      message([.notCompiledIn]) == "This build was compiled without Apple Intelligence support.")
    #expect(message([.unsupportedOS]) == "Apple Intelligence requires macOS 26 or later.")
    // #3899: Apple's deviceNotEligible does not say why, so the sentence names no cause.
    #expect(message([.deviceNotEligible]) == "Apple Intelligence isn't available on this Mac.")
    #expect(message([.unsupportedHardware]) == "Apple Intelligence isn't available on this Mac.")
    let disabledMessage = ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27
      ? "At the last check, macOS reported that Apple Intelligence wasn't enabled on this Mac. You can keep dictating or choose another model in Settings > AI Polish."
      : "Apple Intelligence is not enabled. Turn it on in System Settings > Apple Intelligence & Siri."
    #expect(message([.appleIntelligenceDisabled]) == disabledMessage)
    #expect(
      message([.modelNotReady])
        == "The on-device model is not ready. It may still be downloading. Try again later.")
    #expect(
      message([.modelAccessFailed])
        == "Apple Intelligence is available but model initialization failed.")
    #expect(
      message([.generationFailed])
        == "Apple Intelligence model access works but generation failed. Try again later.")
    #expect(message([.unknownError]) == "Apple Intelligence availability could not be determined.")
    #expect(
      message([.generationFailed], status: .degraded)
        == "Apple Intelligence model access works but generation failed. Try again later.")
  }

  /// #3899: a timed-out model-access or probe gate leaves a degraded (or unknown) report with no
  /// reason; it once read "available and ready" beside a Degraded chip and a blocked import.
  @Test("a report that is not available never says ready")
  func notAvailableNeverSaysReady() {
    func message(_ status: AIAvailabilityStatus) -> String {
      let gate = AIGateResult.passed(summary: "synthetic")
      let gates = AIGateSet(
        build: gate, runtime: gate, eligibility: gate, modelAccess: gate, functionalProbe: gate)
      return AppleIntelligenceAvailabilityReport(
        overallStatus: status, gates: gates, failureReasons: [], osVersion: "synthetic",
        hardwareClass: "arm64"
      ).userVisibleMessage
    }
    #expect(
      message(.degraded)
        == "The Apple Intelligence check did not finish in time. It may still work; check again.")
    #expect(message(.unknown) == "Apple Intelligence availability could not be determined.")
    #expect(message(.unavailable) == "Apple Intelligence availability could not be determined.")
    #expect(message(.available) == "Apple Intelligence is available and ready to use.")
  }

  @Test("debug log level names and the no-cleanup provider name")
  func logLevelsAndNone() {
    #expect(DebugLogLevel.info.displayName == "Info (default)")
    #expect(DebugLogLevel.verbose.displayName == "Verbose")
    #expect(DebugLogLevel.debug.displayName == "Debug (all events)")
    #expect(LLMProvider.none.displayName == "None")
  }

  @Test("the Polish step, now its own key, still reads Polish in English")
  func polishStep() {
    #expect(FileImportCoordinator.Step.polish.title == "Polish")
  }

  /// #3142 chunk 8b: the Settings key check, the Diagnostics speed test and its engine error.
  @Test("key check, speed test and engine-not-ready copy keep their English")
  @MainActor
  func keyCheckAndBenchmark() {
    #expect(LLMModelDiscoveryCoordinator.noKeyMessage == "No API key found")
    #expect(
      LLMModelDiscoveryCoordinator.ollamaNotRunningMessage
        == "Ollama is not running. Start it with: ollama serve")
    #expect(
      LLMModelDiscoveryCoordinator.appleIntelligenceUnavailableMessage
        == "Apple Intelligence not available on this system.")
    #expect(LLMModelDiscoveryCoordinator.invalidKeyMessage == "Invalid API key")

    let notReady = ASREngineNotReadyAfterLoadError()
    #expect(notReady.displayMessage == "The engine finished loading but was not ready to use.")
    #expect(notReady.errorDescription == "The engine finished loading but was not ready to use.")
    #expect(
      BenchmarkSuite.modelLoadFailure(notReady)
        == "Model load failed: The engine finished loading but was not ready to use.")
    let other = NSError(
      domain: "Test", code: 1, userInfo: [NSLocalizedDescriptionKey: "Disk gone."])
    #expect(BenchmarkSuite.modelLoadFailure(other) == "Model load failed: Disk gone.")
    #expect(BenchmarkSuite.pipelineComplete == "Pipeline benchmark complete")
  }
}
