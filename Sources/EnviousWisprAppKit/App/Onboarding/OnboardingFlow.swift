import EnviousWisprCore
import EnviousWisprServices
import Foundation

/// The first-run Setup screens, in order (#4528 plan §3.3).
enum OnboardingStep: String, Codable, CaseIterable, Sendable {
  case welcome, language, speechPick, speechCompare, polishIntro, polishPick, polishSeeAll
  case downloads, permissions, key, gettingReady, practice, film, done
}

/// What the person chose so far. Choices only: no keys, transcripts, grants or readiness.
struct OnboardingChoices: Codable, Equatable, Sendable {
  var languageMode: LanguageMode?
  var speech: ASRBackendType?
  /// A Setup rules polish id ("eg1.mini", "s1mini", "appleIntelligence"), "cloud" for a provider
  /// key, or `OnboardingChoices.polishOff` after Skip AI polish.
  var polish: String?
  var cloudProvider: LLMProvider?
  var cloudModel: String?

  static let polishOff = "off"
  static let polishCloud = "cloud"
}

/// Readiness facts for ONE selection, measured by C2's live owners (delivery, warm engine,
/// polish runtime, AFM availability, key check, permissions). A fact for another selection is
/// ignored, so readiness can never be attributed to a previous choice (plan §3.4, T4).
struct OnboardingReadiness: Equatable, Sendable {
  var speech: ASRBackendType?
  var polish: String?
  /// For a cloud pick: the provider and model the key check passed for.
  var cloudProvider: LLMProvider?
  var cloudModel: String?
  var speechInstalled = false
  var engineWarm = false
  var polishReady = false
  /// The local polish model is installed but its owner reports a failed load (health red, or
  /// the DEBUG `polish-fail` fault). Distinct from loading, which is installed and not ready yet
  /// (plan M83).
  var polishFailed = false
  var microphoneGranted = false
  var accessibilityGranted = false

  var permissionsGranted: Bool { microphoneGranted && accessibilityGranted }

  /// A new language or engine makes the old speech facts stale (plan §3.3.1). Grants stay.
  mutating func clearSpeech() {
    speech = nil
    speechInstalled = false
    engineWarm = false
  }

  /// A new polish pick makes the old polish facts stale.
  mutating func clearPolish() {
    polish = nil
    cloudProvider = nil
    cloudModel = nil
    polishReady = false
    polishFailed = false
  }
}

enum OnboardingPracticeOutcome: String, Codable, Equatable, Sendable {
  case succeeded, skipped
}

/// The recommendation a Setup visit holds (#4528 B2, plan M71): the picks and the rules version
/// they came from, captured from ONE recommendation read, so telemetry never pairs a pick with a
/// rules version that did not produce it. The AI polish cards and the Apple Intelligence state
/// they were ordered for come from that same read (D3a, plan M77), so the screen never re-ranks.
struct OnboardingRecommended: Equatable, Sendable {
  var speech: ASRBackendType = .parakeet
  var polish: String = "eg1.mini"
  var rulesVersion: String = ""
  /// The recommender's two AI polish cards, in screen order, with labels and preselection.
  var polishCards: [SetupRecommendation.PolishCard] = []
  /// What Setup may say about Apple Intelligence, as the cards were ordered for it.
  var appleIntelligence: AppleIntelligenceSetupState = .unavailable
}

/// The flow's whole state. Pure value; C2's coordinator owns the one live copy.
struct OnboardingFlowState: Equatable, Sendable {
  var step: OnboardingStep = .welcome
  var choices = OnboardingChoices()
  var readiness = OnboardingReadiness()
  var practiceOutcome: OnboardingPracticeOutcome?
  /// The recommendation's defaults, used when the person continues without choosing.
  var recommended = OnboardingRecommended()

  /// Ready for practice with the CURRENT selections (plan §3.4, D6).
  var isReadyForPractice: Bool {
    let r = readiness
    guard let speech = choices.speech, r.speech == speech, r.speechInstalled, r.engineWarm,
      r.permissionsGranted
    else { return false }
    let polish = choices.polish ?? OnboardingChoices.polishOff
    if polish == OnboardingChoices.polishOff { return true }
    guard r.polish == polish, r.polishReady else { return false }
    if polish == OnboardingChoices.polishCloud {
      return choices.cloudProvider != nil && r.cloudProvider == choices.cloudProvider
        && r.cloudModel == choices.cloudModel
    }
    return true
  }

  /// The legacy coarse state its readers keep using (plan §3.3.1 projection).
  var legacyState: OnboardingState {
    switch step {
    case .welcome, .language: .notStarted
    case .speechPick, .speechCompare, .polishIntro, .polishPick, .polishSeeAll, .downloads:
      .settingUp
    case .permissions, .key, .gettingReady, .practice, .film: .needsPermissions
    case .done: .completed
    }
  }
}

/// One vocabulary for Setup's buttons and the DEBUG door (plan §3.9).
enum OnboardingEvent: Equatable, Sendable {
  case next
  case back
  case chooseLanguage(LanguageMode)
  case compareSpeech
  case chooseSpeech(ASRBackendType)
  case seeAllPolish
  case choosePolish(String)
  /// A cloud pick names its provider and model (polishSeeAll's cloud tab).
  case chooseCloud(LLMProvider, model: String)
  case skipPolish
  case turnPolishOn
  /// Getting ready's way past a polish model that cannot get ready: stores AI polish off. Speech
  /// and permission readiness are still required (plan M83).
  case continueWithoutPolish
  /// Getting ready's way back to Permissions when a grant was turned off (plan M83).
  case reviewPermissions
  case readinessChanged(OnboardingReadiness)
  case practiceSucceeded
  case skipPractice
  case filmFinished
  case skipFilm
}

/// Work C2 must do for a transition, in order. Narrow on purpose: the coordinator runs them.
enum OnboardingEffect: Equatable, Sendable {
  /// Write the checkpoint BEFORE presenting the new step.
  case persistCheckpoint
  case startSpeechDownload(ASRBackendType)
  case startPolishDownload(String)
  /// Record the practice outcome before completion.
  case recordPracticeOutcome(OnboardingPracticeOutcome)
  /// Write `onboardingState = .completed`, then completion telemetry.
  case markCompleted
}

struct OnboardingTransition: Equatable, Sendable {
  enum Outcome: Equatable, Sendable {
    case moved
    case noOp
    case refused(String)
  }

  var state: OnboardingFlowState
  var outcome: Outcome
  var effects: [OnboardingEffect]
}

/// The pure reducer (#4528 plan §3.3.1). Reads no hardware, setting, clock, credential or service.
enum OnboardingFlow {
  /// Polish ids that download a local model when chosen.
  static func downloadsLocally(_ polish: String) -> Bool {
    polish != OnboardingChoices.polishOff && polish != OnboardingChoices.polishCloud
      && polish != "appleIntelligence"
  }

  static func reduce(_ state: OnboardingFlowState, _ event: OnboardingEvent) -> OnboardingTransition
  {
    var s = state
    func move(_ step: OnboardingStep, _ extra: [OnboardingEffect] = []) -> OnboardingTransition {
      s.step = step
      return OnboardingTransition(state: s, outcome: .moved, effects: [.persistCheckpoint] + extra)
    }
    func chooseSpeech(_ engine: ASRBackendType) -> OnboardingTransition {
      if s.choices.speech != engine { s.readiness.clearSpeech() }
      s.choices.speech = engine
      return move(.polishIntro, [.startSpeechDownload(engine)])
    }
    func choosePolish(_ id: String) -> OnboardingTransition {
      if s.choices.polish != id { s.readiness.clearPolish() }
      s.choices.polish = id
      s.choices.cloudProvider = nil
      s.choices.cloudModel = nil
      return move(.downloads, downloadsLocally(id) ? [.startPolishDownload(id)] : [])
    }
    func chooseCloud(_ provider: LLMProvider, _ model: String) -> OnboardingTransition {
      let same =
        s.choices.polish == OnboardingChoices.polishCloud && s.choices.cloudProvider == provider
        && s.choices.cloudModel == model
      if !same { s.readiness.clearPolish() }
      s.choices.polish = OnboardingChoices.polishCloud
      s.choices.cloudProvider = provider
      s.choices.cloudModel = model
      return move(.downloads)
    }
    let noOp = OnboardingTransition(state: state, outcome: .noOp, effects: [])
    func refuse(_ why: String) -> OnboardingTransition {
      OnboardingTransition(state: state, outcome: .refused(why), effects: [])
    }

    if state.step == .done { return noOp }

    // Facts are recorded at any step; they move the flow only where the table says.
    if case .readinessChanged(let fact) = event {
      s.readiness = fact
      switch state.step {
      case .permissions where fact.permissionsGranted:
        return move(.key)
      case .gettingReady where s.isReadyForPractice:
        return move(.practice)
      default:
        return OnboardingTransition(state: s, outcome: .noOp, effects: [])
      }
    }

    if event == .back {
      guard let previous = previousStep(state.step) else { return noOp }
      return move(previous)
    }

    switch (state.step, event) {
    case (.welcome, .next): return move(.language)

    case (.language, .chooseLanguage(let mode)):
      if s.choices.languageMode != mode { s.readiness.clearSpeech() }
      s.choices.languageMode = mode
      return OnboardingTransition(state: s, outcome: .noOp, effects: [.persistCheckpoint])
    case (.language, .next): return move(.speechPick)

    case (.speechPick, .compareSpeech): return move(.speechCompare)
    case (.speechPick, .chooseSpeech(let engine)), (.speechCompare, .chooseSpeech(let engine)):
      return chooseSpeech(engine)
    case (.speechPick, .next), (.speechCompare, .next):
      return chooseSpeech(s.choices.speech ?? s.recommended.speech)

    case (.polishIntro, .next): return move(.polishPick)

    case (.polishPick, .seeAllPolish): return move(.polishSeeAll)
    case (.polishPick, .choosePolish(OnboardingChoices.polishCloud)),
      (.polishSeeAll, .choosePolish(OnboardingChoices.polishCloud)):
      return refuse("a cloud pick names its provider and model")
    case (.polishPick, .choosePolish(let id)), (.polishSeeAll, .choosePolish(let id)):
      return choosePolish(id)
    case (.polishSeeAll, .chooseCloud(let provider, let model)):
      return chooseCloud(provider, model)
    case (.polishPick, .next):
      // Continuing an existing cloud pick keeps its provider and model.
      if s.choices.polish == OnboardingChoices.polishCloud, let provider = s.choices.cloudProvider,
        let model = s.choices.cloudModel
      {
        return chooseCloud(provider, model)
      }
      return choosePolish(s.choices.polish ?? s.recommended.polish)
    case (.polishPick, .skipPolish), (.polishSeeAll, .skipPolish):
      if s.choices.polish != OnboardingChoices.polishOff { s.readiness.clearPolish() }
      s.choices.polish = OnboardingChoices.polishOff
      s.choices.cloudProvider = nil
      s.choices.cloudModel = nil
      return move(.downloads)

    case (.downloads, .turnPolishOn): return move(.polishPick)
    case (.downloads, .next): return move(.permissions)

    case (.permissions, .next):
      guard s.readiness.permissionsGranted else {
        return refuse("microphone and accessibility are not both granted")
      }
      return move(.key)

    case (.key, .next): return move(s.isReadyForPractice ? .practice : .gettingReady)
    case (.gettingReady, .next):
      return s.isReadyForPractice ? move(.practice) : refuse("not ready for practice")
    case (.gettingReady, .continueWithoutPolish):
      if s.choices.polish != OnboardingChoices.polishOff { s.readiness.clearPolish() }
      s.choices.polish = OnboardingChoices.polishOff
      s.choices.cloudProvider = nil
      s.choices.cloudModel = nil
      // Off needs no polish readiness; speech and both grants still decide.
      return move(s.isReadyForPractice ? .practice : .gettingReady)
    case (.gettingReady, .reviewPermissions):
      return move(.permissions)

    case (.practice, .practiceSucceeded):
      // A resumed Practice opens with empty readiness; a take only counts once the current
      // picks are ready again (plan §3.3.1, C2b).
      guard s.isReadyForPractice else { return refuse("not ready for practice") }
      s.practiceOutcome = .succeeded
      return move(.film, [.recordPracticeOutcome(.succeeded)])
    case (.practice, .skipPractice):
      s.practiceOutcome = .skipped
      return move(.done, [.recordPracticeOutcome(.skipped), .markCompleted])
    case (.practice, .next):
      return refuse("practice ends with a take or Skip practice")

    case (.film, .filmFinished), (.film, .skipFilm): return move(.done, [.markCompleted])

    default: return noOp
    }
  }

  /// The step Back returns to; nil where Back does nothing.
  static func previousStep(_ step: OnboardingStep) -> OnboardingStep? {
    switch step {
    case .welcome, .film, .done: nil
    case .language: .welcome
    case .speechPick: .language
    case .speechCompare: .speechPick
    case .polishIntro: .speechPick
    case .polishPick: .polishIntro
    case .polishSeeAll: .polishPick
    case .downloads: .polishPick
    case .permissions: .downloads
    case .key: .permissions
    case .gettingReady: .key
    case .practice: .key
    }
  }
}
