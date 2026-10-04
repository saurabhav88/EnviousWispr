import EnviousWisprCore
import EnviousWisprLLM
import Testing

@testable import EnviousWisprAppKit

/// #3438. Whether the chosen AI polish model's setup is unfinished, which decides whether the
/// app warns. When this is wrong, a person whose polish is silently off is never told, or a
/// person with a working setup is nagged.
@Suite("Unfinished AI polish setup (#3438)", .tags(.productOutcome))
struct PolishSetupReadinessTests {

  /// A Mac where every provider is fully set up, so each test changes only its one fact.
  private static func facts(
    egOneInstall: EGOneInstallState = .installed(version: "1.2"),
    s1MiniInstall: EGOneInstallState = .installed(version: "1.0"),
    egOneHealth: EGOneHealth = .green,
    appleStatus: AIAvailabilityStatus? = .available,
    appleFailureReasons: [AIFailureReason] = [],
    appleIsChecking: Bool = false,
    cloudValidation: LLMModelDiscoveryCoordinator.KeyValidationState = .idle,
    credentialRevisions: [LLMProvider: UInt64] = [.openAI: 1, .gemini: 1, .claude: 1],
    cloudVerdict: PolishCloudVerdict? = nil,
    openAIKeySaved: Bool? = true,
    geminiKeySaved: Bool? = true,
    claudeKeySaved: Bool? = true,
    ollamaSetup: OllamaSetupState = .ready,
    ollamaModel: OllamaModelFact = .installed
  ) -> PolishSetupFacts {
    PolishSetupFacts(
      egOneInstall: egOneInstall, egOneHealth: egOneHealth,
      s1MiniInstall: s1MiniInstall, s1MiniHealth: .green,
      appleStatus: appleStatus, appleFailureReasons: appleFailureReasons,
      appleIsChecking: appleIsChecking,
      validationProvider: .openAI, cloudValidation: cloudValidation,
      credentialRevisions: credentialRevisions,
      cloudVerdicts: cloudVerdict.map { [$0.provider: $0] } ?? [:],
      openAIKeySaved: openAIKeySaved, geminiKeySaved: geminiKeySaved,
      claudeKeySaved: claudeKeySaved,
      ollamaSetup: ollamaSetup, ollamaModel: ollamaModel)
  }

  private static func evaluate(
    _ provider: LLMProvider, _ facts: PolishSetupFacts = facts()
  ) -> PolishSetupReadiness {
    PolishSetupReadiness.evaluate(provider: provider, facts: facts)
  }

  @Test("a fully set-up Mac has no problem for any provider, and polish off never has one")
  func readyControls() {
    for provider in LLMProvider.allCases {
      #expect(Self.evaluate(provider) == .noProblem, "\(provider)")
    }
    // Off stays quiet even when every other fact is broken.
    let broken = Self.facts(
      egOneInstall: .notInstalled, appleStatus: .unavailable,
      appleFailureReasons: [.unsupportedOS], openAIKeySaved: false, ollamaSetup: .notInstalled)
    #expect(Self.evaluate(.none, broken) == .noProblem)
  }

  @Test("a cloud model with no saved key is a missing key, for that provider only")
  func cloudKeyMissing() {
    let facts = Self.facts(openAIKeySaved: false)
    #expect(Self.evaluate(.openAI, facts) == .problem(.cloudKeyMissing(.openAI)))
    #expect(Self.evaluate(.gemini, facts) == .noProblem)
    #expect(Self.evaluate(.claude, facts) == .noProblem)
  }

  @Test("a Keychain read that failed is unknown, never a missing key")
  func cloudKeyUnknown() {
    #expect(Self.evaluate(.gemini, Self.facts(geminiKeySaved: nil)) == .unknown)
  }

  @Test("only a typed rejection of the key saved now is a rejected key")
  func cloudKeyRejectedNeedsATypedVerdict() {
    func verdict(_ provider: LLMProvider, revision: UInt64, _ result: PolishCloudVerdict.Result)
      -> PolishCloudVerdict
    {
      PolishCloudVerdict(provider: provider, credentialRevision: revision, result: result)
    }
    // A rejection of the current key.
    #expect(
      Self.evaluate(.claude, Self.facts(cloudVerdict: verdict(.claude, revision: 1, .rejected)))
        == .problem(.cloudKeyRejected(.claude)))
    // The same rejection earned on a key that has since been replaced says nothing.
    #expect(
      Self.evaluate(.claude, Self.facts(cloudVerdict: verdict(.claude, revision: 0, .rejected)))
        == .noProblem)
    // No known revision for the provider: the verdict cannot be tied to the saved key.
    #expect(
      Self.evaluate(
        .claude,
        Self.facts(credentialRevisions: [:], cloudVerdict: verdict(.claude, revision: 1, .rejected)))
        == .noProblem)
    // A verdict about another provider says nothing about this one.
    #expect(
      Self.evaluate(.openAI, Self.facts(cloudVerdict: verdict(.gemini, revision: 1, .rejected)))
        == .noProblem)
    // A check in flight, and one that ended without an answer about the key.
    #expect(
      Self.evaluate(.openAI, Self.facts(cloudVerdict: verdict(.openAI, revision: 1, .checking)))
        == .checking)
    #expect(
      Self.evaluate(
        .openAI, Self.facts(cloudVerdict: verdict(.openAI, revision: 1, .inconclusive)))
        == .unknown)
    #expect(
      Self.evaluate(.openAI, Self.facts(cloudVerdict: verdict(.openAI, revision: 1, .accepted)))
        == .noProblem)
    // `.invalid` also carries network and provider failures, so its message is never proof.
    #expect(
      Self.evaluate(.openAI, Self.facts(cloudValidation: .invalid("Invalid API key")))
        == .noProblem)
    // No key at all is the missing-key answer, whatever a verdict says.
    #expect(
      Self.evaluate(
        .claude,
        Self.facts(cloudVerdict: verdict(.claude, revision: 1, .rejected), claudeKeySaved: false))
        == .problem(.cloudKeyMissing(.claude)))
  }

  @Test("each unfinished local install is its own problem, and EG-1 never reads S1-mini")
  func localEngines() {
    let cases: [(EGOneInstallState, PolishSetupProblem)] = [
      (.notInstalled, .localEngineNotDownloaded(.egOne)),
      (.paused, .localEngineDownloadPaused(.egOne)),
      (.updatePaused(resumable: true, targetVersion: "1.3"), .localEngineUpdatePaused(.egOne)),
      (.failed(.disk), .localEngineFailed(.egOne)),
      (.downloading(fractionCompleted: 0.4, upgrade: nil), .localEngineDownloading(.egOne)),
      (.verifying, .localEngineVerifying(.egOne)),
    ]
    for (install, problem) in cases {
      #expect(Self.evaluate(.egOne, Self.facts(egOneInstall: install)) == .problem(problem))
      // The other engine is unaffected by EG-1's state.
      #expect(Self.evaluate(.s1Mini, Self.facts(egOneInstall: install)) == .noProblem)
    }
    #expect(
      Self.evaluate(.s1Mini, Self.facts(s1MiniInstall: .notInstalled))
        == .problem(.localEngineNotDownloaded(.s1Mini)))
  }

  @Test("an installed engine whose server is not healthy is not an unfinished setup")
  func installedButUnhealthyIsNotAProblem() {
    #expect(Self.evaluate(.egOne, Self.facts(egOneHealth: .red(reason: "Server stopped"))) == .noProblem)
  }

  @Test("downloading, verifying and Apple's model not ready are informational")
  func informationalProblems() {
    #expect(PolishSetupProblem.localEngineDownloading(.egOne).isActionable == false)
    #expect(PolishSetupProblem.localEngineVerifying(.s1Mini).isActionable == false)
    #expect(PolishSetupProblem.appleModelNotReady.isActionable == false)
    #expect(PolishSetupProblem.cloudKeyMissing(.openAI).isActionable)
    #expect(PolishSetupProblem.localEngineNotDownloaded(.egOne).isActionable)
    #expect(PolishSetupProblem.appleUnavailable(.unsupportedOS).isActionable)
  }

  @Test("Apple Intelligence names the reason the report gives, and never invents one")
  func appleReasons() {
    func apple(_ reasons: [AIFailureReason]) -> PolishSetupReadiness {
      Self.evaluate(
        .appleIntelligence, Self.facts(appleStatus: .unavailable, appleFailureReasons: reasons))
    }
    #expect(apple([.unsupportedOS]) == .problem(.appleUnavailable(.unsupportedOS)))
    #expect(apple([.deviceNotEligible]) == .problem(.appleUnavailable(.deviceNotEligible)))
    #expect(
      apple([.appleIntelligenceDisabled]) == .problem(.appleUnavailable(.appleIntelligenceDisabled))
    )
    #expect(apple([.modelNotReady]) == .problem(.appleModelNotReady))
    // Transient failures keep their existing handling and are not a setup problem.
    #expect(apple([.generationFailed]) == .unknown)
    #expect(apple([.modelAccessFailed]) == .unknown)
    // An overall unavailable status with no reason cannot say why.
    #expect(apple([]) == .unknown)
    // Not reported yet, or reported unknown: say nothing.
    #expect(Self.evaluate(.appleIntelligence, Self.facts(appleStatus: nil)) == .unknown)
    #expect(Self.evaluate(.appleIntelligence, Self.facts(appleStatus: .unknown)) == .unknown)
    #expect(Self.evaluate(.appleIntelligence, Self.facts(appleIsChecking: true)) == .checking)
    // Degraded means a probe timed out or failed, which does not confirm polish works.
    #expect(Self.evaluate(.appleIntelligence, Self.facts(appleStatus: .degraded)) == .unknown)
  }

  @Test("Ollama: each missing step is named, motion is checking, an error is unknown")
  func ollama() {
    func ollama(_ state: OllamaSetupState, _ model: OllamaModelFact = .installed)
      -> PolishSetupReadiness
    {
      Self.evaluate(.ollama, Self.facts(ollamaSetup: state, ollamaModel: model))
    }
    #expect(ollama(.notInstalled) == .problem(.ollamaNotInstalled))
    #expect(ollama(.installedNotRunning) == .problem(.ollamaNotRunning))
    #expect(ollama(.runningNoModels) == .problem(.ollamaNoModel))
    #expect(ollama(.ready, .notChosen) == .problem(.ollamaNoModel))
    #expect(ollama(.ready, .notInstalled) == .problem(.ollamaModelNotInstalled))
    #expect(ollama(.detecting) == .checking)
    #expect(ollama(.pullingModel(progress: 0.5, status: "pulling")) == .checking)
    #expect(ollama(.error("boom")) == .unknown)
  }

  @Test("the Ollama model fact matches names canonically against the daemon's list")
  func ollamaModelFact() {
    #expect(OllamaModelFact.from(model: "", downloaded: ["llama2:latest"]) == .notChosen)
    #expect(OllamaModelFact.from(model: "llama2", downloaded: ["llama2:latest"]) == .installed)
    #expect(OllamaModelFact.from(model: "qwen3:4b", downloaded: ["llama2:latest"]) == .notInstalled)
  }
}
