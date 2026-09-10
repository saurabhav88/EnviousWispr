import EnviousWisprCore
import EnviousWisprLLM
import EnviousWisprServices

// MARK: - May the import proceed with the engine it has chosen? (#2772 chunk 3)

/// #2772 finding 7a: the Polish step let a user press Continue with a cloud engine selected
/// and no API key at all. The card said "Needs a key" and the wizard moved on, then the
/// import ran and polish was silently skipped. The approved prototype disables Continue and
/// says why, which is what this decides.
///
/// **Why this is not `ProviderStatusMapping`.** That mapping answers "what do I show for
/// this engine", and its answers are deliberately reassuring where a state is transient —
/// a cloud key that is present but never validated reads "Not checked", which is correct to
/// display and says nothing about whether the run may start. This answers "may the run
/// start", and the two disagree on real states. They read the SAME coordinator values, so a
/// new engine must be added to both; both are exhaustive switches over `LLMProvider`, which
/// is what makes the compiler ask rather than a reader remembering to.
///
/// Pure and value-typed on purpose: `FileImportPolishGateTests` walks the whole grid with no
/// app running.
enum FileImportPolishReadiness: Equatable {
  case ready
  case blocked(FileImportPolishBlock)

  var isReady: Bool { self == .ready }

  /// The footer sentence under the disabled Continue button, or nil when nothing blocks.
  var footer: String? {
    switch self {
    case .ready: return nil
    case .blocked(let block): return block.footer
    }
  }
}

/// Why the run may not start. Three of these are the user's move and one clears itself; the
/// sentences differ because "finish setting this up" is wrong advice for a Mac that cannot
/// run the engine at all, and worse advice while we are still asking.
enum FileImportPolishBlock: Equatable {
  /// The user must finish setting the chosen engine up, or choose a different one.
  case needsSetup
  /// We are still asking, and the answer arrives on its own.
  case checking
  /// The saved credential could not be read at all. Distinct from "there is no key",
  /// because telling a user with a working key that they have none is the failure mode
  /// §7 of the plan names.
  case couldNotCheckKey
  /// The engine reports something other than available, and we cannot say why from here.
  ///
  /// Distinct from `needsSetup`, which tells the user to finish something, and from a claim
  /// that the Mac cannot run it — an overall availability status does not establish that,
  /// and the editor below already shows the report's own explanation and a re-check. Found
  /// by Codex, on a first version that said "cannot run on this Mac" for a degraded or
  /// unknown reading.
  case availabilityUnconfirmed
  /// A key is TYPED but not saved. Distinct from "no key", because the user has done the
  /// work and is one button from finished, and because polish reads the Keychain and not
  /// the text field, so an unsaved draft would run as no key at all.
  case unsavedKey

  var footer: String {
    switch self {
    case .needsSetup:
      // Founder copy, from the approved prototype. Do not reword.
      return "Finish setting this one up, or pick another."
    case .checking:
      return "Checking that engine. One moment."
    case .availabilityUnconfirmed:
      return "That engine is not ready. Check its status below, or pick another."
    case .couldNotCheckKey:
      return "We could not check your saved key. Try again, or pick another."
    case .unsavedKey:
      return "Press Save key to finish, or pick another."
    }
  }
}

/// What the Keychain said about this provider's stored key. Three states, never two: the
/// `Bool?` these come from uses `nil` for "not read yet, or the read failed", and collapsing
/// that into "absent" is how a locked Keychain becomes a false "needs a key".
enum FileImportSavedKeyState: Equatable {
  case present
  case absent
  case unknown

  /// From `ProviderSetupModel`'s per-provider `Bool?`.
  static func from(_ saved: Bool?) -> FileImportSavedKeyState {
    switch saved {
    case .some(true): return .present
    case .some(false): return .absent
    case nil: return .unknown
    }
  }
}

enum FileImportPolishGate {
  /// The whole decision, as a pure function of the same coordinator states
  /// `ProviderStatusMapping.status` reads, plus the two facts a status chip has no reason to
  /// carry: whether the Keychain read succeeded, and whether an Ollama model is armed.
  static func readiness(
    provider: LLMProvider,
    savedKey: FileImportSavedKeyState,
    hasUnsavedKeyDraft: Bool,
    keyValidation: LLMModelDiscoveryCoordinator.KeyValidationState,
    egOneInstall: EGOneInstallState,
    egOneHealth: EGOneHealth,
    s1MiniInstall: EGOneInstallState,
    s1MiniHealth: EGOneHealth,
    appleStatus: AIAvailabilityStatus?,
    ollamaSetup: OllamaSetupState,
    ollamaModelIsArmed: Bool
  ) -> FileImportPolishReadiness {
    switch provider {
    case .none:
      // Polish explicitly off for imports. There is nothing to set up, and the transcript
      // still gets numbers, dates, saved words and filler removal.
      return .ready
    case .egOne:
      return localServer(install: egOneInstall, health: egOneHealth)
    case .s1Mini:
      return localServer(install: s1MiniInstall, health: s1MiniHealth)
    case .appleIntelligence:
      return apple(appleStatus)
    case .openAI, .gemini, .claude:
      return cloud(
        savedKey: savedKey, hasUnsavedDraft: hasUnsavedKeyDraft, validation: keyValidation)
    case .ollama:
      return ollama(ollamaSetup, modelIsArmed: ollamaModelIsArmed)
    }
  }

  // A bundled engine: it must be on disk AND answering. Anything in motion clears itself,
  // so the user is asked to wait rather than to act.
  private static func localServer(
    install: EGOneInstallState, health: EGOneHealth
  ) -> FileImportPolishReadiness {
    switch install {
    case .downloading, .verifying:
      return .blocked(.checking)
    case .notInstalled, .paused, .updatePaused, .failed:
      return .blocked(.needsSetup)
    case .installed:
      switch health {
      case .green: return .ready
      // Starting is the ordinary state right after a selection: the run start awaits the
      // probe itself, so this resolves without the user doing anything.
      case .yellow: return .blocked(.checking)
      case .red: return .blocked(.needsSetup)
      }
    }
  }

  // Apple Intelligence needs macOS 26 and a Mac that has it switched on. `nil` is "we have
  // not asked yet" and the availability check is already in flight from the lifecycle.
  // Everything else blocks WITHOUT diagnosing: `.unavailable` on an overall report does not
  // establish that this Mac cannot run it, and the editor below shows the per-gate reason
  // and a re-check that this line cannot.
  private static func apple(_ status: AIAvailabilityStatus?) -> FileImportPolishReadiness {
    switch status {
    case .available: return .ready
    case nil: return .blocked(.checking)
    case .unavailable, .degraded, .unknown: return .blocked(.availabilityUnconfirmed)
    }
  }

  // A cloud engine needs a key that is actually stored. A stored key that has never been
  // validated is allowed through: validation costs a network round trip nobody asked for,
  // and refusing on it would block every user who has a working key and has not pressed
  // Refresh this session.
  private static func cloud(
    savedKey: FileImportSavedKeyState, hasUnsavedDraft: Bool,
    validation: LLMModelDiscoveryCoordinator.KeyValidationState
  ) -> FileImportPolishReadiness {
    if case .validating = validation { return .blocked(.checking) }
    switch savedKey {
    case .unknown: return .blocked(.couldNotCheckKey)
    // Typed but not saved is its own answer. Polish reads the Keychain, never the field, so
    // a draft left unsaved runs exactly as if no key existed; a user who has typed one and
    // is told "finish setting this up" reasonably believes they already did.
    case .absent: return .blocked(hasUnsavedDraft ? .unsavedKey : .needsSetup)
    case .present:
      if case .invalid = validation { return .blocked(.needsSetup) }
      return .ready
    }
  }

  // Ollama is a separate app. Not installed, not running and no models are all the user's
  // move; `.ready` still needs a model chosen, which is finding 7f's second half.
  private static func ollama(
    _ state: OllamaSetupState, modelIsArmed: Bool
  ) -> FileImportPolishReadiness {
    switch state {
    case .detecting:
      return .blocked(.checking)
    case .notInstalled, .installedNotRunning, .runningNoModels, .error:
      return .blocked(.needsSetup)
    // A pull in flight is motion, not a missing step, and the model it is fetching is the
    // one about to be armed.
    case .pullingModel:
      return .blocked(.checking)
    case .ready:
      return modelIsArmed ? .ready : .blocked(.needsSetup)
    }
  }
}

// MARK: - The card subtitle, driven by the same decision (#2772 finding 7g)

/// The one line under an engine's name on the Polish step.
///
/// Founder, on the shipped screen showing a fixed word whatever the state: "Card subtitles
/// are STATE-DRIVEN, and this is the free tell for 7a." So this is computed FROM the gate's
/// verdict rather than from a second reading of the same states. A card cannot say
/// "Cloud based" beside a Continue button the gate has disabled, because there is no
/// separate mapping in which the two could disagree.
enum FileImportPolishSubtitle {
  static func text(
    provider: LLMProvider, readiness: FileImportPolishReadiness
  ) -> String {
    switch readiness {
    case .ready:
      switch provider {
      case .egOne, .s1Mini, .appleIntelligence: return "On device"
      // NOT "On this Mac". Readiness does not decide LOCATION: the daemon proxies some
      // models to Ollama's own servers, and a card claiming local processing over one of
      // those is a false privacy claim on the screen where the user approves the choice.
      // Location is `coordinator.polishOllamaLocalityNow()`, which knows the model. Found
      // by Codex.
      case .ollama: return "Ready"
      case .openAI, .gemini, .claude: return "Cloud based"
      case .none: return "No cleanup"
      }
    case .blocked(.needsSetup):
      switch provider {
      // Every Ollama setup step happens in the Ollama app: install it, start it, or add a
      // model to it. One sentence covers all three honestly.
      case .ollama: return "Needs the app"
      case .openAI, .gemini, .claude: return "Needs a key"
      case .egOne, .s1Mini: return "Needs setup"
      // Unreachable: `.appleIntelligence` never blocks with `.needsSetup` and `.none` never
      // blocks at all. Spelled out rather than defaulted so a new state has to be decided.
      case .appleIntelligence, .none: return "Needs setup"
      }
    case .blocked(.unsavedKey): return "Key not saved"
    case .blocked(.checking): return "Checking"
    case .blocked(.availabilityUnconfirmed): return "Not ready"
    case .blocked(.couldNotCheckKey): return "Key not checked"
    }
  }
}
