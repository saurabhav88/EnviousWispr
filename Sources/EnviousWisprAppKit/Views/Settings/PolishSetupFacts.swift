import EnviousWisprCore
import EnviousWisprLLM
import Security

// MARK: - The setup facts every polish policy reads (#3438)
//
// Three policies answer three different questions about the same provider state:
// `ProviderStatusMapping` (what word does the chip show), `FileImportPolishGate` (may an import
// start) and `PolishSetupReadiness` (is the chosen model's setup unfinished, so a warning is
// due). They disagree on real states on purpose: a saved cloud key that was never validated
// reads "Key saved", is admitted by the import, and is not a setup problem. What they must
// NOT disagree on is the facts, so the facts are one value, captured once per render and
// handed to all three.

/// What the Keychain said about one provider's stored key. Three states, never two: `nil`
/// means "not read yet, or the read failed", and collapsing that into "absent" is how a locked
/// Keychain becomes a false "needs a key".
enum SavedKeyState: Equatable {
  case present
  case absent
  case unknown

  /// From a per-provider `Bool?` (`ProviderSetupModel`).
  static func from(_ saved: Bool?) -> SavedKeyState {
    switch saved {
    case .some(true): return .present
    case .some(false): return .absent
    case nil: return .unknown
    }
  }

  /// One provider's saved-key fact read straight from the Keychain, for a caller with no
  /// editor on screen (the DEBUG import door). Key-less engines answer `.absent`; empty or
  /// `errSecItemNotFound` is absent; any other failure is unknown. Synchronous like the
  /// editor's reads; never call it from a view body.
  static func read(_ provider: LLMProvider, keychain: KeychainManager) -> SavedKeyState {
    let id: String
    switch provider {
    case .openAI: id = KeychainManager.openAIKeyID
    case .gemini: id = KeychainManager.geminiKeyID
    case .claude: id = KeychainManager.claudeKeyID
    case .ollama, .appleIntelligence, .egOne, .s1Mini, .none: return .absent
    }
    do {
      return try keychain.retrieve(key: id).isEmpty ? .absent : .present
    } catch KeyStoreError.retrieveFailed(let status) where status == errSecItemNotFound {
      return .absent
    } catch {
      return .unknown
    }
  }

  /// Back to the `Bool?` the facts store, for a caller that read one provider's key itself.
  var asSavedFlag: Bool? {
    switch self {
    case .present: return true
    case .absent: return false
    case .unknown: return nil
    }
  }
}

/// Whether the Ollama model a surface will ask for is one the daemon actually has. Surface
/// specific: dictation asks for `settings.ollamaModel`, an import for its own field.
enum OllamaModelFact: Equatable {
  /// No model name is set for this surface.
  case notChosen
  /// The name matches a model in the daemon's own list (canonically, `llama2` == `llama2:latest`).
  case installed
  /// A name is set but the daemon does not have it (removed with `ollama rm`, or never pulled).
  case notInstalled

  static func from(model: String, downloaded: [String]) -> OllamaModelFact {
    guard !model.isEmpty else { return .notChosen }
    return FileImportPolishGate.ollamaModelIsArmed(model, downloaded: downloaded)
      ? .installed : .notInstalled
  }
}

/// A typed verdict about ONE provider's key, tied to the credential it was earned on. A
/// verdict about a key that has since been replaced says nothing about the new one, so the
/// revision must match the provider's current one before any policy reads it.
struct PolishCloudVerdict: Equatable {
  enum Result: Equatable {
    case checking
    case accepted
    case rejected
    /// The check finished without an answer about the key (network, provider error).
    case inconclusive
  }

  let provider: LLMProvider
  let credentialRevision: UInt64
  let result: Result
  /// #3438: when the answer arrived, so it is ordered against what a dictation's own request
  /// learned about the same key.
  var decidedAt: ContinuousClock.Instant = .now
  /// #3438: the last DEFINITIVE answer (accepted or rejected) about the same key, carried by a
  /// check still running or one that could not tell, so neither erases what is known.
  var definitive: Definitive? = nil

  struct Definitive: Equatable {
    let rejected: Bool
    let decidedAt: ContinuousClock.Instant
  }

  /// This verdict's own definitive answer, or the one it carries.
  var lastDefinitive: Definitive? {
    switch result {
    case .accepted: return Definitive(rejected: false, decidedAt: decidedAt)
    case .rejected: return Definitive(rejected: true, decidedAt: decidedAt)
    case .checking, .inconclusive: return definitive
    }
  }
}

/// Everything the three policies read, captured once so they see the same snapshot.
struct PolishSetupFacts {
  let egOneInstall: EGOneInstallState
  let egOneHealth: EGOneHealth
  let s1MiniInstall: EGOneInstallState
  let s1MiniHealth: EGOneHealth
  let appleStatus: AIAvailabilityStatus?
  /// The latest report's reasons, empty when there is no report. The overall status alone
  /// cannot say WHY Apple Intelligence is unavailable, and the warnings must.
  let appleFailureReasons: [AIFailureReason]
  let appleIsChecking: Bool
  /// The provider the coordinator's verdict belongs to; another provider's verdict is never
  /// evidence about this one.
  let validationProvider: LLMProvider?
  let cloudValidation: LLMModelDiscoveryCoordinator.KeyValidationState
  /// The saved credential's revision per cloud provider; a save or a clear moves it.
  let credentialRevisions: [LLMProvider: UInt64]
  /// The typed key verdict, read only when its provider and credential revision match the
  /// current ones. `.invalid(String)` above also carries network and provider failures and is
  /// never evidence of a rejected key.
  /// The key check's verdicts, one per provider (#3438), each judged against that provider's
  /// current credential revision.
  let cloudVerdicts: [LLMProvider: PolishCloudVerdict]
  /// The CONFIRMED saved-key read per cloud provider: true present, false absent, nil when the
  /// Keychain read failed or has not answered.
  let openAIKeySaved: Bool?
  let geminiKeySaved: Bool?
  let claudeKeySaved: Bool?
  let ollamaSetup: OllamaSetupState
  let ollamaModel: OllamaModelFact

  func savedKey(for provider: LLMProvider) -> Bool? {
    switch provider {
    case .openAI: return openAIKeySaved
    case .gemini: return geminiKeySaved
    case .claude: return claudeKeySaved
    case .ollama, .appleIntelligence, .egOne, .s1Mini, .none: return nil
    }
  }

  /// The saved-key fact as the import gate reads it. Key-less engines answer `.absent`, which
  /// no policy reads for them.
  func savedKeyState(for provider: LLMProvider) -> SavedKeyState {
    switch provider {
    case .openAI, .gemini, .claude: return .from(savedKey(for: provider))
    case .ollama, .appleIntelligence, .egOne, .s1Mini, .none: return .absent
    }
  }

  /// The discovery verdict only when it is about `provider`.
  func validation(for provider: LLMProvider) -> LLMModelDiscoveryCoordinator.KeyValidationState {
    validationProvider == provider ? cloudValidation : .idle
  }
}

extension PolishSetupFacts {
  /// The facts composed from the live app-level owners. The things that differ per surface
  /// are passed in: which verdict counts here, the saved-key reads (the page editor holds its
  /// own, the DEBUG import door reads one provider), the typed verdict, and the surface's
  /// Ollama model. Credential revisions always come from the one presence owner.
  @MainActor
  static func live(
    localPolishRuntimes: LocalPolishRuntimeSet,
    aiAvailability: AIAvailabilityCoordinator,
    setup: SetupCoordinator,
    validationProvider: LLMProvider?,
    cloudValidation: LLMModelDiscoveryCoordinator.KeyValidationState,
    openAIKeySaved: Bool?, geminiKeySaved: Bool?, claudeKeySaved: Bool?,
    savedKeyPresence: SavedKeyPresence,
    cloudVerdicts: [LLMProvider: PolishCloudVerdict],
    ollamaModel: String
  ) -> PolishSetupFacts {
    PolishSetupFacts(
      egOneInstall: localPolishRuntimes.egOne.installState,
      egOneHealth: localPolishRuntimes.egOne.health,
      s1MiniInstall: localPolishRuntimes.s1Mini.installState,
      s1MiniHealth: localPolishRuntimes.s1Mini.health,
      appleStatus: aiAvailability.latestReport?.overallStatus,
      appleFailureReasons: aiAvailability.latestReport?.failureReasons ?? [],
      appleIsChecking: aiAvailability.isChecking,
      validationProvider: validationProvider,
      cloudValidation: cloudValidation,
      credentialRevisions: savedKeyPresence.revisions, cloudVerdicts: cloudVerdicts,
      openAIKeySaved: openAIKeySaved, geminiKeySaved: geminiKeySaved,
      claudeKeySaved: claudeKeySaved,
      ollamaSetup: setup.ollamaSetup.setupState,
      ollamaModel: .from(
        model: ollamaModel,
        downloaded: setup.ollamaSetup.downloadedModels.map(\.exactName)))
  }
}

// MARK: - Is the chosen model's setup unfinished?

/// A setup the person has not finished, for the provider they chose. Informational cases are
/// motion the app finishes by itself; the rest are the person's move.
enum PolishSetupProblem: Hashable {
  case cloudKeyMissing(LLMProvider)
  case cloudKeyRejected(LLMProvider)
  case ollamaNotInstalled
  case ollamaNotRunning
  /// Ollama runs but no model is chosen, or it has no models at all.
  case ollamaNoModel
  /// The chosen Ollama model is not in the daemon's list.
  case ollamaModelNotInstalled
  case localEngineNotDownloaded(LLMProvider)
  case localEngineDownloadPaused(LLMProvider)
  case localEngineUpdatePaused(LLMProvider)
  case localEngineFailed(LLMProvider)
  case localEngineDownloading(LLMProvider)
  case localEngineVerifying(LLMProvider)
  /// Only the reasons the person can act on or must be told about: no macOS 26, a Mac that
  /// is not eligible, Apple Intelligence switched off, or a build without it.
  case appleUnavailable(AIFailureReason)
  /// Apple's model is not ready. It MAY still be downloading; that is not established.
  case appleModelNotReady

  /// False for motion the app finishes on its own; those get an OK-only notice.
  var isActionable: Bool {
    switch self {
    case .localEngineDownloading, .localEngineVerifying, .appleModelNotReady:
      return false
    case .cloudKeyMissing, .cloudKeyRejected, .ollamaNotInstalled, .ollamaNotRunning,
      .ollamaNoModel, .ollamaModelNotInstalled, .localEngineNotDownloaded,
      .localEngineDownloadPaused, .localEngineUpdatePaused, .localEngineFailed,
      .appleUnavailable:
      return true
    }
  }
}

/// The answer for the chosen provider. Unknown and checking are not problems: a warning shows
/// only for a CONFIRMED unfinished setup.
enum PolishSetupReadiness: Equatable {
  case noProblem
  /// The facts cannot say (a Keychain read failed, no availability report, a transient error).
  case unknown
  /// A check is running and will answer by itself.
  case checking
  case problem(PolishSetupProblem)

  static func evaluate(provider: LLMProvider, facts: PolishSetupFacts) -> PolishSetupReadiness {
    switch provider {
    case .none:
      return .noProblem
    case .egOne:
      return local(.egOne, install: facts.egOneInstall)
    case .s1Mini:
      return local(.s1Mini, install: facts.s1MiniInstall)
    case .appleIntelligence:
      return apple(facts)
    case .ollama:
      return ollama(facts.ollamaSetup, model: facts.ollamaModel)
    case .openAI, .gemini, .claude:
      return cloud(provider, facts: facts)
    }
  }

  // Install state only. An installed engine whose server is starting or unhealthy is not an
  // unfinished setup: the run starts the server itself (see `FileImportPolishGate`).
  private static func local(
    _ provider: LLMProvider, install: EGOneInstallState
  ) -> PolishSetupReadiness {
    switch install {
    case .installed: return .noProblem
    case .notInstalled: return .problem(.localEngineNotDownloaded(provider))
    case .paused: return .problem(.localEngineDownloadPaused(provider))
    case .updatePaused: return .problem(.localEngineUpdatePaused(provider))
    case .failed: return .problem(.localEngineFailed(provider))
    case .downloading: return .problem(.localEngineDownloading(provider))
    case .verifying: return .problem(.localEngineVerifying(provider))
    }
  }

  // The overall status alone never invents a reason. Initialization and generation failures
  // are transient and keep their existing handling, so they read as unknown here.
  private static func apple(_ facts: PolishSetupFacts) -> PolishSetupReadiness {
    if facts.appleIsChecking { return .checking }
    switch facts.appleStatus {
    // `.degraded` is produced when model access or the functional probe timed out or failed
    // (`AppleIntelligenceDiagnostics`), so it does not confirm that polish works.
    case nil, .unknown, .degraded:
      return .unknown
    case .available:
      return .noProblem
    case .unavailable:
      let reasons = facts.appleFailureReasons
      for reason in [
        AIFailureReason.notCompiledIn, .unsupportedOS, .deviceNotEligible, .unsupportedHardware,
        .appleIntelligenceDisabled,
      ] where reasons.contains(reason) {
        return .problem(.appleUnavailable(reason))
      }
      if reasons.contains(.modelNotReady) { return .problem(.appleModelNotReady) }
      return .unknown
    }
  }

  private static func ollama(
    _ state: OllamaSetupState, model: OllamaModelFact
  ) -> PolishSetupReadiness {
    switch state {
    case .detecting, .pullingModel: return .checking
    case .error: return .unknown
    case .notInstalled: return .problem(.ollamaNotInstalled)
    case .installedNotRunning: return .problem(.ollamaNotRunning)
    case .runningNoModels: return .problem(.ollamaNoModel)
    case .ready:
      switch model {
      case .installed: return .noProblem
      case .notChosen: return .problem(.ollamaNoModel)
      case .notInstalled: return .problem(.ollamaModelNotInstalled)
      }
    }
  }

  // A stored key that was never validated is not a setup problem; a rejection counts only
  // when a typed verdict says so about the key that is saved now.
  private static func cloud(
    _ provider: LLMProvider, facts: PolishSetupFacts
  ) -> PolishSetupReadiness {
    switch facts.savedKeyState(for: provider) {
    case .unknown:
      return .unknown
    case .absent:
      return .problem(.cloudKeyMissing(provider))
    case .present:
      guard let verdict = facts.cloudVerdicts[provider],
        verdict.provider == provider,
        facts.credentialRevisions[provider] == verdict.credentialRevision
      else {
        return .noProblem
      }
      switch verdict.result {
      case .checking: return .checking
      case .accepted: return .noProblem
      case .rejected: return .problem(.cloudKeyRejected(provider))
      case .inconclusive:
        // A check that could not tell leaves the last definitive answer about this key.
        guard let known = verdict.definitive else { return .unknown }
        return known.rejected ? .problem(.cloudKeyRejected(provider)) : .noProblem
      }
    }
  }
}
