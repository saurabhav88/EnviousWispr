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
  /// searchable dynamic-title place to be one of them. `language` nil reads the app's language;
  /// a code ("en", "de") reads that language's text, as the search index does for each of its
  /// interface languages (#3545).
  static func dynamicTitle(of id: SettingsMapID, language: String? = nil) -> String {
    switch id {
    case .startWordLanguageEn, .startWordLanguageDe, .startWordLanguageFr, .startWordLanguageEs,
      .startWordLanguageIt:
      let code = String(id.rawValue.split(separator: ".").last ?? "")
      guard let language else {
        return SettingsMapRef.dynamic(id, .startWordLanguage(code: code)).title
      }
      return Locale(identifier: language).localizedString(forLanguageCode: code)?
        .localizedCapitalized ?? code
    default:
      guard var resource = dynamicTitleResource(of: id) else {
        SettingsMap.wiringFault("Settings search: \(id.rawValue) has a dynamic title and no label")
        return ""
      }
      if let language { resource.locale = Locale(identifier: language) }
      return String(localized: resource)
    }
  }

  /// The reviewed label of a dynamic-title place other than a start-word language, nil when it
  /// has none. The one label table: search results and the title-only index both read it.
  static func dynamicTitleResource(of id: SettingsMapID) -> LocalizedStringResource? {
    switch id {
    case .apiKeyReveal: SettingsMapRef.showKeyTitle
    case .lockedLanguage: SettingsSearchCopy.Label.dictationLanguage
    case .livePreviewLanguage: DictationSettingsCopy.Engine.changeLanguage
    case .previewLanguagesInstall: LivePreviewSettingsCopy.packsInstallRowTitleResource
    case .currentEngineSection: SettingsSearchCopy.Label.currentEngine
    case .inputDeviceDevice: SettingsSearchCopy.Label.microphoneInList
    case .inputSocketInput: SettingsSearchCopy.Label.inputs
    case .recordingChimePreview: SettingsSearchCopy.Label.listenToSound
    case .transcribeFileSteps: SettingsSearchCopy.Label.fileSteps
    case .aiPolishProvider: SettingsSearchCopy.Label.provider
    case .aiPolishProviderSection: SettingsSearchCopy.Label.providerSettings
    case .localModelTestLive: SettingsSearchCopy.Label.testModel
    case .appleIntelligenceStatus: SettingsSearchCopy.Label.appleIntelligenceStatus
    case .ollamaDownloadModel: SettingsSearchCopy.Label.ollamaModel
    case .apiKeyGetKeyLink: SettingsSearchCopy.Label.getAPIKey
    case .appLanguageShipped: SettingsSearchCopy.Label.appLanguages
    default: nil
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
