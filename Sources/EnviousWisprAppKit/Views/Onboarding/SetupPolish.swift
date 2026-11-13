import EnviousWisprCore
import EnviousWisprServices
import Foundation

/// AI polish's choice rules and words for Setup (#4528 D3a, plan M77; mockup `polishPlan`,
/// `polishCards`, `egTiles`, `allLocal`, copy verbatim). Order, labels and preselection come from
/// the flow's held recommendation (`OnboardingRecommended.polishCards`); identities from
/// `SetupRules.registeredPolish`; EG-1 names and facts from `EGOneSizeCardCopy` and the
/// `EGOneSizeCatalog`. Nothing here ranks a model.
enum SetupPolish {
  /// The EG-1 sizes as See all lists them, largest first (`EGOneSizeCardPresenter.order`).
  static let egOneOrder = EGOneSizeCardPresenter.order

  /// The rule id of an EG-1 size ("eg1.mini").
  static func id(of size: EGOneSize) -> String {
    let match = SetupRules.registeredPolish.first { $0.value == .egOne(size) }?.key
    assert(match != nil, "no Setup rules id for EG-1 \(size)")
    return match ?? "eg1.\(size.rawValue)"
  }

  /// The rule id of a provider's one local model ("s1mini", "appleIntelligence").
  static func id(of provider: LLMProvider) -> String? {
    SetupRules.registeredPolish.first { $0.value == .singleModel(for: provider) }?.key
  }

  static func model(_ id: String) -> LocalPolishModelID? { SetupRules.registeredPolish[id] }

  /// A local model's manifest download size from the owners the presenter injects (EG-1's
  /// catalog, S1-mini's bundled manifest); nil for Apple Intelligence or an unknown id.
  static func downloadBytes(_ id: String, sources: SetupScreenSources) -> Int64? {
    guard let model = model(id), model.provider != .appleIntelligence else { return nil }
    if let size = model.size { return sources.egOneSizeCatalog.downloadBytes[size] }
    return model.provider == .s1Mini ? sources.s1MiniDownloadBytes : nil
  }

  /// S1-mini in Setup: offered under Auto and for English, as in the approved mockup (`s1Ok`).
  /// No app contract restricts it (Settings offers it everywhere, "happiest in English"); Setup
  /// is the opinionated path, so another locked language sees it disabled with the reason.
  static func s1MiniSupports(_ language: LanguageMode?) -> Bool {
    guard case .locked(let code)? = language, let base = MacProfile.baseCode(code) else {
      return true
    }
    return base == "en"
  }

  /// Whether `id` can be chosen now: every EG-1 size always (memory advice is not a lock), Apple
  /// Intelligence only when available, S1-mini per `s1MiniSupports`.
  static func isSelectable(
    _ id: String, appleIntelligence: AppleIntelligenceSetupState, language: LanguageMode?
  ) -> Bool {
    guard let model = model(id) else { return false }
    if model.size != nil { return true }
    switch model.provider {
    case .appleIntelligence: return appleIntelligence == .available
    case .s1Mini: return s1MiniSupports(language)
    case .egOne, .openAI, .gemini, .claude, .ollama, .none: return false
    }
  }

  /// The card the recommendation preselects.
  static func preselected(_ recommended: OnboardingRecommended) -> String {
    recommended.polishCards.first { $0.preselected }?.model ?? recommended.polish
  }

  /// The pick screen's selection: the first of the draft, the committed pick and the
  /// preselected card that can be chosen now and is one of its cards or any EG-1 size. As the
  /// mockup's `hideAll` does, an EG-1 size picked under See all survives the return (the CTA
  /// names it; the two cards stay as recommended); an S1-mini pick falls back to the
  /// preselected card.
  static func pickDisplayed(
    draft: String?, committed: String?, recommended: OnboardingRecommended,
    language: LanguageMode?
  ) -> String {
    let cards = recommended.polishCards.map(\.model)
    let preselected = preselected(recommended)
    for candidate in [draft, committed, preselected] {
      if let candidate,
        cards.isEmpty || cards.contains(candidate) || model(candidate)?.size != nil,
        isSelectable(
          candidate, appleIntelligence: recommended.appleIntelligence, language: language)
      {
        return candidate
      }
    }
    return preselected
  }

  /// See all's selection: the first of the draft, the committed pick and the preselected card
  /// that can be chosen now.
  static func seeAllDisplayed(
    draft: String?, committed: String?, recommended: OnboardingRecommended,
    language: LanguageMode?
  ) -> String {
    let preselected = preselected(recommended)
    for candidate in [draft, committed, preselected] {
      if let candidate,
        isSelectable(
          candidate, appleIntelligence: recommended.appleIntelligence, language: language)
      {
        return candidate
      }
    }
    return preselected
  }

  // MARK: Words

  /// A model's name: "EG-1 Mini", "Apple Intelligence", "S1-mini" (product names, not translated).
  static func name(_ id: String) -> String {
    guard let model = model(id) else { return id }
    if let size = model.size { return EGOneSizeCardCopy.title(size) }
    return model.provider.displayName
  }

  /// The tag on a recommended card (mockup `polishPlan` labels).
  static func label(_ label: SetupRecommendation.Label) -> String {
    switch label {
    case .easiestWayToStart:
      String(
        localized: "Easiest way to start", comment: "Setup AI polish card tag: Apple Intelligence.")
    case .recommendedBestResults:
      String(
        localized: "Recommended · best results",
        comment: "Setup AI polish card tag: the EG-1 size beside Apple Intelligence.")
    case .recommendedForYourMac:
      String(
        localized: "Recommended for your Mac",
        comment: "Setup AI polish card tag: the EG-1 size recommended for this Mac's memory.")
    case .evenBetterResults:
      String(
        localized: "Even better results",
        comment: "Setup AI polish card tag: a larger EG-1 size than the recommended one.")
    case .smallerDownload:
      String(
        localized: "Smaller download",
        comment: "Setup AI polish card tag: a smaller EG-1 size than the recommended one.")
    }
  }

  /// The sentence under a model's name on a card (mockup `POLISH[...].line`).
  static func line(_ id: String) -> String {
    guard let model = model(id) else { return "" }
    switch model.size {
    case .full?:
      return String(
        localized: "Our largest model, for the very best results.",
        comment: "Setup AI polish card: the line under EG-1.")
    case .mini?:
      return String(
        localized: "Our best balance of quality, speed and size.",
        comment: "Setup AI polish card: the line under EG-1 Mini.")
    case .micro?:
      return String(
        localized: "Our lightest model. Quick to download and run.",
        comment: "Setup AI polish card: the line under EG-1 Micro.")
    case nil:
      return String(
        localized: "Built into your Mac. Ready the moment you finish setup.",
        comment: "Setup AI polish card: the line under Apple Intelligence.")
    }
  }

  /// The one-line reason on a See all EG-1 tile (mockup: the line's first sentence).
  static func tileReason(_ size: EGOneSize) -> String {
    switch size {
    case .full:
      String(localized: "Our largest model", comment: "Setup AI polish See all: EG-1 tile.")
    case .mini:
      String(
        localized: "Our best balance of quality, speed and size",
        comment: "Setup AI polish See all: EG-1 Mini tile.")
    case .micro:
      String(localized: "Our lightest model", comment: "Setup AI polish See all: EG-1 Micro tile.")
    }
  }

  /// Polish intro's six capabilities (mockup `showPoints`).
  static let introPoints: [LocalizedStringResource] = [
    LocalizedStringResource("Fixes filler words", comment: "Setup polish intro: a capability."),
    LocalizedStringResource(
      "Formats numbers, dates and times", comment: "Setup polish intro: a capability."),
    LocalizedStringResource("Corrects grammar", comment: "Setup polish intro: a capability."),
    LocalizedStringResource("Formats lists", comment: "Setup polish intro: a capability."),
    LocalizedStringResource(
      "Recognizes when you misspeak", comment: "Setup polish intro: a capability."),
    LocalizedStringResource("Formats emails", comment: "Setup polish intro: a capability."),
  ]

  /// Apple Intelligence's See all line for each state. Unknown or unavailable says nothing
  /// about why (`AppleIntelligenceSetupState.unavailable`).
  static func appleIntelligenceLine(_ state: AppleIntelligenceSetupState) -> String {
    switch state {
    case .available:
      String(
        localized: "Built in. Ready right away.",
        comment: "Setup AI polish See all: Apple Intelligence can run now.")
    case .turnedOff:
      String(
        localized: "Turn it on in System Settings first.",
        comment: "Setup AI polish See all: Apple Intelligence is turned off.")
    case .needsNewerMacOS:
      String(
        localized: "Needs macOS 26 or newer.",
        comment: "Setup AI polish See all: this macOS is too old for Apple Intelligence.")
    case .gettingReady:
      String(
        localized: "Getting ready. Check again in a moment.",
        comment: "Setup AI polish See all: Apple Intelligence's model is still downloading.")
    case .unavailable:
      String(
        localized: "Not available on this Mac right now.",
        comment: "Setup AI polish See all: Apple Intelligence cannot run; the reason is unknown.")
    }
  }

  /// S1-mini's See all line, with the licence credit (`PolishRailCatalog`: "Superwhisper" as
  /// written).
  static func s1MiniLine(supported: Bool) -> String {
    supported
      ? String(
        localized: "Light and quick · By Superwhisper",
        comment:
          "Setup AI polish See all: the line under S1-mini. Required licence credit; keep Superwhisper as written."
      )
      : String(
        localized: "For English dictation · By Superwhisper",
        comment:
          "Setup AI polish See all: S1-mini is unavailable for the chosen language. Required licence credit; keep Superwhisper as written."
      )
  }
}
