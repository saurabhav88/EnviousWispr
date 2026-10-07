import EnviousWisprCore
import Foundation
import os

/// The Settings Map (#3482 plan §3.6): every searchable place in the Settings window, its
/// structure and where an arrival lands. Titles come from the interface's own owners (see
/// SettingsMapTitle). Choices list their presentation collection's members; a coverage test
/// keeps the two in step.
enum SettingsMap {
  static let window = SettingsMapNode(
    id: .windowSettings, structure: .window, item: nil, title: .verbatim("EnviousWispr"), description: nil,
    parent: nil, destination: nil, dictionaryTab: nil, visibility: .always, target: nil, fallbacks: [])

  static let nodes: [SettingsMapNode] = [window] + literalNodes + choiceNodes

  private static let literalNodes: [SettingsMapNode] = [
    SettingsMapNode(
      id: .pageAiPolish, structure: .page, item: nil,
      title: .resource(SettingsPage.aiPolish.labelResource!),
      description: nil,
      parent: .windowSettings, destination: .aiPolish, dictionaryTab: nil,
      visibility: .always, target: nil, fallbacks: []),
    SettingsMapNode(
      id: .pageAppSettings, structure: .page, item: nil,
      title: .resource(SettingsPage.appSettings.labelResource!),
      description: nil,
      parent: .windowSettings, destination: .appSettings(.appearance), dictionaryTab: nil,
      visibility: .always, target: nil, fallbacks: []),
    SettingsMapNode(
      id: .pageDictation, structure: .page, item: nil,
      title: .resource(SettingsPage.dictation.labelResource!),
      description: nil,
      parent: .windowSettings, destination: .dictation(.engine), dictionaryTab: nil,
      visibility: .always, target: nil, fallbacks: []),
    SettingsMapNode(
      id: .pageDictionary, structure: .page, item: nil,
      title: .resource(SettingsPage.dictionary.labelResource!),
      description: nil,
      parent: .windowSettings, destination: .dictionary, dictionaryTab: nil,
      visibility: .always, target: nil, fallbacks: []),
    SettingsMapNode(
      id: .pageKeybinds, structure: .page, item: nil,
      title: .resource(SettingsPage.keybinds.labelResource!),
      description: nil,
      parent: .windowSettings, destination: .keybinds, dictionaryTab: nil,
      visibility: .always, target: nil, fallbacks: []),
    SettingsMapNode(
      id: .pageSnippets, structure: .page, item: nil,
      title: .resource(SettingsPage.snippets.labelResource!),
      description: nil,
      parent: .windowSettings, destination: .snippets, dictionaryTab: nil,
      visibility: .always, target: nil, fallbacks: []),
    SettingsMapNode(
      id: .pageTranscribeFile, structure: .page, item: nil,
      title: .resource(SettingsPage.transcribeFile.labelResource!),
      description: nil,
      parent: .windowSettings, destination: .transcribeFile, dictionaryTab: nil,
      visibility: .always, target: nil, fallbacks: []),
    SettingsMapNode(
      id: .sectionTranscriptionEngine, structure: .section, item: nil,
      title: .resource(DictationSettingsCopy.Engine.sectionHeading),
      description: nil,
      parent: .dictationTabEngine, destination: .dictation(.engine), dictionaryTab: nil,
      visibility: .always, target: nil, fallbacks: []),
    SettingsMapNode(
      id: .sectionEngineShared, structure: .section, item: nil,
      title: .resource(DictationSettingsCopy.Engine.sharedHeading),
      description: nil,
      parent: .dictationTabEngine, destination: .dictation(.engine), dictionaryTab: nil,
      visibility: .always, target: nil, fallbacks: []),
    SettingsMapNode(
      id: .sectionMicrophone, structure: .section, item: nil,
      title: .resource(DictationSettingsCopy.Microphone.sectionHeading),
      description: nil,
      parent: .dictationTabMicrophone, destination: .dictation(.microphone), dictionaryTab: nil,
      visibility: .always, target: nil, fallbacks: []),
    SettingsMapNode(
      id: .sectionLivePreview, structure: .section, item: nil,
      title: .resource(LivePreviewSettingsCopy.sectionHeaderResource),
      description: nil,
      parent: .dictationTabLivePreview, destination: .dictation(.livePreview), dictionaryTab: nil,
      visibility: .always, target: nil, fallbacks: []),
    SettingsMapNode(
      id: .sectionPreviewEngine, structure: .section, item: nil,
      title: .resource(LivePreviewEngineCopy.sectionHeaderResource),
      description: nil,
      parent: .dictationTabLivePreview, destination: .dictation(.livePreview), dictionaryTab: nil,
      visibility: .always, target: nil, fallbacks: []),
    SettingsMapNode(
      id: .sectionPill, structure: .section, item: nil,
      title: .resource(DictationTab.pill.label),
      description: nil,
      parent: .dictationTabPill, destination: .dictation(.pill), dictionaryTab: nil,
      visibility: .always, target: nil, fallbacks: []),
    SettingsMapNode(
      id: .sectionChimes, structure: .section, item: nil,
      title: .resource(DictationSettingsCopy.Chimes.sectionHeading),
      description: nil,
      parent: .dictationTabChimes, destination: .dictation(.chimes), dictionaryTab: nil,
      visibility: .always, target: nil, fallbacks: []),
    SettingsMapNode(
      id: .sectionClipboard, structure: .section, item: nil,
      title: .resource(DictationSettingsCopy.Clipboard.clipboardHeading),
      description: nil,
      parent: .dictationTabClipboard, destination: .dictation(.clipboard), dictionaryTab: nil,
      visibility: .always, target: nil, fallbacks: []),
    SettingsMapNode(
      id: .sectionQuickAddClipboard, structure: .section, item: nil,
      title: .resource(DictationSettingsCopy.Clipboard.quickAddHeading),
      description: nil,
      parent: .dictationTabClipboard, destination: .dictation(.clipboard), dictionaryTab: nil,
      visibility: .always, target: nil, fallbacks: []),
    SettingsMapNode(
      id: .sectionKeybindsRecording, structure: .section, item: nil,
      title: .resource(SettingsItemCopy.Keybinds.recordingSection),
      description: nil,
      parent: .pageKeybinds, destination: .keybinds, dictionaryTab: nil,
      visibility: .always, target: nil, fallbacks: []),
    SettingsMapNode(
      id: .sectionKeybindsShortcuts, structure: .section, item: nil,
      title: .resource(SettingsItemCopy.Keybinds.shortcutsSection),
      description: nil,
      parent: .pageKeybinds, destination: .keybinds, dictionaryTab: nil,
      visibility: .always, target: nil, fallbacks: []),
    SettingsMapNode(
      id: .sectionAiPolishModel, structure: .section, item: nil,
      title: .resource(SettingsItemCopy.AIPolish.modelSection),
      description: nil,
      parent: .pageAiPolish, destination: .aiPolish, dictionaryTab: nil,
      visibility: .aiPolishEnabled, target: nil, fallbacks: []),
    SettingsMapNode(
      id: .sectionDictionary, structure: .section, item: nil,
      title: .resource(SettingsShellCopy.Dictionary.heading),
      description: nil,
      parent: .pageDictionary, destination: .dictionary, dictionaryTab: nil,
      visibility: .always, target: nil, fallbacks: []),
    SettingsMapNode(
      id: .sectionAppearance, structure: .section, item: nil,
      title: .resource(SettingsItemCopy.AppSettings.appearanceSection),
      description: nil,
      parent: .appSettingsTabAppearance, destination: .appSettings(.appearance), dictionaryTab: nil,
      visibility: .always, target: nil, fallbacks: []),
    SettingsMapNode(
      id: .sectionPermissions, structure: .section, item: nil,
      title: .resource(SettingsItemCopy.AppSettings.permissionsSection),
      description: nil,
      parent: .appSettingsTabPermissions, destination: .appSettings(.permissions), dictionaryTab: nil,
      visibility: .always, target: nil, fallbacks: []),
    SettingsMapNode(
      id: .sectionPrivacy, structure: .section, item: nil,
      title: .resource(SettingsItemCopy.AppSettings.privacySection),
      description: nil,
      parent: .appSettingsTabPrivacy, destination: .appSettings(.privacy), dictionaryTab: nil,
      visibility: .always, target: nil, fallbacks: []),
    SettingsMapNode(
      id: .sectionAbout, structure: .section, item: nil,
      title: .resource(SettingsItemCopy.AppSettings.aboutSection),
      description: nil,
      parent: .appSettingsTabLicenses, destination: .appSettings(.licenses), dictionaryTab: nil,
      visibility: .always, target: nil, fallbacks: []),
    SettingsMapNode(
      id: .dictationTabEngine, structure: .tab, item: .feature,
      title: .resource(DictationTab.engine.label),
      description: nil,
      parent: .pageDictation, destination: .dictation(.engine), dictionaryTab: nil,
      visibility: .always, target: .dictationTabEngine, fallbacks: []),
    SettingsMapNode(
      id: .dictationTabMicrophone, structure: .tab, item: .feature,
      title: .resource(DictationTab.microphone.label),
      description: nil,
      parent: .pageDictation, destination: .dictation(.microphone), dictionaryTab: nil,
      visibility: .always, target: .dictationTabMicrophone, fallbacks: []),
    SettingsMapNode(
      id: .dictationTabLivePreview, structure: .tab, item: .feature,
      title: .resource(DictationTab.livePreview.label),
      description: nil,
      parent: .pageDictation, destination: .dictation(.livePreview), dictionaryTab: nil,
      visibility: .always, target: .dictationTabLivePreview, fallbacks: []),
    SettingsMapNode(
      id: .dictationTabPill, structure: .tab, item: .feature,
      title: .resource(DictationTab.pill.label),
      description: nil,
      parent: .pageDictation, destination: .dictation(.pill), dictionaryTab: nil,
      visibility: .always, target: .dictationTabPill, fallbacks: []),
    SettingsMapNode(
      id: .dictationTabChimes, structure: .tab, item: .feature,
      title: .resource(DictationTab.chimes.label),
      description: nil,
      parent: .pageDictation, destination: .dictation(.chimes), dictionaryTab: nil,
      visibility: .always, target: .dictationTabChimes, fallbacks: []),
    SettingsMapNode(
      id: .dictationTabClipboard, structure: .tab, item: .feature,
      title: .resource(DictationTab.clipboard.label),
      description: nil,
      parent: .pageDictation, destination: .dictation(.clipboard), dictionaryTab: nil,
      visibility: .always, target: .dictationTabClipboard, fallbacks: []),
    SettingsMapNode(
      id: .transcriptionEngine, structure: .item, item: .setting,
      title: .resource(DictationSettingsCopy.Engine.sectionHeading),
      description: nil,
      parent: .sectionTranscriptionEngine, destination: .dictation(.engine), dictionaryTab: nil,
      visibility: .always, target: .transcriptionEngine, fallbacks: []),
    SettingsMapNode(
      id: .transcriptionEngineChange, structure: .item, item: .action,
      title: .resource(SettingsItemCopy.Shared.change),
      description: nil,
      parent: .transcriptionEngine, destination: .dictation(.engine), dictionaryTab: nil,
      visibility: .always, target: .transcriptionEngine, fallbacks: []),
    SettingsMapNode(
      id: .transcriptionEngineKeepCurrent, structure: .item, item: .action,
      title: .resource(DictationSettingsCopy.Engine.keepCurrent),
      description: nil,
      parent: .transcriptionEngine, destination: .dictation(.engine), dictionaryTab: nil,
      visibility: .engineChoicesExpanded, target: .transcriptionEngine, fallbacks: [.transcriptionEngine]),
    SettingsMapNode(
      id: .transcriptionEngineRecheckFast, structure: .item, item: .action,
      title: .resource(EngineSummaryCopy.recheckFast),
      description: nil,
      parent: .transcriptionEngine, destination: .dictation(.engine), dictionaryTab: nil,
      visibility: .fastSelected, target: .transcriptionEngineRecheckFast, fallbacks: [.transcriptionEngine]),
    SettingsMapNode(
      id: .fastModelCancelDownload, structure: .item, item: .action,
      title: .resource(SettingsItemCopy.Engine.fastCancel),
      description: nil,
      parent: .transcriptionEngine, destination: .dictation(.engine), dictionaryTab: nil,
      visibility: .fastDeliveryAction, target: .fastModelCancelDownload, fallbacks: [.transcriptionEngine]),
    SettingsMapNode(
      id: .fastModelResume, structure: .item, item: .action,
      title: .resource(SettingsItemCopy.Engine.fastResume),
      description: nil,
      parent: .transcriptionEngine, destination: .dictation(.engine), dictionaryTab: nil,
      visibility: .fastDeliveryAction, target: .transcriptionEngine, fallbacks: [.transcriptionEngine]),
    SettingsMapNode(
      id: .fastModelTryAgain, structure: .item, item: .action,
      title: .resource(SettingsItemCopy.Engine.fastTryAgain),
      description: nil,
      parent: .transcriptionEngine, destination: .dictation(.engine), dictionaryTab: nil,
      visibility: .fastDeliveryAction, target: .transcriptionEngine, fallbacks: [.transcriptionEngine]),
    SettingsMapNode(
      id: .whisperModelSetUp, structure: .item, item: .action,
      title: .resource(DictationSettingsCopy.Engine.setUpModel),
      description: nil,
      parent: .transcriptionEngine, destination: .dictation(.engine), dictionaryTab: nil,
      visibility: .whisperSetupState, target: .whisperModelSetUp, fallbacks: [.transcriptionEngine]),
    SettingsMapNode(
      id: .whisperModelCancelDownload, structure: .item, item: .action,
      title: .resource(SettingsItemCopy.Engine.whisperCancel),
      description: nil,
      parent: .transcriptionEngine, destination: .dictation(.engine), dictionaryTab: nil,
      visibility: .whisperSetupState, target: .whisperModelCancelDownload, fallbacks: [.transcriptionEngine]),
    SettingsMapNode(
      id: .whisperModelResume, structure: .item, item: .action,
      title: .resource(SettingsItemCopy.Engine.whisperResume),
      description: nil,
      parent: .transcriptionEngine, destination: .dictation(.engine), dictionaryTab: nil,
      visibility: .whisperSetupState, target: .whisperModelResume, fallbacks: [.transcriptionEngine]),
    SettingsMapNode(
      id: .whisperModelRemove, structure: .item, item: .action,
      title: .resource(SettingsItemCopy.Engine.whisperRemove),
      description: nil,
      parent: .transcriptionEngine, destination: .dictation(.engine), dictionaryTab: nil,
      visibility: .whisperSetupState, target: .whisperModelRemove, fallbacks: [.transcriptionEngine]),
    SettingsMapNode(
      id: .whisperModelRecheck, structure: .item, item: .action,
      title: .resource(SettingsItemCopy.Engine.whisperRecheck),
      description: nil,
      parent: .transcriptionEngine, destination: .dictation(.engine), dictionaryTab: nil,
      visibility: .whisperSetupState, target: .whisperModelRecheck, fallbacks: [.transcriptionEngine]),
    SettingsMapNode(
      id: .whisperModelTryAgain, structure: .item, item: .action,
      title: .resource(SettingsItemCopy.Engine.whisperTryAgain),
      description: nil,
      parent: .transcriptionEngine, destination: .dictation(.engine), dictionaryTab: nil,
      visibility: .whisperSetupState, target: .whisperModelTryAgain, fallbacks: [.transcriptionEngine]),
    SettingsMapNode(
      id: .currentEngineSection, structure: .item, item: .feature,
      title: .dynamic(.currentEngineHeading),
      description: nil,
      parent: .dictationTabEngine, destination: .dictation(.engine), dictionaryTab: nil,
      visibility: .always, target: .currentEngineSection, fallbacks: []),
    SettingsMapNode(
      id: .autoDetectLanguage, structure: .item, item: .setting,
      title: .resource(DictationSettingsCopy.Engine.autoDetectTitle),
      description: .runtime,
      parent: .currentEngineSection, destination: .dictation(.engine), dictionaryTab: nil,
      visibility: .languageSectionAvailable, target: .autoDetectLanguage, fallbacks: [.transcriptionEngine]),
    SettingsMapNode(
      id: .autoDetectLanguageResetSuggestions, structure: .item, item: .action,
      title: .resource(SettingsItemCopy.Engine.resetSuggestions),
      description: nil,
      parent: .autoDetectLanguage, destination: .dictation(.engine), dictionaryTab: nil,
      visibility: .languageSectionAvailable, target: .autoDetectLanguageResetSuggestions, fallbacks: [.autoDetectLanguage, .transcriptionEngine]),
    SettingsMapNode(
      id: .lockedLanguage, structure: .item, item: .setting,
      title: .dynamic(.lockedLanguage),
      description: .resource(DictationSettingsCopy.Engine.lockedLanguageShort),
      parent: .currentEngineSection, destination: .dictation(.engine), dictionaryTab: nil,
      visibility: .languageLocked, target: .lockedLanguage, fallbacks: [.transcriptionEngine]),
    SettingsMapNode(
      id: .lockedLanguageChange, structure: .item, item: .action,
      title: .resource(SettingsItemCopy.Engine.lockedLanguageChange),
      description: nil,
      parent: .lockedLanguage, destination: .dictation(.engine), dictionaryTab: nil,
      visibility: .languageLocked, target: .lockedLanguageChange, fallbacks: [.lockedLanguage, .transcriptionEngine]),
    SettingsMapNode(
      id: .fasterTranscription, structure: .item, item: .setting,
      title: .resource(LiveTranscriptionCopy.toggleLabelResource),
      description: .runtime,
      parent: .currentEngineSection, destination: .dictation(.engine), dictionaryTab: nil,
      visibility: .always, target: .fasterTranscription, fallbacks: []),
    SettingsMapNode(
      id: .stopOnSilence, structure: .item, item: .setting,
      title: .resource(DictationSettingsCopy.Engine.stopOnSilenceTitle),
      description: .resource(DictationSettingsCopy.Engine.stopOnSilenceShort),
      parent: .sectionEngineShared, destination: .dictation(.engine), dictionaryTab: nil,
      visibility: .always, target: .stopOnSilence, fallbacks: []),
    SettingsMapNode(
      id: .pauseDuration, structure: .item, item: .setting,
      title: .resource(SettingsItemCopy.Engine.pauseDuration),
      description: .resource(DictationSettingsCopy.Engine.pauseShort),
      parent: .stopOnSilence, destination: .dictation(.engine), dictionaryTab: nil,
      visibility: .stopOnSilenceOn, target: .pauseDuration, fallbacks: [.stopOnSilence]),
    SettingsMapNode(
      id: .fillerRemoval, structure: .item, item: .setting,
      title: .resource(DictationSettingsCopy.Engine.fillerTitle),
      description: .resource(DictationSettingsCopy.Engine.fillerShort),
      parent: .sectionEngineShared, destination: .dictation(.engine), dictionaryTab: nil,
      visibility: .always, target: .fillerRemoval, fallbacks: []),
    SettingsMapNode(
      id: .spokenEmoji, structure: .item, item: .setting,
      title: .resource(DictationSettingsCopy.Engine.emojiTitle),
      description: .resource(DictationSettingsCopy.Engine.emojiShort),
      parent: .sectionEngineShared, destination: .dictation(.engine), dictionaryTab: nil,
      visibility: .always, target: .spokenEmoji, fallbacks: []),
    SettingsMapNode(
      id: .spokenPunctuation, structure: .item, item: .setting,
      title: .resource(SpokenPunctuationCopy.toggleLabelResource),
      description: .resource(DictationSettingsCopy.Engine.punctuationShort),
      parent: .sectionEngineShared, destination: .dictation(.engine), dictionaryTab: nil,
      visibility: .always, target: .spokenPunctuation, fallbacks: []),
    SettingsMapNode(
      id: .startWordLanguage, structure: .item, item: .setting,
      title: .resource(SpokenPunctuationCopy.startWordTitleResource),
      description: .resource(SpokenPunctuationCopy.startWordShortResource),
      parent: .spokenPunctuation, destination: .dictation(.engine), dictionaryTab: nil,
      visibility: .spokenPunctuationOn, target: .startWordLanguage, fallbacks: [.spokenPunctuation]),
    SettingsMapNode(
      id: .startWordField, structure: .item, item: .setting,
      title: .resource(SpokenPunctuationCopy.languagePickerLabelResource),
      description: nil,
      parent: .spokenPunctuation, destination: .dictation(.engine), dictionaryTab: nil,
      visibility: .spokenPunctuationOn, target: .startWordField, fallbacks: [.spokenPunctuation]),
    SettingsMapNode(
      id: .startWordSave, structure: .item, item: .action,
      title: .resource(SpokenPunctuationCopy.saveLabelResource),
      description: nil,
      parent: .startWordField, destination: .dictation(.engine), dictionaryTab: nil,
      visibility: .spokenPunctuationOn, target: .startWordSave, fallbacks: [.spokenPunctuation]),
    SettingsMapNode(
      id: .startWordReset, structure: .item, item: .action,
      title: .resource(SpokenPunctuationCopy.resetLabelResource),
      description: nil,
      parent: .startWordField, destination: .dictation(.engine), dictionaryTab: nil,
      visibility: .spokenPunctuationOn, target: .startWordReset, fallbacks: [.spokenPunctuation]),
    SettingsMapNode(
      id: .unloadModelAfter, structure: .item, item: .setting,
      title: .resource(DictationSettingsCopy.Engine.unloadTitle),
      description: .resource(DictationSettingsCopy.Engine.unloadShort),
      parent: .sectionEngineShared, destination: .dictation(.engine), dictionaryTab: nil,
      visibility: .always, target: .unloadModelAfter, fallbacks: []),
    SettingsMapNode(
      id: .inputDevice, structure: .item, item: .setting,
      title: .resource(DictationSettingsCopy.Microphone.inputDeviceTitle),
      description: .resource(DictationSettingsCopy.Microphone.inputDeviceShort),
      parent: .sectionMicrophone, destination: .dictation(.microphone), dictionaryTab: nil,
      visibility: .always, target: .inputDevice, fallbacks: []),
    SettingsMapNode(
      id: .inputDeviceAuto, structure: .item, item: .choice,
      title: .resource(SettingsItemCopy.Microphone.auto),
      description: .resource(SettingsItemCopy.Microphone.followsMacOS),
      parent: .inputDevice, destination: .dictation(.microphone), dictionaryTab: nil,
      visibility: .always, target: .inputDevice, fallbacks: []),
    SettingsMapNode(
      id: .inputDeviceDevice, structure: .item, item: .choice,
      title: .dynamic(.inputDeviceName),
      description: .runtime,
      parent: .inputDevice, destination: .dictation(.microphone), dictionaryTab: nil,
      visibility: .always, target: .inputDevice, fallbacks: []),
    SettingsMapNode(
      id: .inputSocket, structure: .item, item: .setting,
      title: .resource(InputSocketCopy.labelResource),
      description: .resource(DictationSettingsCopy.Microphone.socketShort),
      parent: .inputDevice, destination: .dictation(.microphone), dictionaryTab: nil,
      visibility: .multiInputDevice, target: .inputSocket, fallbacks: [.inputDevice]),
    SettingsMapNode(
      id: .inputSocketInput, structure: .item, item: .choice,
      title: .dynamic(.inputSocketOption),
      description: .runtime,
      parent: .inputSocket, destination: .dictation(.microphone), dictionaryTab: nil,
      visibility: .multiInputDevice, target: .inputSocket, fallbacks: [.inputDevice]),
    SettingsMapNode(
      id: .mediaDuringDictation, structure: .item, item: .setting,
      title: .resource(DictationSettingsCopy.Microphone.mediaTitle),
      description: .resource(DictationSettingsCopy.Microphone.mediaShort),
      parent: .sectionMicrophone, destination: .dictation(.microphone), dictionaryTab: nil,
      visibility: .always, target: .mediaDuringDictation, fallbacks: []),
    SettingsMapNode(
      id: .micReadiness, structure: .item, item: .setting,
      title: .resource(DictationSettingsCopy.Microphone.readinessTitle),
      description: .resource(DictationSettingsCopy.Microphone.readinessShort),
      parent: .sectionMicrophone, destination: .dictation(.microphone), dictionaryTab: nil,
      visibility: .always, target: .micReadiness, fallbacks: []),
    SettingsMapNode(
      id: .bluetoothGuide, structure: .item, item: .feature,
      title: .resource(BluetoothTipsCopy.settingsHeaderResource),
      description: .resource(DictationSettingsCopy.Microphone.bluetoothShort),
      parent: .sectionMicrophone, destination: .dictation(.microphone), dictionaryTab: nil,
      visibility: .always, target: .bluetoothGuide, fallbacks: []),
    SettingsMapNode(
      id: .bluetoothGuideLearnMore, structure: .item, item: .action,
      title: .resource(SettingsItemCopy.Microphone.bluetoothLearnMore),
      description: nil,
      parent: .bluetoothGuide, destination: .dictation(.microphone), dictionaryTab: nil,
      visibility: .always, target: .bluetoothGuideLearnMore, fallbacks: []),
    SettingsMapNode(
      id: .livePreview, structure: .item, item: .setting,
      title: .resource(LivePreviewSettingsCopy.toggleLabelResource),
      description: .resource(DictationSettingsCopy.Preview.toggleShort),
      parent: .sectionLivePreview, destination: .dictation(.livePreview), dictionaryTab: nil,
      visibility: .always, target: .livePreview, fallbacks: []),
    SettingsMapNode(
      id: .livePreviewLanguage, structure: .item, item: .action,
      title: .dynamic(.previewLanguage),
      description: .resource(DictationSettingsCopy.Preview.languageShort),
      parent: .livePreview, destination: .dictation(.livePreview), dictionaryTab: nil,
      visibility: .previewLanguageKnown, target: .livePreviewLanguage, fallbacks: [.livePreview]),
    SettingsMapNode(
      id: .livePreviewBrowseDownloads, structure: .item, item: .action,
      title: .resource(LivePreviewSettingsCopy.browseDownloadsButtonResource),
      description: nil,
      parent: .livePreview, destination: .dictation(.livePreview), dictionaryTab: nil,
      visibility: .previewLanguageMissing, target: .livePreviewBrowseDownloads, fallbacks: [.livePreview]),
    SettingsMapNode(
      id: .previewEngine, structure: .item, item: .setting,
      title: .resource(LivePreviewEngineCopy.sectionHeaderResource),
      description: .resource(DictationSettingsCopy.Preview.engineShort),
      parent: .sectionPreviewEngine, destination: .dictation(.livePreview), dictionaryTab: nil,
      visibility: .always, target: .previewEngine, fallbacks: []),
    SettingsMapNode(
      id: .previewEngineChange, structure: .item, item: .action,
      title: .resource(SettingsItemCopy.Shared.change),
      description: nil,
      parent: .previewEngine, destination: .dictation(.livePreview), dictionaryTab: nil,
      visibility: .always, target: .previewEngine, fallbacks: []),
    SettingsMapNode(
      id: .previewEngineCompare, structure: .item, item: .action,
      title: .resource(LivePreviewEngineCopy.learnMoreLabelResource),
      description: nil,
      parent: .previewEngine, destination: .dictation(.livePreview), dictionaryTab: nil,
      visibility: .always, target: .previewEngineCompare, fallbacks: []),
    SettingsMapNode(
      id: .previewEngineKeepCurrent, structure: .item, item: .action,
      title: .resource(DictationSettingsCopy.Preview.keepCurrent),
      description: nil,
      parent: .previewEngine, destination: .dictation(.livePreview), dictionaryTab: nil,
      visibility: .previewChoicesExpanded, target: .previewEngine, fallbacks: []),
    SettingsMapNode(
      id: .previewEngineUniversalDownload, structure: .item, item: .action,
      title: .resource(SettingsItemCopy.LivePreview.universalDownload),
      description: nil,
      parent: .previewEngineUniversal, destination: .dictation(.livePreview), dictionaryTab: nil,
      visibility: .universalSetupState, target: .previewEngine, fallbacks: []),
    SettingsMapNode(
      id: .previewEngineUniversalCancel, structure: .item, item: .action,
      title: .resource(SettingsItemCopy.LivePreview.universalCancel),
      description: nil,
      parent: .previewEngineUniversal, destination: .dictation(.livePreview), dictionaryTab: nil,
      visibility: .universalSetupState, target: .previewEngine, fallbacks: []),
    SettingsMapNode(
      id: .previewEngineUniversalResume, structure: .item, item: .action,
      title: .resource(SettingsItemCopy.LivePreview.universalResume),
      description: nil,
      parent: .previewEngineUniversal, destination: .dictation(.livePreview), dictionaryTab: nil,
      visibility: .universalSetupState, target: .previewEngine, fallbacks: []),
    SettingsMapNode(
      id: .previewEngineUniversalRetry, structure: .item, item: .action,
      title: .resource(SettingsItemCopy.LivePreview.universalRetry),
      description: nil,
      parent: .previewEngineUniversal, destination: .dictation(.livePreview), dictionaryTab: nil,
      visibility: .universalSetupState, target: .previewEngine, fallbacks: []),
    SettingsMapNode(
      id: .previewEngineUniversalRemove, structure: .item, item: .action,
      title: .resource(SettingsItemCopy.LivePreview.universalRemove),
      description: nil,
      parent: .previewEngineUniversal, destination: .dictation(.livePreview), dictionaryTab: nil,
      visibility: .universalSetupState, target: .previewEngine, fallbacks: []),
    SettingsMapNode(
      id: .previewLanguages, structure: .item, item: .feature,
      title: .resource(LivePreviewSettingsCopy.packsHeaderResource),
      description: .runtime,
      parent: .sectionPreviewEngine, destination: .dictation(.livePreview), dictionaryTab: nil,
      visibility: .appleLanguagePacks, target: .previewLanguages, fallbacks: [.previewEngine]),
    SettingsMapNode(
      id: .previewLanguagesInstall, structure: .item, item: .action,
      title: .dynamic(.previewLanguagesInstall),
      description: .resource(DictationSettingsCopy.Preview.installShort),
      parent: .previewLanguages, destination: .dictation(.livePreview), dictionaryTab: nil,
      visibility: .appleLanguagePacks, target: .previewLanguages, fallbacks: [.previewEngine]),
    SettingsMapNode(
      id: .pillPosition, structure: .item, item: .setting,
      title: .resource(DictationSettingsCopy.Pill.positionTitle),
      description: .resource(DictationSettingsCopy.Pill.positionShort),
      parent: .sectionPill, destination: .dictation(.pill), dictionaryTab: nil,
      visibility: .always, target: .pillPosition, fallbacks: []),
    SettingsMapNode(
      id: .pillStyle, structure: .item, item: .setting,
      title: .resource(DictationSettingsCopy.Pill.styleTitle),
      description: .resource(DictationSettingsCopy.Pill.styleShort),
      parent: .sectionPill, destination: .dictation(.pill), dictionaryTab: nil,
      visibility: .always, target: .pillStyle, fallbacks: []),
    SettingsMapNode(
      id: .pillStyleConfigureLivePreview, structure: .item, item: .action,
      title: .resource(SettingsItemCopy.Pill.configureLivePreview),
      description: nil,
      parent: .pillStyle, destination: .dictation(.pill), dictionaryTab: nil,
      visibility: .pillShowsWords, target: .pillStyleConfigureLivePreview, fallbacks: [.pillStyle]),
    SettingsMapNode(
      id: .recordingChimes, structure: .item, item: .setting,
      title: .resource(DictationSettingsCopy.Chimes.toggleTitle),
      description: .resource(DictationSettingsCopy.Chimes.toggleShort),
      parent: .sectionChimes, destination: .dictation(.chimes), dictionaryTab: nil,
      visibility: .always, target: .recordingChimes, fallbacks: []),
    SettingsMapNode(
      id: .recordingChime, structure: .item, item: .setting,
      title: .resource(DictationSettingsCopy.Chimes.sectionHeading),
      description: .resource(DictationSettingsCopy.Chimes.previewExplanation),
      parent: .sectionChimes, destination: .dictation(.chimes), dictionaryTab: nil,
      visibility: .always, target: .recordingChime, fallbacks: []),
    SettingsMapNode(
      id: .recordingChimePreview, structure: .item, item: .action,
      title: .dynamic(.chimePreview),
      description: nil,
      parent: .recordingChime, destination: .dictation(.chimes), dictionaryTab: nil,
      visibility: .always, target: .recordingChime, fallbacks: []),
    SettingsMapNode(
      id: .autoCopyToClipboard, structure: .item, item: .setting,
      title: .resource(DictationSettingsCopy.Clipboard.autoCopyTitle),
      description: .resource(DictationSettingsCopy.Clipboard.autoCopyShort),
      parent: .sectionClipboard, destination: .dictation(.clipboard), dictionaryTab: nil,
      visibility: .always, target: .autoCopyToClipboard, fallbacks: []),
    SettingsMapNode(
      id: .restoreClipboard, structure: .item, item: .setting,
      title: .resource(DictationSettingsCopy.Clipboard.restoreTitle),
      description: .resource(DictationSettingsCopy.Clipboard.restoreShort),
      parent: .sectionClipboard, destination: .dictation(.clipboard), dictionaryTab: nil,
      visibility: .always, target: .restoreClipboard, fallbacks: []),
    SettingsMapNode(
      id: .smartInsertion, structure: .item, item: .setting,
      title: .resource(DictationSettingsCopy.Clipboard.smartInsertionTitle),
      description: .resource(DictationSettingsCopy.Clipboard.smartInsertionShort),
      parent: .sectionClipboard, destination: .dictation(.clipboard), dictionaryTab: nil,
      visibility: .always, target: .smartInsertion, fallbacks: []),
    SettingsMapNode(
      id: .quickAddClipboardFallback, structure: .item, item: .setting,
      title: .resource(DictationSettingsCopy.Clipboard.quickAddTitle),
      description: .resource(DictationSettingsCopy.Clipboard.quickAddShort),
      parent: .sectionQuickAddClipboard, destination: .dictation(.clipboard), dictionaryTab: nil,
      visibility: .always, target: .quickAddClipboardFallback, fallbacks: []),
    SettingsMapNode(
      id: .recordingMode, structure: .item, item: .setting,
      title: .resource(KeybindsSettingsCopy.modeTitle),
      description: .resource(KeybindsSettingsCopy.modeShort),
      parent: .sectionKeybindsRecording, destination: .keybinds, dictionaryTab: nil,
      visibility: .always, target: .recordingMode, fallbacks: []),
    SettingsMapNode(
      id: .recordKeybind, structure: .item, item: .setting,
      title: .resource(KeybindsSettingsCopy.recordTitle),
      description: .resource(KeybindsSettingsCopy.recordShort),
      parent: .sectionKeybindsRecording, destination: .keybinds, dictionaryTab: nil,
      visibility: .always, target: .recordKeybind, fallbacks: []),
    SettingsMapNode(
      id: .cancelKeybind, structure: .item, item: .setting,
      title: .resource(KeybindsSettingsCopy.cancelTitle),
      description: .resource(KeybindsSettingsCopy.cancelShort),
      parent: .sectionKeybindsRecording, destination: .keybinds, dictionaryTab: nil,
      visibility: .always, target: .cancelKeybind, fallbacks: []),
    SettingsMapNode(
      id: .escapeRecovery, structure: .item, item: .setting,
      title: .resource(KeybindsSettingsCopy.recoveryTitle),
      description: .resource(KeybindsSettingsCopy.recoveryShort),
      parent: .sectionKeybindsRecording, destination: .keybinds, dictionaryTab: nil,
      visibility: .always, target: .escapeRecovery, fallbacks: []),
    SettingsMapNode(
      id: .quickAddKeybind, structure: .item, item: .setting,
      title: .resource(KeybindsSettingsCopy.addTitle),
      description: .resource(KeybindsSettingsCopy.addShort),
      parent: .sectionKeybindsShortcuts, destination: .keybinds, dictionaryTab: nil,
      visibility: .always, target: .quickAddKeybind, fallbacks: []),
    SettingsMapNode(
      id: .pasteLastKeybind, structure: .item, item: .setting,
      title: .resource(KeybindsSettingsCopy.pasteTitle),
      description: .resource(KeybindsSettingsCopy.pasteShort),
      parent: .sectionKeybindsShortcuts, destination: .keybinds, dictionaryTab: nil,
      visibility: .always, target: .pasteLastKeybind, fallbacks: []),
    SettingsMapNode(
      id: .copyLastKeybind, structure: .item, item: .setting,
      title: .resource(KeybindsSettingsCopy.copyTitle),
      description: .resource(KeybindsSettingsCopy.copyShort),
      parent: .sectionKeybindsShortcuts, destination: .keybinds, dictionaryTab: nil,
      visibility: .always, target: .copyLastKeybind, fallbacks: []),
    SettingsMapNode(
      id: .keybindResetToDefault, structure: .item, item: .action,
      title: .resource(SettingsItemCopy.Keybinds.resetToDefault),
      description: nil,
      parent: .sectionKeybindsRecording, destination: .keybinds, dictionaryTab: nil,
      visibility: .always, target: .recordKeybind, fallbacks: []),
    SettingsMapNode(
      id: .transcribeFileSteps, structure: .item, item: .feature,
      title: .dynamic(.transcribeFileStep),
      description: nil,
      parent: .pageTranscribeFile, destination: .transcribeFile, dictionaryTab: nil,
      visibility: .always, target: .transcribeFileSteps, fallbacks: []),
    SettingsMapNode(
      id: .enableAIPolish, structure: .item, item: .setting,
      title: .resource(SettingsItemCopy.AIPolish.enable),
      description: .resource(SettingsItemCopy.AIPolish.enableShort),
      parent: .pageAiPolish, destination: .aiPolish, dictionaryTab: nil,
      visibility: .always, target: .enableAIPolish, fallbacks: []),
    SettingsMapNode(
      id: .aiPolishProvider, structure: .item, item: .setting,
      title: .dynamic(.providerName),
      description: nil,
      parent: .sectionAiPolishModel, destination: .aiPolish, dictionaryTab: nil,
      visibility: .aiPolishEnabled, target: .aiPolishProvider, fallbacks: [.enableAIPolish]),
    SettingsMapNode(
      id: .aiPolishProviderSection, structure: .item, item: .feature,
      title: .dynamic(.providerSection),
      description: nil,
      parent: .aiPolishProvider, destination: .aiPolish, dictionaryTab: nil,
      visibility: .providerSelected, target: .aiPolishProviderSection, fallbacks: [.aiPolishProvider, .enableAIPolish]),
    SettingsMapNode(
      id: .aiPolishWhyUseEgOne, structure: .item, item: .feature,
      title: .resource(SettingsItemCopy.AIPolish.whyEGOne),
      description: nil,
      parent: .aiPolishProviderEgOne, destination: .aiPolish, dictionaryTab: nil,
      visibility: .providerSelected, target: .aiPolishWhyUseEgOne, fallbacks: [.aiPolishProvider, .enableAIPolish]),
    SettingsMapNode(
      id: .aiPolishWhyUseS1Mini, structure: .item, item: .feature,
      title: .resource(SettingsItemCopy.AIPolish.whyS1Mini),
      description: nil,
      parent: .aiPolishProviderS1Mini, destination: .aiPolish, dictionaryTab: nil,
      visibility: .providerSelected, target: .aiPolishWhyUseS1Mini, fallbacks: [.aiPolishProvider, .enableAIPolish]),
    SettingsMapNode(
      id: .aiPolishWhyUseAppleIntelligence, structure: .item, item: .feature,
      title: .resource(SettingsItemCopy.AIPolish.whyAppleIntelligence),
      description: nil,
      parent: .aiPolishProviderAppleIntelligence, destination: .aiPolish, dictionaryTab: nil,
      visibility: .providerSelected, target: .aiPolishWhyUseAppleIntelligence, fallbacks: [.aiPolishProvider, .enableAIPolish]),
    SettingsMapNode(
      id: .aiPolishWhyUseOllama, structure: .item, item: .feature,
      title: .resource(SettingsItemCopy.AIPolish.whyOllama),
      description: nil,
      parent: .aiPolishProviderOllama, destination: .aiPolish, dictionaryTab: nil,
      visibility: .providerSelected, target: .aiPolishWhyUseOllama, fallbacks: [.aiPolishProvider, .enableAIPolish]),
    SettingsMapNode(
      id: .aiPolishWhyUseOpenAI, structure: .item, item: .feature,
      title: .resource(SettingsItemCopy.AIPolish.whyOpenAI),
      description: nil,
      parent: .aiPolishProviderOpenAI, destination: .aiPolish, dictionaryTab: nil,
      visibility: .providerSelected, target: .aiPolishWhyUseOpenAI, fallbacks: [.aiPolishProvider, .enableAIPolish]),
    SettingsMapNode(
      id: .aiPolishWhyUseGemini, structure: .item, item: .feature,
      title: .resource(SettingsItemCopy.AIPolish.whyGemini),
      description: nil,
      parent: .aiPolishProviderGemini, destination: .aiPolish, dictionaryTab: nil,
      visibility: .providerSelected, target: .aiPolishWhyUseGemini, fallbacks: [.aiPolishProvider, .enableAIPolish]),
    SettingsMapNode(
      id: .aiPolishWhyUseClaude, structure: .item, item: .feature,
      title: .resource(SettingsItemCopy.AIPolish.whyClaude),
      description: nil,
      parent: .aiPolishProviderClaude, destination: .aiPolish, dictionaryTab: nil,
      visibility: .providerSelected, target: .aiPolishWhyUseClaude, fallbacks: [.aiPolishProvider, .enableAIPolish]),
    SettingsMapNode(
      id: .aiPolishLinkAboutAppleIntelligence, structure: .item, item: .action,
      title: .resource(SettingsItemCopy.AIPolish.aboutAppleIntelligence),
      description: nil,
      parent: .aiPolishWhyUseAppleIntelligence, destination: .aiPolish, dictionaryTab: nil,
      visibility: .providerSelected, target: .aiPolishWhyUseAppleIntelligence, fallbacks: [.aiPolishProvider, .enableAIPolish]),
    SettingsMapNode(
      id: .aiPolishLinkOllamaLibrary, structure: .item, item: .action,
      title: .resource(SettingsItemCopy.AIPolish.ollamaLibrary),
      description: nil,
      parent: .aiPolishWhyUseOllama, destination: .aiPolish, dictionaryTab: nil,
      visibility: .providerSelected, target: .aiPolishWhyUseOllama, fallbacks: [.aiPolishProvider, .enableAIPolish]),
    SettingsMapNode(
      id: .aiPolishLinkOpenAIRateLimits, structure: .item, item: .action,
      title: .resource(SettingsItemCopy.AIPolish.openAIRateLimits),
      description: nil,
      parent: .aiPolishWhyUseOpenAI, destination: .aiPolish, dictionaryTab: nil,
      visibility: .providerSelected, target: .aiPolishWhyUseOpenAI, fallbacks: [.aiPolishProvider, .enableAIPolish]),
    SettingsMapNode(
      id: .aiPolishLinkGeminiRateLimits, structure: .item, item: .action,
      title: .resource(SettingsItemCopy.AIPolish.geminiRateLimits),
      description: nil,
      parent: .aiPolishWhyUseGemini, destination: .aiPolish, dictionaryTab: nil,
      visibility: .providerSelected, target: .aiPolishWhyUseGemini, fallbacks: [.aiPolishProvider, .enableAIPolish]),
    SettingsMapNode(
      id: .aiPolishLinkClaudeRateLimits, structure: .item, item: .action,
      title: .resource(SettingsItemCopy.AIPolish.claudeRateLimits),
      description: nil,
      parent: .aiPolishWhyUseClaude, destination: .aiPolish, dictionaryTab: nil,
      visibility: .providerSelected, target: .aiPolishWhyUseClaude, fallbacks: [.aiPolishProvider, .enableAIPolish]),
    SettingsMapNode(
      id: .localModelDownload, structure: .item, item: .action,
      title: .resource(SettingsItemCopy.AIPolish.localModelDownload),
      description: .runtime,
      parent: .aiPolishProviderSection, destination: .aiPolish, dictionaryTab: nil,
      visibility: .providerSetupState, target: .localModelDownload, fallbacks: [.aiPolishProvider, .enableAIPolish]),
    SettingsMapNode(
      id: .localModelCancel, structure: .item, item: .action,
      title: .resource(EGOneRowPresentation.cancelAction),
      description: .runtime,
      parent: .aiPolishProviderSection, destination: .aiPolish, dictionaryTab: nil,
      visibility: .providerSetupState, target: .localModelCancel, fallbacks: [.aiPolishProvider, .enableAIPolish]),
    SettingsMapNode(
      id: .localModelResume, structure: .item, item: .action,
      title: .resource(EGOneRowPresentation.resumeAction),
      description: nil,
      parent: .aiPolishProviderSection, destination: .aiPolish, dictionaryTab: nil,
      visibility: .providerSetupState, target: .localModelResume, fallbacks: [.aiPolishProvider, .enableAIPolish]),
    SettingsMapNode(
      id: .localModelResumeUpgrade, structure: .item, item: .action,
      title: .resource(EGOneRowPresentation.resumeUpgradeAction),
      description: nil,
      parent: .aiPolishProviderSection, destination: .aiPolish, dictionaryTab: nil,
      visibility: .providerSetupState, target: .aiPolishProvider, fallbacks: [.aiPolishProvider, .enableAIPolish]),
    SettingsMapNode(
      id: .localModelFinishUpgrade, structure: .item, item: .action,
      title: .resource(EGOneRowPresentation.finishUpgradeAction),
      description: nil,
      parent: .aiPolishProviderSection, destination: .aiPolish, dictionaryTab: nil,
      visibility: .providerSetupState, target: .aiPolishProvider, fallbacks: [.aiPolishProvider, .enableAIPolish]),
    SettingsMapNode(
      id: .localModelTryAgain, structure: .item, item: .action,
      title: .resource(EGOneRowPresentation.tryAgainAction),
      description: nil,
      parent: .aiPolishProviderSection, destination: .aiPolish, dictionaryTab: nil,
      visibility: .providerSetupState, target: .localModelTryAgain, fallbacks: [.aiPolishProvider, .enableAIPolish]),
    SettingsMapNode(
      id: .localModelTestLive, structure: .item, item: .action,
      title: .dynamic(.localModelTest),
      description: nil,
      parent: .aiPolishProviderSection, destination: .aiPolish, dictionaryTab: nil,
      visibility: .providerSetupState, target: .localModelTestLive, fallbacks: [.aiPolishProvider, .enableAIPolish]),
    SettingsMapNode(
      id: .s1Tone, structure: .item, item: .setting,
      title: .resource(S1ControlCopy.stylingLabelResource),
      description: .resource(S1ControlCopy.stylingShortResource),
      parent: .aiPolishProviderSection, destination: .aiPolish, dictionaryTab: nil,
      visibility: .providerSelected, target: .s1Tone, fallbacks: [.aiPolishProvider, .enableAIPolish]),
    SettingsMapNode(
      id: .s1Structure, structure: .item, item: .setting,
      title: .resource(S1ControlCopy.structureLabelResource),
      description: .resource(S1ControlCopy.structureShortResource),
      parent: .aiPolishProviderSection, destination: .aiPolish, dictionaryTab: nil,
      visibility: .providerSelected, target: .s1Structure, fallbacks: [.aiPolishProvider, .enableAIPolish]),
    SettingsMapNode(
      id: .s1Context, structure: .item, item: .setting,
      title: .resource(S1ControlCopy.contextLabelResource),
      description: .resource(S1ControlCopy.contextShortResource),
      parent: .aiPolishProviderSection, destination: .aiPolish, dictionaryTab: nil,
      visibility: .providerSelected, target: .s1Context, fallbacks: [.aiPolishProvider, .enableAIPolish]),
    SettingsMapNode(
      id: .appleIntelligenceStatus, structure: .item, item: .feature,
      title: .dynamic(.appleIntelligenceStatus),
      description: .runtime,
      parent: .aiPolishProviderAppleIntelligence, destination: .aiPolish, dictionaryTab: nil,
      visibility: .providerSetupState, target: .appleIntelligenceStatus, fallbacks: [.aiPolishProvider, .enableAIPolish]),
    SettingsMapNode(
      id: .appleIntelligenceRecheck, structure: .item, item: .action,
      title: .resource(SettingsItemCopy.AIPolish.appleRecheck),
      description: nil,
      parent: .appleIntelligenceStatus, destination: .aiPolish, dictionaryTab: nil,
      visibility: .providerSetupState, target: .appleIntelligenceRecheck, fallbacks: [.aiPolishProvider, .enableAIPolish]),
    SettingsMapNode(
      id: .ollamaDownloadOllama, structure: .item, item: .action,
      title: .resource(SettingsItemCopy.AIPolish.downloadOllama),
      description: nil,
      parent: .aiPolishProviderOllama, destination: .aiPolish, dictionaryTab: nil,
      visibility: .providerSetupState, target: .ollamaDownloadOllama, fallbacks: [.aiPolishProvider, .enableAIPolish]),
    SettingsMapNode(
      id: .ollamaStart, structure: .item, item: .action,
      title: .resource(SettingsItemCopy.AIPolish.startOllama),
      description: nil,
      parent: .aiPolishProviderOllama, destination: .aiPolish, dictionaryTab: nil,
      visibility: .providerSetupState, target: .ollamaStart, fallbacks: [.aiPolishProvider, .enableAIPolish]),
    SettingsMapNode(
      id: .ollamaDownloadModel, structure: .item, item: .action,
      title: .dynamic(.ollamaModelDownload),
      description: nil,
      parent: .aiPolishProviderOllama, destination: .aiPolish, dictionaryTab: nil,
      visibility: .providerSetupState, target: .ollamaDownloadModel, fallbacks: [.aiPolishProvider, .enableAIPolish]),
    SettingsMapNode(
      id: .ollamaCancelPull, structure: .item, item: .action,
      title: .resource(SettingsItemCopy.AIPolish.ollamaCancel),
      description: nil,
      parent: .aiPolishProviderOllama, destination: .aiPolish, dictionaryTab: nil,
      visibility: .providerSetupState, target: .ollamaCancelPull, fallbacks: [.aiPolishProvider, .enableAIPolish]),
    SettingsMapNode(
      id: .ollamaServer, structure: .item, item: .feature,
      title: .resource(SettingsItemCopy.AIPolish.ollamaServer),
      description: .runtime,
      parent: .aiPolishProviderOllama, destination: .aiPolish, dictionaryTab: nil,
      visibility: .providerSetupState, target: .ollamaServer, fallbacks: [.aiPolishProvider, .enableAIPolish]),
    SettingsMapNode(
      id: .ollamaRecheck, structure: .item, item: .action,
      title: .resource(SettingsItemCopy.AIPolish.ollamaRecheck),
      description: nil,
      parent: .aiPolishProviderOllama, destination: .aiPolish, dictionaryTab: nil,
      visibility: .providerSetupState, target: .ollamaRecheck, fallbacks: [.aiPolishProvider, .enableAIPolish]),
    SettingsMapNode(
      id: .ollamaTryAgain, structure: .item, item: .action,
      title: .resource(SettingsItemCopy.AIPolish.ollamaTryAgain),
      description: nil,
      parent: .aiPolishProviderOllama, destination: .aiPolish, dictionaryTab: nil,
      visibility: .providerSetupState, target: .ollamaTryAgain, fallbacks: [.aiPolishProvider, .enableAIPolish]),
    SettingsMapNode(
      id: .ollamaBrowseModels, structure: .item, item: .action,
      title: .resource(SettingsItemCopy.AIPolish.ollamaBrowseModels),
      description: nil,
      parent: .aiPolishProviderOllama, destination: .aiPolish, dictionaryTab: nil,
      visibility: .providerSetupState, target: .ollamaBrowseModels, fallbacks: [.aiPolishProvider, .enableAIPolish]),
    SettingsMapNode(
      id: .ollamaPrepareModel, structure: .item, item: .action,
      title: .resource(SettingsItemCopy.AIPolish.ollamaPrepareModel),
      description: nil,
      parent: .polishModel, destination: .aiPolish, dictionaryTab: nil,
      visibility: .providerSetupState, target: .ollamaPrepareModel, fallbacks: [.aiPolishProvider, .enableAIPolish]),
    SettingsMapNode(
      id: .apiKeyOpenAI, structure: .item, item: .setting,
      title: .resource(SettingsItemCopy.AIPolish.openAIKey),
      description: .resource(SettingsItemCopy.AIPolish.openAIKeyShort),
      parent: .aiPolishProviderSection, destination: .aiPolish, dictionaryTab: nil,
      visibility: .apiKeyProvider, target: .apiKeyOpenAI, fallbacks: [.aiPolishProvider, .enableAIPolish]),
    SettingsMapNode(
      id: .apiKeyGemini, structure: .item, item: .setting,
      title: .resource(SettingsItemCopy.AIPolish.geminiKey),
      description: .resource(SettingsItemCopy.AIPolish.geminiKeyShort),
      parent: .aiPolishProviderSection, destination: .aiPolish, dictionaryTab: nil,
      visibility: .apiKeyProvider, target: .apiKeyGemini, fallbacks: [.aiPolishProvider, .enableAIPolish]),
    SettingsMapNode(
      id: .apiKeyClaude, structure: .item, item: .setting,
      title: .resource(SettingsItemCopy.AIPolish.claudeKey),
      description: .resource(SettingsItemCopy.AIPolish.claudeKeyShort),
      parent: .aiPolishProviderSection, destination: .aiPolish, dictionaryTab: nil,
      visibility: .apiKeyProvider, target: .apiKeyClaude, fallbacks: [.aiPolishProvider, .enableAIPolish]),
    SettingsMapNode(
      id: .apiKeySave, structure: .item, item: .action,
      title: .resource(SettingsItemCopy.AIPolish.keySave),
      description: nil,
      parent: .aiPolishProviderSection, destination: .aiPolish, dictionaryTab: nil,
      visibility: .apiKeyProvider, target: .apiKeySave, fallbacks: [.aiPolishProvider, .enableAIPolish]),
    SettingsMapNode(
      id: .apiKeyClear, structure: .item, item: .action,
      title: .resource(SettingsItemCopy.AIPolish.keyClear),
      description: nil,
      parent: .aiPolishProviderSection, destination: .aiPolish, dictionaryTab: nil,
      visibility: .apiKeySaved, target: .apiKeyClear, fallbacks: [.aiPolishProvider, .enableAIPolish]),
    SettingsMapNode(
      id: .apiKeyReveal, structure: .item, item: .action,
      title: .dynamic(.apiKeyReveal),
      description: nil,
      parent: .aiPolishProviderSection, destination: .aiPolish, dictionaryTab: nil,
      visibility: .apiKeyDraftNonempty, target: .apiKeyReveal, fallbacks: [.aiPolishProvider, .enableAIPolish]),
    SettingsMapNode(
      id: .apiKeyGetKeyLink, structure: .item, item: .action,
      title: .dynamic(.apiKeyLink),
      description: nil,
      parent: .aiPolishProviderSection, destination: .aiPolish, dictionaryTab: nil,
      visibility: .apiKeyProvider, target: .apiKeyGetKeyLink, fallbacks: [.aiPolishProvider, .enableAIPolish]),
    SettingsMapNode(
      id: .polishModel, structure: .item, item: .setting,
      title: .resource(SettingsItemCopy.AIPolish.model),
      description: .runtime,
      parent: .aiPolishProviderSection, destination: .aiPolish, dictionaryTab: nil,
      visibility: .providerSelected, target: .polishModel, fallbacks: [.aiPolishProvider, .enableAIPolish]),
    SettingsMapNode(
      id: .polishModelRefresh, structure: .item, item: .action,
      title: .resource(SettingsItemCopy.AIPolish.refreshModels),
      description: nil,
      parent: .polishModel, destination: .aiPolish, dictionaryTab: nil,
      visibility: .providerSelected, target: .polishModelRefresh, fallbacks: [.aiPolishProvider, .enableAIPolish]),
    SettingsMapNode(
      id: .enableDictionary, structure: .item, item: .setting,
      title: .resource(SettingsShellCopy.Dictionary.enableTitle),
      description: .resource(SettingsShellCopy.Dictionary.enableShort),
      parent: .pageDictionary, destination: .dictionary, dictionaryTab: nil,
      visibility: .always, target: .enableDictionary, fallbacks: []),
    SettingsMapNode(
      id: .dictionaryTabYourWords, structure: .tab, item: .feature,
      title: .resource(DictionaryTab.yourWords.labelResource),
      description: .resource(DictionaryTab.yourWords.taglineResource),
      parent: .pageDictionary, destination: .dictionary, dictionaryTab: .yourWords,
      visibility: .always, target: .dictionaryTabYourWords, fallbacks: []),
    SettingsMapNode(
      id: .dictionaryTabVocabularyPacks, structure: .tab, item: .feature,
      title: .resource(DictionaryTab.vocabularyPacks.labelResource),
      description: .resource(DictionaryTab.vocabularyPacks.taglineResource),
      parent: .pageDictionary, destination: .dictionary, dictionaryTab: .vocabularyPacks,
      visibility: .always, target: .dictionaryTabVocabularyPacks, fallbacks: []),
    SettingsMapNode(
      id: .dictionaryTabLearnFrom, structure: .tab, item: .feature,
      title: .resource(DictionaryTab.learnFrom.labelResource),
      description: .resource(DictionaryTab.learnFrom.taglineResource),
      parent: .pageDictionary, destination: .dictionary, dictionaryTab: .learnFrom,
      visibility: .always, target: .dictionaryTabLearnFrom, fallbacks: []),
    SettingsMapNode(
      id: .dictionaryTabQuickAdd, structure: .tab, item: .feature,
      title: .resource(DictionaryTab.quickAdd.labelResource),
      description: .resource(DictionaryTab.quickAdd.taglineResource),
      parent: .pageDictionary, destination: .dictionary, dictionaryTab: .quickAdd,
      visibility: .always, target: .dictionaryTabQuickAdd, fallbacks: []),
    SettingsMapNode(
      id: .yourWordsAdd, structure: .item, item: .action,
      title: .resource(SettingsItemCopy.Dictionary.addWord),
      description: nil,
      parent: .dictionaryTabYourWords, destination: .dictionary, dictionaryTab: .yourWords,
      visibility: .always, target: .yourWordsAdd, fallbacks: []),
    SettingsMapNode(
      id: .yourWordsImport, structure: .item, item: .action,
      title: .resource(SettingsItemCopy.Dictionary.importWords),
      description: nil,
      parent: .dictionaryTabYourWords, destination: .dictionary, dictionaryTab: .yourWords,
      visibility: .always, target: .yourWordsImport, fallbacks: []),
    SettingsMapNode(
      id: .yourWordsExport, structure: .item, item: .action,
      title: .resource(SettingsItemCopy.Dictionary.exportWords),
      description: nil,
      parent: .dictionaryTabYourWords, destination: .dictionary, dictionaryTab: .yourWords,
      visibility: .always, target: .yourWordsExport, fallbacks: []),
    SettingsMapNode(
      id: .yourWordsSearch, structure: .item, item: .setting,
      title: .resource(SettingsItemCopy.Dictionary.searchWords),
      description: nil,
      parent: .dictionaryTabYourWords, destination: .dictionary, dictionaryTab: .yourWords,
      visibility: .always, target: .yourWordsSearch, fallbacks: []),
    SettingsMapNode(
      id: .yourWordsClearSearch, structure: .item, item: .action,
      title: .resource(SettingsItemCopy.Dictionary.clearSearch),
      description: nil,
      parent: .yourWordsSearch, destination: .dictionary, dictionaryTab: .yourWords,
      visibility: .searchHasQuery, target: .yourWordsClearSearch, fallbacks: [.yourWordsSearch]),
    SettingsMapNode(
      id: .yourWordsCategoryFilter, structure: .item, item: .setting,
      title: .resource(SettingsItemCopy.Dictionary.allCategories),
      description: nil,
      parent: .dictionaryTabYourWords, destination: .dictionary, dictionaryTab: .yourWords,
      visibility: .always, target: .yourWordsCategoryFilter, fallbacks: []),
    SettingsMapNode(
      id: .yourWordsMassEdit, structure: .item, item: .action,
      title: .resource(SettingsItemCopy.Dictionary.massEdit),
      description: nil,
      parent: .dictionaryTabYourWords, destination: .dictionary, dictionaryTab: .yourWords,
      visibility: .wordsListed, target: .yourWordsMassEdit, fallbacks: [.yourWordsSearch]),
    SettingsMapNode(
      id: .learnFrom, structure: .item, item: .feature,
      title: .resource(SettingsItemCopy.Dictionary.learnFromPanel),
      description: .resource(SettingsItemCopy.Dictionary.learnFromShort),
      parent: .dictionaryTabLearnFrom, destination: .dictionary, dictionaryTab: .learnFrom,
      visibility: .always, target: .learnFrom, fallbacks: []),
    SettingsMapNode(
      id: .selfLearningDictionary, structure: .item, item: .setting,
      title: .resource(LearnFromEditsSettingsPresentation.rowTitleResource),
      description: .resource(LearnFromEditsSettingsPresentation.rowCopyResource),
      parent: .dictionaryTabLearnFrom, destination: .dictionary, dictionaryTab: .learnFrom,
      visibility: .always, target: .selfLearningDictionary, fallbacks: []),
    SettingsMapNode(
      id: .selfLearningDictionaryLearnMore, structure: .item, item: .action,
      title: .resource(LearnFromEditsSettingsPresentation.learnMoreLabelResource),
      description: nil,
      parent: .selfLearningDictionary, destination: .dictionary, dictionaryTab: .learnFrom,
      visibility: .always, target: .selfLearningDictionaryLearnMore, fallbacks: []),
    SettingsMapNode(
      id: .importContacts, structure: .item, item: .feature,
      title: .resource(SettingsItemCopy.Dictionary.importContacts),
      description: .resource(SettingsItemCopy.Dictionary.importContactsShort),
      parent: .dictionaryTabLearnFrom, destination: .dictionary, dictionaryTab: .learnFrom,
      visibility: .always, target: .importContacts, fallbacks: []),
    SettingsMapNode(
      id: .contactsSyncOnLaunch, structure: .item, item: .setting,
      title: .resource(SettingsItemCopy.Dictionary.syncOnLaunch),
      description: .resource(SettingsItemCopy.Dictionary.syncOnLaunchShort),
      parent: .importContacts, destination: .dictionary, dictionaryTab: .learnFrom,
      visibility: .always, target: .contactsSyncOnLaunch, fallbacks: []),
    SettingsMapNode(
      id: .quickAddStep1, structure: .item, item: .feature,
      title: .resource(SettingsItemCopy.Dictionary.quickAddStep1),
      description: .resource(SettingsItemCopy.Dictionary.quickAddStep1Body),
      parent: .dictionaryTabQuickAdd, destination: .dictionary, dictionaryTab: .quickAdd,
      visibility: .always, target: .quickAddStep1, fallbacks: []),
    SettingsMapNode(
      id: .quickAddStep2, structure: .item, item: .feature,
      title: .resource(SettingsItemCopy.Dictionary.quickAddStep2),
      description: .runtime,
      parent: .dictionaryTabQuickAdd, destination: .dictionary, dictionaryTab: .quickAdd,
      visibility: .always, target: .quickAddStep2, fallbacks: []),
    SettingsMapNode(
      id: .quickAddStep3, structure: .item, item: .feature,
      title: .resource(SettingsItemCopy.Dictionary.quickAddStep3),
      description: .resource(SettingsItemCopy.Dictionary.quickAddStep3Body),
      parent: .dictionaryTabQuickAdd, destination: .dictionary, dictionaryTab: .quickAdd,
      visibility: .always, target: .quickAddStep3, fallbacks: []),
    SettingsMapNode(
      id: .quickAddShortcut, structure: .item, item: .action,
      title: .resource(SettingsItemCopy.Dictionary.quickAddShortcut),
      description: .runtime,
      parent: .dictionaryTabQuickAdd, destination: .dictionary, dictionaryTab: .quickAdd,
      visibility: .always, target: .quickAddShortcut, fallbacks: []),
    SettingsMapNode(
      id: .quickAddMenuBar, structure: .item, item: .feature,
      title: .resource(SettingsItemCopy.Dictionary.quickAddMenuBar),
      description: .resource(SettingsItemCopy.Dictionary.quickAddMenuBarBody),
      parent: .dictionaryTabQuickAdd, destination: .dictionary, dictionaryTab: .quickAdd,
      visibility: .always, target: .quickAddMenuBar, fallbacks: []),
    SettingsMapNode(
      id: .snippets, structure: .item, item: .feature,
      title: .resource(SnippetsSettingsCopy.headline),
      description: .resource(SnippetsSettingsCopy.body),
      parent: .pageSnippets, destination: .snippets, dictionaryTab: nil,
      visibility: .always, target: .snippets, fallbacks: []),
    SettingsMapNode(
      id: .snippetKeyword, structure: .item, item: .setting,
      title: .resource(SettingsItemCopy.Snippets.keyword),
      description: .resource(SnippetsSettingsCopy.keywordShort),
      parent: .pageSnippets, destination: .snippets, dictionaryTab: nil,
      visibility: .always, target: .snippetKeyword, fallbacks: []),
    SettingsMapNode(
      id: .yourSnippets, structure: .item, item: .feature,
      title: .resource(SettingsItemCopy.Snippets.yourSnippets),
      description: .runtime,
      parent: .pageSnippets, destination: .snippets, dictionaryTab: nil,
      visibility: .always, target: .yourSnippets, fallbacks: []),
    SettingsMapNode(
      id: .snippetsSearch, structure: .item, item: .setting,
      title: .resource(SettingsItemCopy.Snippets.search),
      description: nil,
      parent: .yourSnippets, destination: .snippets, dictionaryTab: nil,
      visibility: .snippetsListed, target: .snippetsSearch, fallbacks: [.yourSnippets]),
    SettingsMapNode(
      id: .snippetsImport, structure: .item, item: .action,
      title: .resource(SettingsItemCopy.Snippets.importSnippets),
      description: nil,
      parent: .yourSnippets, destination: .snippets, dictionaryTab: nil,
      visibility: .always, target: .snippetsImport, fallbacks: []),
    SettingsMapNode(
      id: .snippetsExport, structure: .item, item: .action,
      title: .resource(SettingsItemCopy.Snippets.exportSnippets),
      description: nil,
      parent: .yourSnippets, destination: .snippets, dictionaryTab: nil,
      visibility: .always, target: .snippetsExport, fallbacks: []),
    SettingsMapNode(
      id: .snippetsAdd, structure: .item, item: .action,
      title: .resource(SettingsItemCopy.Snippets.add),
      description: nil,
      parent: .yourSnippets, destination: .snippets, dictionaryTab: nil,
      visibility: .always, target: .snippetsAdd, fallbacks: []),
    SettingsMapNode(
      id: .snippetsAddFirst, structure: .item, item: .action,
      title: .resource(SettingsItemCopy.Snippets.addFirst),
      description: nil,
      parent: .yourSnippets, destination: .snippets, dictionaryTab: nil,
      visibility: .snippetsEmpty, target: .snippetsAddFirst, fallbacks: [.snippetsAdd]),
    SettingsMapNode(
      id: .snippetsClearSearch, structure: .item, item: .action,
      title: .resource(SettingsItemCopy.Snippets.clearSearch),
      description: nil,
      parent: .snippetsSearch, destination: .snippets, dictionaryTab: nil,
      visibility: .searchHasQuery, target: .snippetsClearSearch, fallbacks: [.snippetsSearch, .yourSnippets]),
    SettingsMapNode(
      id: .appSettingsTabAppearance, structure: .tab, item: .feature,
      title: .resource(AppSettingsTab.appearance.label),
      description: nil,
      parent: .pageAppSettings, destination: .appSettings(.appearance), dictionaryTab: nil,
      visibility: .always, target: .appSettingsTabAppearance, fallbacks: []),
    SettingsMapNode(
      id: .appSettingsTabPermissions, structure: .tab, item: .feature,
      title: .resource(AppSettingsTab.permissions.label),
      description: nil,
      parent: .pageAppSettings, destination: .appSettings(.permissions), dictionaryTab: nil,
      visibility: .always, target: .appSettingsTabPermissions, fallbacks: []),
    SettingsMapNode(
      id: .appSettingsTabPrivacy, structure: .tab, item: .feature,
      title: .resource(AppSettingsTab.privacy.label),
      description: nil,
      parent: .pageAppSettings, destination: .appSettings(.privacy), dictionaryTab: nil,
      visibility: .always, target: .appSettingsTabPrivacy, fallbacks: []),
    SettingsMapNode(
      id: .appSettingsTabLicenses, structure: .tab, item: .feature,
      title: .resource(AppSettingsTab.licenses.label),
      description: nil,
      parent: .pageAppSettings, destination: .appSettings(.licenses), dictionaryTab: nil,
      visibility: .always, target: .appSettingsTabLicenses, fallbacks: []),
    SettingsMapNode(
      id: .theme, structure: .item, item: .setting,
      title: .resource(SettingsItemCopy.AppSettings.theme),
      description: .resource(SettingsItemCopy.AppSettings.themeShort),
      parent: .sectionAppearance, destination: .appSettings(.appearance), dictionaryTab: nil,
      visibility: .always, target: .theme, fallbacks: []),
    SettingsMapNode(
      id: .appLanguage, structure: .item, item: .setting,
      title: .resource(SettingsItemCopy.AppSettings.language),
      description: .resource(SettingsItemCopy.AppSettings.languageShort),
      parent: .sectionAppearance, destination: .appSettings(.appearance), dictionaryTab: nil,
      visibility: .always, target: .appLanguage, fallbacks: []),
    SettingsMapNode(
      id: .appLanguageSystemDefault, structure: .item, item: .choice,
      title: .resource(SettingsItemCopy.AppSettings.systemDefault),
      description: nil,
      parent: .appLanguage, destination: .appSettings(.appearance), dictionaryTab: nil,
      visibility: .always, target: .appLanguage, fallbacks: []),
    SettingsMapNode(
      id: .appLanguageShipped, structure: .item, item: .choice,
      title: .dynamic(.appLanguageName),
      description: nil,
      parent: .appLanguage, destination: .appSettings(.appearance), dictionaryTab: nil,
      visibility: .always, target: .appLanguage, fallbacks: []),
    SettingsMapNode(
      id: .appLanguageRelaunch, structure: .item, item: .action,
      title: .resource(SettingsItemCopy.AppSettings.relaunch),
      description: nil,
      parent: .appLanguage, destination: .appSettings(.appearance), dictionaryTab: nil,
      visibility: .relaunchNeeded, target: .appLanguageRelaunch, fallbacks: [.appLanguage]),
    SettingsMapNode(
      id: .showInDock, structure: .item, item: .setting,
      title: .resource(SettingsItemCopy.AppSettings.showInDock),
      description: .resource(SettingsItemCopy.AppSettings.dockShort),
      parent: .sectionAppearance, destination: .appSettings(.appearance), dictionaryTab: nil,
      visibility: .always, target: .showInDock, fallbacks: []),
    SettingsMapNode(
      id: .updateAlertInMenuBar, structure: .item, item: .setting,
      title: .resource(SettingsItemCopy.AppSettings.updateAlert),
      description: .resource(SettingsItemCopy.AppSettings.updateAlertShort),
      parent: .sectionAppearance, destination: .appSettings(.appearance), dictionaryTab: nil,
      visibility: .always, target: .updateAlertInMenuBar, fallbacks: []),
    SettingsMapNode(
      id: .permissionMicrophone, structure: .item, item: .feature,
      title: .resource(SettingsItemCopy.AppSettings.microphonePermission),
      description: .resource(SettingsItemCopy.AppSettings.microphoneShort),
      parent: .sectionPermissions, destination: .appSettings(.permissions), dictionaryTab: nil,
      visibility: .always, target: .permissionMicrophone, fallbacks: []),
    SettingsMapNode(
      id: .permissionMicrophoneRequest, structure: .item, item: .action,
      title: .resource(SettingsItemCopy.AppSettings.requestAccess),
      description: nil,
      parent: .permissionMicrophone, destination: .appSettings(.permissions), dictionaryTab: nil,
      visibility: .permissionState, target: .permissionMicrophone, fallbacks: []),
    SettingsMapNode(
      id: .permissionAccessibility, structure: .item, item: .feature,
      title: .resource(SettingsItemCopy.AppSettings.accessibilityPermission),
      description: .resource(SettingsItemCopy.AppSettings.accessibilityShort),
      parent: .sectionPermissions, destination: .appSettings(.permissions), dictionaryTab: nil,
      visibility: .always, target: .permissionAccessibility, fallbacks: []),
    SettingsMapNode(
      id: .permissionAccessibilityOpenSettings, structure: .item, item: .action,
      title: .resource(SettingsItemCopy.AppSettings.openSystemSettings),
      description: nil,
      parent: .permissionAccessibility, destination: .appSettings(.permissions), dictionaryTab: nil,
      visibility: .permissionState, target: .permissionAccessibility, fallbacks: []),
    SettingsMapNode(
      id: .shareUsageMetrics, structure: .item, item: .setting,
      title: .resource(PrivacySettingsCopy.metricsLabelResource),
      description: .resource(PrivacySettingsCopy.metricsShortResource),
      parent: .sectionPrivacy, destination: .appSettings(.privacy), dictionaryTab: nil,
      visibility: .always, target: .shareUsageMetrics, fallbacks: []),
    SettingsMapNode(
      id: .sendCrashReports, structure: .item, item: .setting,
      title: .resource(PrivacySettingsCopy.crashLabelResource),
      description: .resource(PrivacySettingsCopy.crashShortResource),
      parent: .sectionPrivacy, destination: .appSettings(.privacy), dictionaryTab: nil,
      visibility: .always, target: .sendCrashReports, fallbacks: []),
    SettingsMapNode(
      id: .sendCrashReportsRestart, structure: .item, item: .action,
      title: .resource(PrivacySettingsCopy.restartActionResource),
      description: nil,
      parent: .sendCrashReports, destination: .appSettings(.privacy), dictionaryTab: nil,
      visibility: .crashReportsChanged, target: .sendCrashReportsRestart, fallbacks: [.sendCrashReports]),
    SettingsMapNode(
      id: .whatWeCollect, structure: .item, item: .feature,
      title: .resource(PrivacySettingsCopy.collectTitleResource),
      description: .resource(PrivacySettingsCopy.collectShortResource),
      parent: .sectionPrivacy, destination: .appSettings(.privacy), dictionaryTab: nil,
      visibility: .always, target: .whatWeCollect, fallbacks: []),
    SettingsMapNode(
      id: .whatWeCollectSeeDetails, structure: .item, item: .action,
      title: .resource(PrivacySettingsCopy.seeDetailsLabelResource),
      description: nil,
      parent: .whatWeCollect, destination: .appSettings(.privacy), dictionaryTab: nil,
      visibility: .always, target: .whatWeCollectSeeDetails, fallbacks: []),
    SettingsMapNode(
      id: .licenseGpl, structure: .item, item: .feature,
      title: .resource(SettingsItemCopy.AppSettings.gplLicense),
      description: .resource(SettingsItemCopy.AppSettings.gplShort),
      parent: .sectionAbout, destination: .appSettings(.licenses), dictionaryTab: nil,
      visibility: .always, target: .licenseGpl, fallbacks: []),
    SettingsMapNode(
      id: .licenseGplView, structure: .item, item: .action,
      title: .resource(SettingsItemCopy.AppSettings.viewLicense),
      description: nil,
      parent: .licenseGpl, destination: .appSettings(.licenses), dictionaryTab: nil,
      visibility: .always, target: .licenseGplView, fallbacks: []),
    SettingsMapNode(
      id: .licenseNotices, structure: .item, item: .feature,
      title: .resource(SettingsItemCopy.AppSettings.thirdPartyNotices),
      description: .resource(SettingsItemCopy.AppSettings.noticesShort),
      parent: .sectionAbout, destination: .appSettings(.licenses), dictionaryTab: nil,
      visibility: .always, target: .licenseNotices, fallbacks: []),
    SettingsMapNode(
      id: .licenseNoticesView, structure: .item, item: .action,
      title: .resource(SettingsItemCopy.AppSettings.viewNotices),
      description: nil,
      parent: .licenseNotices, destination: .appSettings(.licenses), dictionaryTab: nil,
      visibility: .always, target: .licenseNoticesView, fallbacks: []),
  ]

  /// Each picker's choices, mapped from the collection the picker itself iterates.
  private static let choiceNodes: [SettingsMapNode] =
    choices(
      of: .transcriptionEngine, destination: .dictation(.engine), dictionaryTab: nil,
      visibility: .engineChoicesExpanded, fallbacks: [.transcriptionEngine],
      EngineChoicePresentation.choices.map { ($0.mapID, .resource($0.title), .resource($0.tagline)) })
    + choices(
      of: .startWordLanguage, destination: .dictation(.engine), dictionaryTab: nil,
      visibility: .spokenPunctuationOn, fallbacks: [.spokenPunctuation],
      SpokenPunctuationStartWordEditor.languages.compactMap { code in
        SettingsMapChoiceIDs.startWordLanguage(code).map { ($0, .dynamic(.startWordLanguage), .runtime) }
      })
    + choices(
      of: .unloadModelAfter, destination: .dictation(.engine), dictionaryTab: nil,
      visibility: .always, fallbacks: [],
      ModelUnloadPolicy.allCases.map { ($0.settingsMapID, .resource($0.displayNameResource), nil) })
    + choices(
      of: .mediaDuringDictation, destination: .dictation(.microphone), dictionaryTab: nil,
      visibility: .always, fallbacks: [],
      SettingsChoicePresentation.mediaDuringDictation.map { ($0.mapID, .resource($0.label), nil) })
    + choices(
      of: .micReadiness, destination: .dictation(.microphone), dictionaryTab: nil,
      visibility: .always, fallbacks: [],
      SettingsChoicePresentation.micReadiness.map { ($0.mapID, .resource($0.label), nil) })
    + choices(
      of: .previewEngine, destination: .dictation(.livePreview), dictionaryTab: nil,
      visibility: .previewChoicesExpanded, fallbacks: [],
      LivePreviewSettingsView.engineChoices.map {
        (
          LivePreviewSettingsView.mapID(for: $0), LivePreviewSettingsView.mapTitle(for: $0),
          .resource(LivePreviewSettingsView.mapDescription(for: $0)))
      })
    + choices(
      of: .pillPosition, destination: .dictation(.pill), dictionaryTab: nil,
      visibility: .always, fallbacks: [],
      SettingsChoicePresentation.pillPosition.map { ($0.mapID, .resource($0.label), nil) })
    + choices(
      of: .pillStyle, destination: .dictation(.pill), dictionaryTab: nil,
      visibility: .always, fallbacks: [],
      RecordingPillAppearancePanel.displayOrder.map {
        (
          $0.settingsMapID, .resource($0.displayNameResource),
          .resource(DictationSettingsCopy.Pill.shortDescription(for: $0)))
      })
    + choices(
      of: .recordingChime, destination: .dictation(.chimes), dictionaryTab: nil,
      visibility: .always, fallbacks: [],
      RecordingSoundPairing.allCases.map {
        (
          RecordingChimeCard.mapID(for: $0), .resource(displayNameResource(for: $0)),
          .resource(pairingDescriptionResource(for: $0)))
      })
    + choices(
      of: .recordingMode, destination: .keybinds, dictionaryTab: nil,
      visibility: .always, fallbacks: [],
      SettingsChoicePresentation.recordingMode.map { ($0.mapID, .resource($0.label), nil) })
    + choices(
      of: .aiPolishProvider, destination: .aiPolish, dictionaryTab: nil,
      visibility: .aiPolishEnabled, fallbacks: [.aiPolishProvider, .enableAIPolish],
      PolishRailGroup.allCases.flatMap { PolishRailCatalog.providers(in: $0) }.map {
        ($0.settingsMapID, .verbatim($0.name), .resource($0.taglineResource))
      })
    + choices(
      of: .s1Tone, destination: .aiPolish, dictionaryTab: nil,
      visibility: .providerSelected, fallbacks: [.aiPolishProvider, .enableAIPolish],
      S1Styling.allCases.map { ($0.settingsMapID, .resource(S1ControlCopy.labelResource(for: $0)), nil) })
    + choices(
      of: .s1Structure, destination: .aiPolish, dictionaryTab: nil,
      visibility: .providerSelected, fallbacks: [.aiPolishProvider, .enableAIPolish],
      S1Structure.allCases.map { ($0.settingsMapID, .resource(S1ControlCopy.labelResource(for: $0)), nil) })
    + choices(
      of: .s1Context, destination: .aiPolish, dictionaryTab: nil,
      visibility: .providerSelected, fallbacks: [.aiPolishProvider, .enableAIPolish],
      S1Context.allCases.map { ($0.settingsMapID, .resource(S1ControlCopy.labelResource(for: $0)), nil) })
    + choices(
      of: .yourWordsCategoryFilter, destination: .dictionary, dictionaryTab: .yourWords,
      visibility: .always, fallbacks: [],
      [(.yourWordsCategoryAll, .resource(SettingsItemCopy.Dictionary.allCategories), nil)]
        + WordCategory.allCases.map { ($0.settingsMapID, .resource($0.displayNameResource), nil) }
        + [(.yourWordsCategoryAutoLearned, .resource(CustomTermProvenanceCopy.filterPillResource), nil)])
    + choices(
      of: .theme, destination: .appSettings(.appearance), dictionaryTab: nil,
      visibility: .always, fallbacks: [],
      ThemeChoicePresentation.choices.map { ($0.mapID, .resource($0.label), nil) })

  private static func choices(
    of parent: SettingsMapID, destination: SettingsDestination, dictionaryTab: DictionaryTab?,
    visibility: SettingsMapVisibility, fallbacks: [SettingsMapID],
    _ members: [(SettingsMapID, SettingsMapTitle, SettingsMapDescription?)]
  ) -> [SettingsMapNode] {
    members.map { id, title, description in
      SettingsMapNode(
        id: id, structure: .item, item: .choice, title: title, description: description,
        parent: parent,
        destination: destination, dictionaryTab: dictionaryTab, visibility: visibility,
        target: parent, fallbacks: fallbacks)
    }
  }

  /// Every node by id. A duplicate id is a wiring fault (the map tests fail on it); the first
  /// node wins.
  static let byID: [SettingsMapID: SettingsMapNode] = Dictionary(
    nodes.map { ($0.id, $0) },
    uniquingKeysWith: { first, _ in
      wiringFault("Settings Map has two nodes \(first.id.rawValue)")
      return first
    })

  static func node(_ id: SettingsMapID) -> SettingsMapNode {
    guard let node = byID[id] else {
      wiringFault("Settings Map has no node \(id.rawValue)")
      return SettingsMapNode(
        id: id, structure: .item, item: nil, title: .verbatim(""), description: nil, parent: nil,
        destination: nil, dictionaryTab: nil, visibility: .always, target: nil, fallbacks: [])
    }
    return node
  }

  /// A Settings Map wiring mistake: a missing or duplicate node, or a name asked for with the
  /// wrong kind of reference. It stops a DEBUG build and every Debug test that reaches it. In a
  /// Release build (the PR gate's test run) it is recorded, and every rendered Settings state
  /// fails on a recorded fault. A shipped app logs it and shows a plain fallback, never closing
  /// the Settings window over a name (adversarial review 2026-10-07, after the AI Polish
  /// key-link crash).
  static func wiringFault(_ message: @autoclosure () -> String) {
    let text = message()
    settingsMapLog.fault("\(text, privacy: .public)")
    recordedFaults.withLock { $0.append(text) }
    assertionFailure(text)
  }

  /// Wiring faults since the last call, cleared by reading. A shipped app records one only after
  /// a mistake the tests exist to catch, so the list stays empty.
  static func takeRecordedFaults() -> [String] {
    recordedFaults.withLock { faults in
      defer { faults.removeAll() }
      return faults
    }
  }

  private static let recordedFaults = OSAllocatedUnfairLock<[String]>(initialState: [])
}

private let settingsMapLog = Logger(subsystem: "com.enviouswispr.app", category: "SettingsMap")
