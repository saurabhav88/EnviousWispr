import EnviousWisprCore
import Foundation

// The Settings Map identity of each option the pickers build from a Core collection (#3482 plan
// §3.6 item 2). SettingsMap derives its choice entries by mapping the same collections the
// pickers iterate through these, so an option added to a collection needs an identity here
// (the switches are exhaustive) and then appears in the map in the picker's order.
// Core cannot name SettingsMapID, so the identities live beside the map in the view layer.

extension ModelUnloadPolicy {
  var settingsMapID: SettingsMapID {
    switch self {
    case .never: .unloadModelNever
    case .immediately: .unloadModelImmediately
    case .twoMinutes: .unloadModelTwoMinutes
    case .fiveMinutes: .unloadModelFiveMinutes
    case .tenMinutes: .unloadModelTenMinutes
    case .fifteenMinutes: .unloadModelFifteenMinutes
    case .sixtyMinutes: .unloadModelOneHour
    }
  }
}

extension RecordingPillDesign {
  var settingsMapID: SettingsMapID {
    switch self {
    case .classic: .pillStyleCapsule
    case .readingWell: .pillStyleReadingWell
    case .levelRail: .pillStyleLevelRail
    }
  }
}

extension S1Styling {
  var settingsMapID: SettingsMapID {
    switch self {
    case .casual: .s1ToneCasual
    case .semiCasual: .s1ToneSemiCasual
    case .semiFormal: .s1ToneSemiFormal
    case .formal: .s1ToneFormal
    }
  }
}

extension S1Structure {
  var settingsMapID: SettingsMapID {
    switch self {
    case .prose: .s1StructureProse
    case .lists: .s1StructureLists
    }
  }
}

extension S1Context {
  var settingsMapID: SettingsMapID {
    switch self {
    case .general: .s1ContextGeneral
    case .email: .s1ContextEmail
    }
  }
}

extension WordCategory {
  var settingsMapID: SettingsMapID {
    switch self {
    case .general: .yourWordsCategoryGeneral
    case .person: .yourWordsCategoryPerson
    case .brand: .yourWordsCategoryBrand
    case .acronym: .yourWordsCategoryAcronym
    case .domain: .yourWordsCategoryDomain
    }
  }
}

extension PolishRailProvider {
  /// The provider's entry in the AI Polish provider list. `LLMProvider.none` is the switched-off
  /// state, never a list entry (`PolishRailCatalog.all` does not contain it).
  var settingsMapID: SettingsMapID {
    switch provider {
    case .egOne: return .aiPolishProviderEgOne
    case .s1Mini: return .aiPolishProviderS1Mini
    case .appleIntelligence: return .aiPolishProviderAppleIntelligence
    case .ollama: return .aiPolishProviderOllama
    case .openAI: return .aiPolishProviderOpenAI
    case .gemini: return .aiPolishProviderGemini
    case .claude: return .aiPolishProviderClaude
    case .none:
      SettingsMap.wiringFault("the switched-off state is not a provider list entry")
      return .aiPolishProvider
    }
  }
}

extension PolishRailProvider {
  /// #4287: the provider's entry among the Summaries tab's engine choices. S1-mini is not a
  /// summary engine (founder 2026-10-31), and the switched-off state is not a choice.
  var meetingSummaryMapID: SettingsMapID {
    switch provider {
    case .appleIntelligence: return .meetingSummaryEngineAppleIntelligence
    case .egOne: return .meetingSummaryEngineEgOne
    case .ollama: return .meetingSummaryEngineOllama
    case .openAI: return .meetingSummaryEngineOpenAI
    case .gemini: return .meetingSummaryEngineGemini
    case .claude: return .meetingSummaryEngineClaude
    case .s1Mini, .none:
      SettingsMap.wiringFault("S1-mini and the off state are not summary engine choices")
      return .meetingSummaryEngine
    }
  }
}

enum SettingsMapChoiceIDs {
  /// The start-word editor's language options (`SpokenPunctuationStartWordEditor.languages`).
  /// Nil, and a wiring fault, for a language the map does not name yet (the map tests fail on it).
  static func startWordLanguage(_ code: String) -> SettingsMapID? {
    switch code {
    case "en": return .startWordLanguageEn
    case "de": return .startWordLanguageDe
    case "fr": return .startWordLanguageFr
    case "es": return .startWordLanguageEs
    case "it": return .startWordLanguageIt
    default:
      SettingsMap.wiringFault("start-word language \(code) has no Settings Map identity")
      return nil
    }
  }
}

// #4105: the Live words card's engines, in the order the cards show them (#4287 PR 2).
extension LivePreviewEngineChoice {
  var meetingLiveWordsMapID: SettingsMapID {
    switch self {
    case .apple: .meetingLiveWordsApple
    case .universal: .meetingLiveWordsUniversal
    }
  }

  var meetingLiveWordsTitle: SettingsMapTitle {
    switch self {
    case .apple: .verbatim(LivePreviewEngineCopy.appleTitle)
    case .universal: .resource(LivePreviewEngineCopy.universalTitleResource)
    }
  }
}

// #3973 C3: the Transcript engine card's engines (#4287 PR 2: Apple's Coming soon card is
// `MeetingTranscriptEngineCards.Item.appleComingSoon`).
extension MeetingEngineChoice {
  var transcriptEngineMapID: SettingsMapID {
    switch self {
    case .parakeet: .meetingTranscriptEngineParakeet
    case .whisper: .meetingTranscriptEngineWhisper
    }
  }

  var transcriptEngineTitle: SettingsMapTitle {
    switch self {
    case .parakeet: .resource(MeetingsCopy.engineParakeet)
    case .whisper: .resource(MeetingsCopy.engineWhisper)
    }
  }
}

// #4287 PR 2: a Transcript engine card's name in the Settings Map: the engines' own titles, and
// Apple by its product name.
extension MeetingTranscriptEngineCards.Item {
  var mapTitle: SettingsMapTitle {
    switch self {
    case .engine(let engine): engine.transcriptEngineTitle
    case .appleComingSoon: .verbatim(LivePreviewEngineCopy.appleTitle)
    }
  }
}
