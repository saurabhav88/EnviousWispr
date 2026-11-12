import EnviousWisprCore
import Foundation

/// Which languages each speech engine can transcribe, handed in by the app (#4528 plan §3.2).
///
/// Services never imports ASR (ASR imports Services; the reverse edge would be a cycle), so the
/// app reads the engines' own authorities (`ParakeetBackend.lockableLanguageCodes`,
/// `LanguageTypes.whisperSupportedLanguages`) and passes the lists here as data.
public struct SpeechLanguageCapabilities: Sendable, Equatable {
  /// Base language codes Parakeet transcribes.
  public let parakeet: Set<String>
  /// Base language codes Whisper transcribes; nil means no restriction.
  public let whisper: Set<String>?

  public init(parakeet: Set<String>, whisper: Set<String>?) {
    self.parakeet = parakeet
    self.whisper = whisper
  }

  func contains(_ code: String, in set: String) -> Bool {
    switch set {
    case "parakeet": return parakeet.contains(code)
    case "whisper": return whisper.map { $0.contains(code) } ?? true
    default: return false
    }
  }

  /// True when any engine transcribes `code`.
  func supportsAny(_ code: String) -> Bool {
    parakeet.contains(code) || (whisper.map { $0.contains(code) } ?? true)
  }
}

/// One recommended Setup, for display and seeding (#4528 plan §3.2). Advice, never a setting.
public struct SetupRecommendation: Sendable, Equatable {
  /// The dictation language mode to keep. Auto stays Auto; a locked language stays locked.
  public let languageMode: LanguageMode
  /// The Mac's language to offer first on the Language screen, when an engine can transcribe it.
  public let suggestedLanguage: String?
  /// The speech engine to recommend.
  public let speech: ASRBackendType
  /// The rule identifier of the recommended local polish model ("eg1.mini").
  public let polishPrimary: String
  /// The two AI polish cards, in screen order.
  public let polishCards: [PolishCard]
  /// What Setup may say about Apple Intelligence.
  public let appleIntelligence: AppleIntelligenceSetupState
  /// Start the polish download at the same time as the speech download.
  public let parallelDownloads: Bool
  /// The rules revision this advice came from, for telemetry.
  public let rulesRevision: Int
  public let rulesVersion: String

  public struct PolishCard: Sendable, Equatable {
    /// A rule identifier: an EG-1 size, or "appleIntelligence".
    public let model: String
    public let label: Label
    /// The card selected when the screen opens.
    public let preselected: Bool
  }

  /// Card labels from the approved mockup (`polishPlan`, Main.baseline-before-audit.html:613-620).
  public enum Label: String, Sendable, Equatable {
    /// "Easiest way to start" (Apple Intelligence, when it is available).
    case easiestWayToStart
    /// "Recommended · best results" (the EG-1 size beside an available Apple Intelligence).
    case recommendedBestResults
    /// "Recommended for your Mac" (the EG-1 size when Apple Intelligence is not offered).
    case recommendedForYourMac
    /// "Even better results" (a larger neighbouring size).
    case evenBetterResults
    /// "Smaller download" (a smaller neighbouring size).
    case smallerDownload
  }
}

/// Turns a Mac profile and rules into one recommended Setup (#4528 plan §3.2). Pure: it reads
/// nothing, stores nothing, downloads nothing.
public enum SetupRecommender {
  public static func recommend(
    profile: MacProfile, rules: SetupRules, languageMode: LanguageMode,
    capabilities: SpeechLanguageCapabilities
  ) -> SetupRecommendation {
    let suggested = profile.primaryMacLanguageCode.flatMap {
      capabilities.supportsAny($0) ? $0 : nil
    }
    // The language the speech engine must handle: the locked language, or under Auto the Mac's
    // own language (English when the Mac's language is unknown or unsupported).
    let speechLanguage: String = {
      if case .locked(let code) = languageMode, let base = MacProfile.baseCode(code) { return base }
      return suggested ?? "en"
    }()
    let lockedNonEnglish: Bool = {
      guard case .locked(let code) = languageMode, let base = MacProfile.baseCode(code) else {
        return false
      }
      return base != "en"
    }()

    func matches(_ c: SetupRules.Conditions, primary: String? = nil) -> Bool {
      if let min = c.memoryAtLeastGiB, profile.memoryGiB < min { return false }
      if let max = c.memoryBelowGiB, profile.memoryGiB >= max { return false }
      if let wanted = c.lockedNonEnglish, wanted != lockedNonEnglish { return false }
      if let set = c.languageIn, !capabilities.contains(speechLanguage, in: set) { return false }
      if let wanted = c.primary, wanted != primary { return false }
      return true
    }
    func first(_ table: [SetupRules.Row], primary: String? = nil) -> String {
      // Validated tables always end with a catch-all, so a row always matches.
      table.first { matches($0.when, primary: primary) }?.pick ?? table[table.count - 1].pick
    }

    let speechPick = first(rules.speechChoice)
    let speech = SetupRules.registeredSpeech[speechPick] ?? .parakeet
    let primary = first(rules.polishPrimary)
    let cards: [SetupRecommendation.PolishCard]
    if profile.appleIntelligence == .available {
      cards = [
        .init(model: "appleIntelligence", label: .easiestWayToStart, preselected: false),
        .init(model: primary, label: .recommendedBestResults, preselected: true),
      ]
    } else {
      let neighbour = first(rules.polishNeighbour, primary: primary)
      let label: SetupRecommendation.Label =
        sizeRank(neighbour) > sizeRank(primary) ? .evenBetterResults : .smallerDownload
      cards = [
        .init(model: primary, label: .recommendedForYourMac, preselected: true),
        .init(model: neighbour, label: label, preselected: false),
      ]
    }
    return SetupRecommendation(
      languageMode: languageMode, suggestedLanguage: suggested, speech: speech,
      polishPrimary: primary, polishCards: cards, appleIntelligence: profile.appleIntelligence,
      parallelDownloads: profile.memoryGiB >= rules.parallelDownloadsMinMemoryGiB,
      rulesRevision: rules.revision, rulesVersion: rules.rulesVersion)
  }

  /// EG-1 sizes smallest first; other models sort after them.
  static func sizeRank(_ model: String) -> Int {
    switch SetupRules.registeredPolish[model]?.size {
    case .micro: 0
    case .mini: 1
    case .full: 2
    case nil: 3
    }
  }
}
