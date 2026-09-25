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
    func message(_ reasons: [AIFailureReason]) -> String {
      let gate = AIGateResult.passed(summary: "synthetic")
      let gates = AIGateSet(
        build: gate, runtime: gate, eligibility: gate, modelAccess: gate, functionalProbe: gate)
      return AppleIntelligenceAvailabilityReport(
        overallStatus: reasons.isEmpty ? .available : .unavailable, gates: gates,
        failureReasons: reasons, osVersion: "synthetic", hardwareClass: "arm64"
      ).userVisibleMessage
    }
    #expect(message([]) == "Apple Intelligence is available and ready to use.")
    #expect(
      message([.notCompiledIn]) == "This build was compiled without Apple Intelligence support.")
    #expect(message([.unsupportedOS]) == "Apple Intelligence requires macOS 26 or later.")
    #expect(
      message([.deviceNotEligible])
        == "This Mac does not support Apple Intelligence. Requires Apple Silicon (M1 or later).")
    #expect(
      message([.appleIntelligenceDisabled])
        == "Apple Intelligence is not enabled. Turn it on in System Settings > Apple Intelligence & Siri."
    )
    #expect(
      message([.modelNotReady])
        == "The on-device model is not ready — it may still be downloading. Try again later.")
    #expect(
      message([.modelAccessFailed])
        == "Apple Intelligence is available but model initialization failed.")
    #expect(
      message([.generationFailed])
        == "Apple Intelligence model access works but generation failed. Try again later.")
    #expect(message([.unknownError]) == "Apple Intelligence availability could not be determined.")
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
}
