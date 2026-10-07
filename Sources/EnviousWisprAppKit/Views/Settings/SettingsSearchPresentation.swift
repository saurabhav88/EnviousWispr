import Foundation

/// What a search result row says (#3482 plan §3.1, §3.3): the place's title in the interface
/// language and its breadcrumb (page › tab, plus the parent setting for a choice or action). Read
/// from the Settings Map at display time, so a row always says what the page says.
enum SettingsSearchPresentation {
  /// The row title. A place whose interface title is only known at run time uses a fixed context
  /// where its id supplies one truthfully, otherwise its reviewed label.
  static func title(of id: SettingsMapID) -> String {
    let node = SettingsMap.node(id)
    switch node.title {
    case .resource, .verbatim:
      return SettingsMapRef.id(id).title
    case .dynamic:
      return dynamicTitle(of: id)
    }
  }

  /// The places whose dynamic title has a fixed context or a label; a test requires every
  /// searchable dynamic-title place to be one of them.
  static func dynamicTitle(of id: SettingsMapID) -> String {
    switch id {
    case .startWordLanguageEn, .startWordLanguageDe, .startWordLanguageFr, .startWordLanguageEs,
      .startWordLanguageIt:
      let code = String(id.rawValue.split(separator: ".").last ?? "")
      return SettingsMapRef.dynamic(id, .startWordLanguage(code: code)).title
    case .apiKeyReveal:
      return SettingsMapRef.dynamic(.apiKeyReveal, .apiKeyReveal(revealed: false)).title
    case .lockedLanguage:
      return String(
        localized: "Dictation language",
        comment: "The language dictation is locked to: the language sheet's title and a Settings search result.")
    case .livePreviewLanguage:
      return String(localized: DictationSettingsCopy.Engine.changeLanguage)
    case .previewLanguagesInstall:
      return String(localized: LivePreviewSettingsCopy.packsInstallRowTitleResource)
    case .currentEngineSection: return String(localized: SettingsSearchCopy.Label.currentEngine)
    case .inputDeviceDevice: return String(localized: SettingsSearchCopy.Label.microphoneInList)
    case .inputSocketInput: return String(localized: SettingsSearchCopy.Label.inputs)
    case .recordingChimePreview: return String(localized: SettingsSearchCopy.Label.listenToSound)
    case .transcribeFileSteps: return String(localized: SettingsSearchCopy.Label.fileSteps)
    case .aiPolishProvider: return String(localized: SettingsSearchCopy.Label.provider)
    case .aiPolishProviderSection:
      return String(localized: SettingsSearchCopy.Label.providerSettings)
    case .localModelTestLive: return String(localized: SettingsSearchCopy.Label.testModel)
    case .appleIntelligenceStatus:
      return String(localized: SettingsSearchCopy.Label.appleIntelligenceStatus)
    case .ollamaDownloadModel: return String(localized: SettingsSearchCopy.Label.ollamaModel)
    case .apiKeyGetKeyLink: return String(localized: SettingsSearchCopy.Label.getAPIKey)
    case .appLanguageShipped: return String(localized: SettingsSearchCopy.Label.appLanguages)
    default:
      SettingsMap.wiringFault("Settings search: \(id.rawValue) has a dynamic title and no label")
      return ""
    }
  }

  /// "Dictation Settings › Engine", plus "› Input device" for a choice or action of that setting.
  static func breadcrumb(of id: SettingsMapID) -> String {
    var names: [String] = []
    var current = SettingsMap.node(id).parent
    var seen: Set<SettingsMapID> = [id]
    let node = SettingsMap.node(id)
    let namesParent = node.item == .choice || node.item == .action
    var isDirectParent = true
    while let parentID = current, seen.insert(parentID).inserted {
      let parent = SettingsMap.node(parentID)
      if parent.structure == .page || parent.structure == .tab
        || (isDirectParent && namesParent && parent.item != nil)
      {
        names.append(title(of: parentID))
      }
      isDirectParent = false
      current = parent.parent
    }
    return names.reversed().joined(separator: " › ")
  }
}
