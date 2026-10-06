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
    case .egOne: .aiPolishProviderEgOne
    case .s1Mini: .aiPolishProviderS1Mini
    case .appleIntelligence: .aiPolishProviderAppleIntelligence
    case .ollama: .aiPolishProviderOllama
    case .openAI: .aiPolishProviderOpenAI
    case .gemini: .aiPolishProviderGemini
    case .claude: .aiPolishProviderClaude
    case .none: preconditionFailure("the switched-off state is not a provider list entry")
    }
  }
}

enum SettingsMapChoiceIDs {
  /// The start-word editor's language options (`SpokenPunctuationStartWordEditor.languages`).
  static func startWordLanguage(_ code: String) -> SettingsMapID {
    switch code {
    case "en": .startWordLanguageEn
    case "de": .startWordLanguageDe
    case "fr": .startWordLanguageFr
    case "es": .startWordLanguageEs
    case "it": .startWordLanguageIt
    default: preconditionFailure("start-word language \(code) has no Settings Map identity")
    }
  }
}
