import EnviousWisprCore
import Foundation
import os

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

/// The one composition point between the recommender and the app (#4528 B3, plan §3.2): which
/// rules are in force and which Mac profile advice is read from. Every recommendation consumer
/// (launch EG-1 seeding, Settings size cards, removal fallback, the provider "Recommended"
/// label, the fresh-install polish default, the dictation language lock default, Transcribe a
/// File badges) reads it here, so no consumer reads rules or hardware on its own.
public enum SetupAdvice {
  /// The rules in force.
  ///
  /// B2 INTEGRATION HANDOFF (outstanding delivery gate, plan §3.11 M39): when the signed store
  /// lands, this returns the store's trusted rules (`SetupRulesStore.live.current().rules`), the
  /// higher of the bundled copy and the last good signed download. Until then it is the bundled
  /// copy; bundled-only is not the final delivery.
  public static var activeRules: SetupRules { bundledRules }

  private static let bundledRules: SetupRules = (try? SetupRules.bundled()) ?? .builtIn

  /// This Mac for advice: memory, macOS, chip and the Mac's own language list. Free disk space is
  /// not advice (the download preflight reads it), so it is left out of the per-render read.
  private static let profileReader = MacProfileReader(
    physicalMemoryBytes: MacProfileReader.live.physicalMemoryBytes,
    macOSMajor: MacProfileReader.live.macOSMajor, chipName: MacProfileReader.live.chipName,
    freeDiskBytes: { nil }, systemLanguages: MacProfileReader.live.systemLanguages)

  /// The full recommendation for this Mac.
  public static func recommendation(
    languageMode: LanguageMode, appleIntelligence: AppleIntelligenceSetupState = .unavailable,
    capabilities: SpeechLanguageCapabilities
  ) -> SetupRecommendation {
    SetupRecommender.recommend(
      profile: adviceProfile(appleIntelligence: appleIntelligence), rules: activeRules,
      languageMode: languageMode, capabilities: capabilities)
  }

  /// The recommended EG-1 size. It depends only on memory and the dictation language, never on
  /// Apple Intelligence or the speech engines, so they are not asked for.
  ///
  /// Advice only (#4473, founder 2026-11-10, moved here by #4528): not from which sizes are
  /// published or installed, not from the interface language, not from what was recognised
  /// recently. The size the app USES is the stored preference (`SettingsManager.egOneSize`); this
  /// value only seeds that preference once, for a user with no EG-1 history
  /// (`EGOneSizeResolution`), and labels a card "Best for this Mac". Automatic language detection
  /// counts as English, so the 8 GB default stays Micro (rules row `lockedNonEnglish`).
  public static func recommendedEGOneSize(languageMode: LanguageMode) -> EGOneSize {
    egOneSize(of: recommendation(languageMode: languageMode, capabilities: .polishOnly).polishPrimary)
  }

  /// The polish provider Setup preselects: the provider of the preselected card (EG-1 under the
  /// approved rules, D1/D2). Read by the provider "Recommended" label and the fresh-install
  /// default.
  public static func recommendedPolishProvider(languageMode: LanguageMode = .auto) -> LLMProvider {
    let advice = recommendation(languageMode: languageMode, capabilities: .polishOnly)
    let preselected = advice.polishCards.first { $0.preselected }?.model ?? advice.polishPrimary
    return SetupRules.registeredPolish[preselected]?.provider ?? .egOne
  }

  /// The Mac's own primary language code ("fr" on a French Mac), for language defaults. Callers
  /// still apply their own supported-language check.
  public static var macLanguageCode: String? {
    adviceProfile(appleIntelligence: .unavailable).primaryMacLanguageCode
  }

  /// The one profile every piece of advice reads (the DEBUG override applies here only).
  private static func adviceProfile(appleIntelligence: AppleIntelligenceSetupState) -> MacProfile {
    let real = profileReader.read(appleIntelligence: appleIntelligence)
    #if DEBUG
      return applying(debugProfile, to: real)
    #else
      return real
    #endif
  }

  #if DEBUG
    /// #4528 plan §3.9: a faked Mac for ADVICE only (the door's `onboarding profile`), so CLI UAT
    /// can walk every recommendation branch on one Mac. It changes what Setup and Settings
    /// recommend while set, never a setting, a download, readiness or a real availability check.
    /// A nil field keeps the real value.
    public struct DebugProfile: Equatable, Sendable {
      public var memoryGiB: Int?
      public var macOSMajor: Int?
      public var appleIntelligence: AppleIntelligenceSetupState?
      public var macLanguages: [String]?

      public init(
        memoryGiB: Int? = nil, macOSMajor: Int? = nil,
        appleIntelligence: AppleIntelligenceSetupState? = nil, macLanguages: [String]? = nil
      ) {
        self.memoryGiB = memoryGiB
        self.macOSMajor = macOSMajor
        self.appleIntelligence = appleIntelligence
        self.macLanguages = macLanguages
      }
    }

    /// The faked profile: each set field replaces the real one; chip and free disk stay real.
    static func applying(_ fake: DebugProfile?, to real: MacProfile) -> MacProfile {
      guard let fake else { return real }
      return MacProfile(
        memoryGiB: fake.memoryGiB ?? real.memoryGiB, chipName: real.chipName,
        macOSMajor: fake.macOSMajor ?? real.macOSMajor,
        appleIntelligence: fake.appleIntelligence ?? real.appleIntelligence,
        macLanguages: fake.macLanguages ?? real.macLanguages, freeDiskBytes: real.freeDiskBytes)
    }

    private static let debugProfileLock = OSAllocatedUnfairLock<DebugProfile?>(initialState: nil)

    public static var debugProfile: DebugProfile? {
      get { debugProfileLock.withLock { $0 } }
      set { debugProfileLock.withLock { $0 = newValue } }
    }
  #endif

  /// The EG-1 size a polish-table pick names. Validated polish tables pick only EG-1 sizes
  /// (`SetupRules.polishTablePicks`), so a pick without a size is a broken rules invariant.
  static func egOneSize(of pick: String) -> EGOneSize {
    guard let size = SetupRules.registeredPolish[pick]?.size else {
      assertionFailure("polish pick \(pick) has no EG-1 size; SetupRules validation should refuse it")
      return .micro
    }
    return size
  }
}

extension SpeechLanguageCapabilities {
  /// For questions that do not involve speech (the EG-1 size, the polish provider).
  public static let polishOnly = SpeechLanguageCapabilities(parakeet: [], whisper: [])
}
