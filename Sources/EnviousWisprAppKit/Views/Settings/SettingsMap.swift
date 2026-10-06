import EnviousWisprCore
import Foundation

/// The Settings Map (#3482 plan §3.6): every searchable place in the Settings window, its
/// structure and where an arrival lands. Titles come from the interface's own owners (see
/// SettingsMapTitle). Choices list their presentation collection's members; a coverage test
/// keeps the two in step.
enum SettingsMap {
  static let window = SettingsMapNode(
    id: .windowSettings, structure: .window, item: nil, title: .verbatim("EnviousWispr"),
    parent: nil, destination: nil, dictionaryTab: nil, visibility: .always, target: nil, fallbacks: [])

  static let nodes: [SettingsMapNode] = [window] + [
    SettingsMapNode(
      id: .pageAiPolish, structure: .page, item: nil,
      title: .resource(SettingsPage.aiPolish.labelResource!),
      parent: .windowSettings, destination: .aiPolish, dictionaryTab: nil,
      visibility: .always, target: nil, fallbacks: []),
    SettingsMapNode(
      id: .pageAppSettings, structure: .page, item: nil,
      title: .resource(SettingsPage.appSettings.labelResource!),
      parent: .windowSettings, destination: .appSettings(.appearance), dictionaryTab: nil,
      visibility: .always, target: nil, fallbacks: []),
    SettingsMapNode(
      id: .pageDictation, structure: .page, item: nil,
      title: .resource(SettingsPage.dictation.labelResource!),
      parent: .windowSettings, destination: .dictation(.engine), dictionaryTab: nil,
      visibility: .always, target: nil, fallbacks: []),
    SettingsMapNode(
      id: .pageDictionary, structure: .page, item: nil,
      title: .resource(SettingsPage.dictionary.labelResource!),
      parent: .windowSettings, destination: .dictionary, dictionaryTab: nil,
      visibility: .always, target: nil, fallbacks: []),
    SettingsMapNode(
      id: .pageKeybinds, structure: .page, item: nil,
      title: .resource(SettingsPage.keybinds.labelResource!),
      parent: .windowSettings, destination: .keybinds, dictionaryTab: nil,
      visibility: .always, target: nil, fallbacks: []),
    SettingsMapNode(
      id: .pageSnippets, structure: .page, item: nil,
      title: .resource(SettingsPage.snippets.labelResource!),
      parent: .windowSettings, destination: .snippets, dictionaryTab: nil,
      visibility: .always, target: nil, fallbacks: []),
    SettingsMapNode(
      id: .pageTranscribeFile, structure: .page, item: nil,
      title: .resource(SettingsPage.transcribeFile.labelResource!),
      parent: .windowSettings, destination: .transcribeFile, dictionaryTab: nil,
      visibility: .always, target: nil, fallbacks: []),
    SettingsMapNode(
      id: .sectionTranscriptionEngine, structure: .section, item: nil,
      title: .resource(DictationSettingsCopy.Engine.sectionHeading),
      parent: .pageDictation, destination: .dictation(.engine), dictionaryTab: nil,
      visibility: .always, target: nil, fallbacks: []),
    SettingsMapNode(
      id: .sectionEngineShared, structure: .section, item: nil,
      title: .resource(DictationSettingsCopy.Engine.sharedHeading),
      parent: .pageDictation, destination: .dictation(.engine), dictionaryTab: nil,
      visibility: .always, target: nil, fallbacks: []),
    SettingsMapNode(
      id: .sectionMicrophone, structure: .section, item: nil,
      title: .resource(DictationSettingsCopy.Microphone.sectionHeading),
      parent: .pageDictation, destination: .dictation(.microphone), dictionaryTab: nil,
      visibility: .always, target: nil, fallbacks: []),
    SettingsMapNode(
      id: .sectionLivePreview, structure: .section, item: nil,
      title: .resource(LivePreviewSettingsCopy.sectionHeaderResource),
      parent: .pageDictation, destination: .dictation(.livePreview), dictionaryTab: nil,
      visibility: .always, target: nil, fallbacks: []),
    SettingsMapNode(
      id: .sectionPreviewEngine, structure: .section, item: nil,
      title: .resource(LivePreviewEngineCopy.sectionHeaderResource),
      parent: .pageDictation, destination: .dictation(.livePreview), dictionaryTab: nil,
      visibility: .always, target: nil, fallbacks: []),
    SettingsMapNode(
      id: .sectionPill, structure: .section, item: nil,
      title: .resource(DictationTab.pill.label),
      parent: .pageDictation, destination: .dictation(.pill), dictionaryTab: nil,
      visibility: .always, target: nil, fallbacks: []),
    SettingsMapNode(
      id: .sectionChimes, structure: .section, item: nil,
      title: .resource(DictationSettingsCopy.Chimes.sectionHeading),
      parent: .pageDictation, destination: .dictation(.chimes), dictionaryTab: nil,
      visibility: .always, target: nil, fallbacks: []),
    SettingsMapNode(
      id: .sectionClipboard, structure: .section, item: nil,
      title: .resource(DictationSettingsCopy.Clipboard.clipboardHeading),
      parent: .pageDictation, destination: .dictation(.clipboard), dictionaryTab: nil,
      visibility: .always, target: nil, fallbacks: []),
    SettingsMapNode(
      id: .sectionQuickAddClipboard, structure: .section, item: nil,
      title: .resource(DictationSettingsCopy.Clipboard.quickAddHeading),
      parent: .pageDictation, destination: .dictation(.clipboard), dictionaryTab: nil,
      visibility: .always, target: nil, fallbacks: []),
    SettingsMapNode(
      id: .sectionKeybindsRecording, structure: .section, item: nil,
      title: .resource(SettingsItemCopy.Keybinds.recordingSection),
      parent: .pageKeybinds, destination: .keybinds, dictionaryTab: nil,
      visibility: .always, target: nil, fallbacks: []),
    SettingsMapNode(
      id: .sectionKeybindsShortcuts, structure: .section, item: nil,
      title: .resource(SettingsItemCopy.Keybinds.shortcutsSection),
      parent: .pageKeybinds, destination: .keybinds, dictionaryTab: nil,
      visibility: .always, target: nil, fallbacks: []),
    SettingsMapNode(
      id: .sectionAiPolishModel, structure: .section, item: nil,
      title: .resource(SettingsItemCopy.AIPolish.modelSection),
      parent: .pageAiPolish, destination: .aiPolish, dictionaryTab: nil,
      visibility: .aiPolishEnabled, target: nil, fallbacks: []),
    SettingsMapNode(
      id: .sectionDictionary, structure: .section, item: nil,
      title: .resource(SettingsShellCopy.Dictionary.heading),
      parent: .pageDictionary, destination: .dictionary, dictionaryTab: nil,
      visibility: .always, target: nil, fallbacks: []),
    SettingsMapNode(
      id: .sectionAppearance, structure: .section, item: nil,
      title: .resource(SettingsItemCopy.AppSettings.appearanceSection),
      parent: .pageAppSettings, destination: .appSettings(.appearance), dictionaryTab: nil,
      visibility: .always, target: nil, fallbacks: []),
    SettingsMapNode(
      id: .sectionPermissions, structure: .section, item: nil,
      title: .resource(SettingsItemCopy.AppSettings.permissionsSection),
      parent: .pageAppSettings, destination: .appSettings(.permissions), dictionaryTab: nil,
      visibility: .always, target: nil, fallbacks: []),
    SettingsMapNode(
      id: .sectionPrivacy, structure: .section, item: nil,
      title: .resource(SettingsItemCopy.AppSettings.privacySection),
      parent: .pageAppSettings, destination: .appSettings(.privacy), dictionaryTab: nil,
      visibility: .always, target: nil, fallbacks: []),
    SettingsMapNode(
      id: .sectionAbout, structure: .section, item: nil,
      title: .resource(SettingsItemCopy.AppSettings.aboutSection),
      parent: .pageAppSettings, destination: .appSettings(.licenses), dictionaryTab: nil,
      visibility: .always, target: nil, fallbacks: []),
    SettingsMapNode(
      id: .dictationTabEngine, structure: .tab, item: .feature,
      title: .resource(DictationTab.engine.label),
      parent: .pageDictation, destination: .dictation(.engine), dictionaryTab: nil,
      visibility: .always, target: .dictationTabEngine, fallbacks: []),
    SettingsMapNode(
      id: .dictationTabMicrophone, structure: .tab, item: .feature,
      title: .resource(DictationTab.microphone.label),
      parent: .pageDictation, destination: .dictation(.microphone), dictionaryTab: nil,
      visibility: .always, target: .dictationTabMicrophone, fallbacks: []),
    SettingsMapNode(
      id: .dictationTabLivePreview, structure: .tab, item: .feature,
      title: .resource(DictationTab.livePreview.label),
      parent: .pageDictation, destination: .dictation(.livePreview), dictionaryTab: nil,
      visibility: .always, target: .dictationTabLivePreview, fallbacks: []),
    SettingsMapNode(
      id: .dictationTabPill, structure: .tab, item: .feature,
      title: .resource(DictationTab.pill.label),
      parent: .pageDictation, destination: .dictation(.pill), dictionaryTab: nil,
      visibility: .always, target: .dictationTabPill, fallbacks: []),
    SettingsMapNode(
      id: .dictationTabChimes, structure: .tab, item: .feature,
      title: .resource(DictationTab.chimes.label),
      parent: .pageDictation, destination: .dictation(.chimes), dictionaryTab: nil,
      visibility: .always, target: .dictationTabChimes, fallbacks: []),
    SettingsMapNode(
      id: .dictationTabClipboard, structure: .tab, item: .feature,
      title: .resource(DictationTab.clipboard.label),
      parent: .pageDictation, destination: .dictation(.clipboard), dictionaryTab: nil,
      visibility: .always, target: .dictationTabClipboard, fallbacks: []),
    SettingsMapNode(
      id: .transcriptionEngine, structure: .item, item: .setting,
      title: .resource(DictationSettingsCopy.Engine.sectionHeading),
      parent: .pageDictation, destination: .dictation(.engine), dictionaryTab: nil,
      visibility: .always, target: .transcriptionEngine, fallbacks: []),
    SettingsMapNode(
      id: .transcriptionEngineChange, structure: .item, item: .action,
      title: .resource(SettingsItemCopy.Shared.change),
      parent: .transcriptionEngine, destination: .dictation(.engine), dictionaryTab: nil,
      visibility: .always, target: .transcriptionEngine, fallbacks: []),
    SettingsMapNode(
      id: .transcriptionEngineFast, structure: .item, item: .choice,
      title: .resource(EngineChoicePresentation.fast.title),
      parent: .transcriptionEngine, destination: .dictation(.engine), dictionaryTab: nil,
      visibility: .engineChoicesExpanded, target: .transcriptionEngine, fallbacks: [.transcriptionEngine]),
    SettingsMapNode(
      id: .transcriptionEngineAllLanguages, structure: .item, item: .choice,
      title: .resource(EngineChoicePresentation.allLanguages.title),
      parent: .transcriptionEngine, destination: .dictation(.engine), dictionaryTab: nil,
      visibility: .engineChoicesExpanded, target: .transcriptionEngine, fallbacks: [.transcriptionEngine]),
    SettingsMapNode(
      id: .transcriptionEngineKeepCurrent, structure: .item, item: .action,
      title: .resource(DictationSettingsCopy.Engine.keepCurrent),
      parent: .transcriptionEngine, destination: .dictation(.engine), dictionaryTab: nil,
      visibility: .engineChoicesExpanded, target: .transcriptionEngine, fallbacks: [.transcriptionEngine]),
    SettingsMapNode(
      id: .transcriptionEngineRecheckFast, structure: .item, item: .action,
      title: .resource(EngineSummaryCopy.recheckFast),
      parent: .transcriptionEngine, destination: .dictation(.engine), dictionaryTab: nil,
      visibility: .fastSelected, target: .transcriptionEngineRecheckFast, fallbacks: [.transcriptionEngine]),
    SettingsMapNode(
      id: .fastModelCancelDownload, structure: .item, item: .action,
      title: .resource(SettingsItemCopy.Engine.fastCancel),
      parent: .transcriptionEngine, destination: .dictation(.engine), dictionaryTab: nil,
      visibility: .fastDeliveryAction, target: .fastModelCancelDownload, fallbacks: [.transcriptionEngine]),
    SettingsMapNode(
      id: .fastModelResume, structure: .item, item: .action,
      title: .resource(SettingsItemCopy.Engine.fastResume),
      parent: .transcriptionEngine, destination: .dictation(.engine), dictionaryTab: nil,
      visibility: .fastDeliveryAction, target: .transcriptionEngine, fallbacks: [.transcriptionEngine]),
    SettingsMapNode(
      id: .fastModelTryAgain, structure: .item, item: .action,
      title: .resource(SettingsItemCopy.Engine.fastTryAgain),
      parent: .transcriptionEngine, destination: .dictation(.engine), dictionaryTab: nil,
      visibility: .fastDeliveryAction, target: .transcriptionEngine, fallbacks: [.transcriptionEngine]),
    SettingsMapNode(
      id: .whisperModelSetUp, structure: .item, item: .action,
      title: .resource(DictationSettingsCopy.Engine.setUpModel),
      parent: .transcriptionEngine, destination: .dictation(.engine), dictionaryTab: nil,
      visibility: .whisperSetupState, target: .whisperModelSetUp, fallbacks: [.transcriptionEngine]),
    SettingsMapNode(
      id: .whisperModelCancelDownload, structure: .item, item: .action,
      title: .resource(SettingsItemCopy.Engine.whisperCancel),
      parent: .transcriptionEngine, destination: .dictation(.engine), dictionaryTab: nil,
      visibility: .whisperSetupState, target: .whisperModelCancelDownload, fallbacks: [.transcriptionEngine]),
    SettingsMapNode(
      id: .whisperModelResume, structure: .item, item: .action,
      title: .resource(SettingsItemCopy.Engine.whisperResume),
      parent: .transcriptionEngine, destination: .dictation(.engine), dictionaryTab: nil,
      visibility: .whisperSetupState, target: .whisperModelResume, fallbacks: [.transcriptionEngine]),
    SettingsMapNode(
      id: .whisperModelRemove, structure: .item, item: .action,
      title: .resource(SettingsItemCopy.Engine.whisperRemove),
      parent: .transcriptionEngine, destination: .dictation(.engine), dictionaryTab: nil,
      visibility: .whisperSetupState, target: .whisperModelRemove, fallbacks: [.transcriptionEngine]),
    SettingsMapNode(
      id: .whisperModelRecheck, structure: .item, item: .action,
      title: .resource(SettingsItemCopy.Engine.whisperRecheck),
      parent: .transcriptionEngine, destination: .dictation(.engine), dictionaryTab: nil,
      visibility: .whisperSetupState, target: .whisperModelRecheck, fallbacks: [.transcriptionEngine]),
    SettingsMapNode(
      id: .whisperModelTryAgain, structure: .item, item: .action,
      title: .resource(SettingsItemCopy.Engine.whisperTryAgain),
      parent: .transcriptionEngine, destination: .dictation(.engine), dictionaryTab: nil,
      visibility: .whisperSetupState, target: .whisperModelTryAgain, fallbacks: [.transcriptionEngine]),
    SettingsMapNode(
      id: .currentEngineSection, structure: .item, item: .feature,
      title: .dynamic(.currentEngineHeading),
      parent: .pageDictation, destination: .dictation(.engine), dictionaryTab: nil,
      visibility: .always, target: .currentEngineSection, fallbacks: []),
    SettingsMapNode(
      id: .autoDetectLanguage, structure: .item, item: .setting,
      title: .resource(DictationSettingsCopy.Engine.autoDetectTitle),
      parent: .pageDictation, destination: .dictation(.engine), dictionaryTab: nil,
      visibility: .languageSectionAvailable, target: .autoDetectLanguage, fallbacks: [.transcriptionEngine]),
    SettingsMapNode(
      id: .autoDetectLanguageResetSuggestions, structure: .item, item: .action,
      title: .resource(SettingsItemCopy.Engine.resetSuggestions),
      parent: .autoDetectLanguage, destination: .dictation(.engine), dictionaryTab: nil,
      visibility: .languageSectionAvailable, target: .autoDetectLanguageResetSuggestions, fallbacks: []),
    SettingsMapNode(
      id: .lockedLanguage, structure: .item, item: .setting,
      title: .dynamic(.lockedLanguage),
      parent: .pageDictation, destination: .dictation(.engine), dictionaryTab: nil,
      visibility: .languageLocked, target: .lockedLanguage, fallbacks: [.transcriptionEngine]),
    SettingsMapNode(
      id: .lockedLanguageChange, structure: .item, item: .action,
      title: .resource(SettingsItemCopy.Engine.lockedLanguageChange),
      parent: .lockedLanguage, destination: .dictation(.engine), dictionaryTab: nil,
      visibility: .languageLocked, target: .lockedLanguageChange, fallbacks: []),
    SettingsMapNode(
      id: .fasterTranscription, structure: .item, item: .setting,
      title: .resource(LiveTranscriptionCopy.toggleLabelResource),
      parent: .pageDictation, destination: .dictation(.engine), dictionaryTab: nil,
      visibility: .always, target: .fasterTranscription, fallbacks: []),
    SettingsMapNode(
      id: .stopOnSilence, structure: .item, item: .setting,
      title: .resource(DictationSettingsCopy.Engine.stopOnSilenceTitle),
      parent: .pageDictation, destination: .dictation(.engine), dictionaryTab: nil,
      visibility: .always, target: .stopOnSilence, fallbacks: []),
    SettingsMapNode(
      id: .pauseDuration, structure: .item, item: .setting,
      title: .resource(SettingsItemCopy.Engine.pauseDuration),
      parent: .stopOnSilence, destination: .dictation(.engine), dictionaryTab: nil,
      visibility: .stopOnSilenceOn, target: .pauseDuration, fallbacks: [.stopOnSilence]),
    SettingsMapNode(
      id: .fillerRemoval, structure: .item, item: .setting,
      title: .resource(DictationSettingsCopy.Engine.fillerTitle),
      parent: .pageDictation, destination: .dictation(.engine), dictionaryTab: nil,
      visibility: .always, target: .fillerRemoval, fallbacks: []),
    SettingsMapNode(
      id: .spokenEmoji, structure: .item, item: .setting,
      title: .resource(DictationSettingsCopy.Engine.emojiTitle),
      parent: .pageDictation, destination: .dictation(.engine), dictionaryTab: nil,
      visibility: .always, target: .spokenEmoji, fallbacks: []),
    SettingsMapNode(
      id: .spokenPunctuation, structure: .item, item: .setting,
      title: .resource(SpokenPunctuationCopy.toggleLabelResource),
      parent: .pageDictation, destination: .dictation(.engine), dictionaryTab: nil,
      visibility: .always, target: .spokenPunctuation, fallbacks: []),
    SettingsMapNode(
      id: .startWordLanguage, structure: .item, item: .setting,
      title: .resource(SpokenPunctuationCopy.startWordTitleResource),
      parent: .spokenPunctuation, destination: .dictation(.engine), dictionaryTab: nil,
      visibility: .spokenPunctuationOn, target: .startWordLanguage, fallbacks: [.spokenPunctuation]),
    SettingsMapNode(
      id: .startWordLanguageEn, structure: .item, item: .choice,
      title: .dynamic(.startWordLanguage),
      parent: .startWordLanguage, destination: .dictation(.engine), dictionaryTab: nil,
      visibility: .spokenPunctuationOn, target: .startWordLanguage, fallbacks: []),
    SettingsMapNode(
      id: .startWordLanguageDe, structure: .item, item: .choice,
      title: .dynamic(.startWordLanguage),
      parent: .startWordLanguage, destination: .dictation(.engine), dictionaryTab: nil,
      visibility: .spokenPunctuationOn, target: .startWordLanguage, fallbacks: []),
    SettingsMapNode(
      id: .startWordLanguageFr, structure: .item, item: .choice,
      title: .dynamic(.startWordLanguage),
      parent: .startWordLanguage, destination: .dictation(.engine), dictionaryTab: nil,
      visibility: .spokenPunctuationOn, target: .startWordLanguage, fallbacks: []),
    SettingsMapNode(
      id: .startWordLanguageEs, structure: .item, item: .choice,
      title: .dynamic(.startWordLanguage),
      parent: .startWordLanguage, destination: .dictation(.engine), dictionaryTab: nil,
      visibility: .spokenPunctuationOn, target: .startWordLanguage, fallbacks: []),
    SettingsMapNode(
      id: .startWordLanguageIt, structure: .item, item: .choice,
      title: .dynamic(.startWordLanguage),
      parent: .startWordLanguage, destination: .dictation(.engine), dictionaryTab: nil,
      visibility: .spokenPunctuationOn, target: .startWordLanguage, fallbacks: []),
    SettingsMapNode(
      id: .startWordField, structure: .item, item: .setting,
      title: .resource(SpokenPunctuationCopy.languagePickerLabelResource),
      parent: .spokenPunctuation, destination: .dictation(.engine), dictionaryTab: nil,
      visibility: .spokenPunctuationOn, target: .startWordField, fallbacks: [.spokenPunctuation]),
    SettingsMapNode(
      id: .startWordSave, structure: .item, item: .action,
      title: .resource(SpokenPunctuationCopy.saveLabelResource),
      parent: .startWordField, destination: .dictation(.engine), dictionaryTab: nil,
      visibility: .spokenPunctuationOn, target: .startWordSave, fallbacks: []),
    SettingsMapNode(
      id: .startWordReset, structure: .item, item: .action,
      title: .resource(SpokenPunctuationCopy.resetLabelResource),
      parent: .startWordField, destination: .dictation(.engine), dictionaryTab: nil,
      visibility: .spokenPunctuationOn, target: .startWordReset, fallbacks: []),
    SettingsMapNode(
      id: .unloadModelAfter, structure: .item, item: .setting,
      title: .resource(DictationSettingsCopy.Engine.unloadTitle),
      parent: .pageDictation, destination: .dictation(.engine), dictionaryTab: nil,
      visibility: .always, target: .unloadModelAfter, fallbacks: []),
    SettingsMapNode(
      id: .unloadModelNever, structure: .item, item: .choice,
      title: .resource(ModelUnloadPolicy.never.displayNameResource),
      parent: .unloadModelAfter, destination: .dictation(.engine), dictionaryTab: nil,
      visibility: .always, target: .unloadModelAfter, fallbacks: []),
    SettingsMapNode(
      id: .unloadModelImmediately, structure: .item, item: .choice,
      title: .resource(ModelUnloadPolicy.immediately.displayNameResource),
      parent: .unloadModelAfter, destination: .dictation(.engine), dictionaryTab: nil,
      visibility: .always, target: .unloadModelAfter, fallbacks: []),
    SettingsMapNode(
      id: .unloadModelTwoMinutes, structure: .item, item: .choice,
      title: .resource(ModelUnloadPolicy.twoMinutes.displayNameResource),
      parent: .unloadModelAfter, destination: .dictation(.engine), dictionaryTab: nil,
      visibility: .always, target: .unloadModelAfter, fallbacks: []),
    SettingsMapNode(
      id: .unloadModelFiveMinutes, structure: .item, item: .choice,
      title: .resource(ModelUnloadPolicy.fiveMinutes.displayNameResource),
      parent: .unloadModelAfter, destination: .dictation(.engine), dictionaryTab: nil,
      visibility: .always, target: .unloadModelAfter, fallbacks: []),
    SettingsMapNode(
      id: .unloadModelTenMinutes, structure: .item, item: .choice,
      title: .resource(ModelUnloadPolicy.tenMinutes.displayNameResource),
      parent: .unloadModelAfter, destination: .dictation(.engine), dictionaryTab: nil,
      visibility: .always, target: .unloadModelAfter, fallbacks: []),
    SettingsMapNode(
      id: .unloadModelFifteenMinutes, structure: .item, item: .choice,
      title: .resource(ModelUnloadPolicy.fifteenMinutes.displayNameResource),
      parent: .unloadModelAfter, destination: .dictation(.engine), dictionaryTab: nil,
      visibility: .always, target: .unloadModelAfter, fallbacks: []),
    SettingsMapNode(
      id: .unloadModelOneHour, structure: .item, item: .choice,
      title: .resource(ModelUnloadPolicy.sixtyMinutes.displayNameResource),
      parent: .unloadModelAfter, destination: .dictation(.engine), dictionaryTab: nil,
      visibility: .always, target: .unloadModelAfter, fallbacks: []),
    SettingsMapNode(
      id: .inputDevice, structure: .item, item: .setting,
      title: .resource(DictationSettingsCopy.Microphone.inputDeviceTitle),
      parent: .pageDictation, destination: .dictation(.microphone), dictionaryTab: nil,
      visibility: .always, target: .inputDevice, fallbacks: []),
    SettingsMapNode(
      id: .inputDeviceAuto, structure: .item, item: .choice,
      title: .resource(SettingsItemCopy.Microphone.auto),
      parent: .inputDevice, destination: .dictation(.microphone), dictionaryTab: nil,
      visibility: .always, target: .inputDevice, fallbacks: []),
    SettingsMapNode(
      id: .inputDeviceDevice, structure: .item, item: .choice,
      title: .dynamic(.inputDeviceName),
      parent: .inputDevice, destination: .dictation(.microphone), dictionaryTab: nil,
      visibility: .always, target: .inputDevice, fallbacks: []),
    SettingsMapNode(
      id: .inputSocket, structure: .item, item: .setting,
      title: .resource(InputSocketCopy.labelResource),
      parent: .inputDevice, destination: .dictation(.microphone), dictionaryTab: nil,
      visibility: .multiInputDevice, target: .inputSocket, fallbacks: [.inputDevice]),
    SettingsMapNode(
      id: .inputSocketInput, structure: .item, item: .choice,
      title: .dynamic(.inputSocketOption),
      parent: .inputSocket, destination: .dictation(.microphone), dictionaryTab: nil,
      visibility: .multiInputDevice, target: .inputSocket, fallbacks: []),
    SettingsMapNode(
      id: .mediaDuringDictation, structure: .item, item: .setting,
      title: .resource(DictationSettingsCopy.Microphone.mediaTitle),
      parent: .pageDictation, destination: .dictation(.microphone), dictionaryTab: nil,
      visibility: .always, target: .mediaDuringDictation, fallbacks: []),
    SettingsMapNode(
      id: .mediaDuringDictationContinue, structure: .item, item: .choice,
      title: .resource(SettingsItemCopy.Microphone.mediaContinue),
      parent: .mediaDuringDictation, destination: .dictation(.microphone), dictionaryTab: nil,
      visibility: .always, target: .mediaDuringDictation, fallbacks: []),
    SettingsMapNode(
      id: .mediaDuringDictationLower, structure: .item, item: .choice,
      title: .resource(SettingsItemCopy.Microphone.mediaLower),
      parent: .mediaDuringDictation, destination: .dictation(.microphone), dictionaryTab: nil,
      visibility: .always, target: .mediaDuringDictation, fallbacks: []),
    SettingsMapNode(
      id: .mediaDuringDictationMute, structure: .item, item: .choice,
      title: .resource(SettingsItemCopy.Microphone.mediaMute),
      parent: .mediaDuringDictation, destination: .dictation(.microphone), dictionaryTab: nil,
      visibility: .always, target: .mediaDuringDictation, fallbacks: []),
    SettingsMapNode(
      id: .mediaDuringDictationPause, structure: .item, item: .choice,
      title: .resource(SettingsItemCopy.Microphone.mediaPause),
      parent: .mediaDuringDictation, destination: .dictation(.microphone), dictionaryTab: nil,
      visibility: .always, target: .mediaDuringDictation, fallbacks: []),
    SettingsMapNode(
      id: .micReadiness, structure: .item, item: .setting,
      title: .resource(DictationSettingsCopy.Microphone.readinessTitle),
      parent: .pageDictation, destination: .dictation(.microphone), dictionaryTab: nil,
      visibility: .always, target: .micReadiness, fallbacks: []),
    SettingsMapNode(
      id: .micReadinessOff, structure: .item, item: .choice,
      title: .resource(SettingsItemCopy.Microphone.readinessOff),
      parent: .micReadiness, destination: .dictation(.microphone), dictionaryTab: nil,
      visibility: .always, target: .micReadiness, fallbacks: []),
    SettingsMapNode(
      id: .micReadiness10s, structure: .item, item: .choice,
      title: .resource(SettingsItemCopy.Microphone.readiness10s),
      parent: .micReadiness, destination: .dictation(.microphone), dictionaryTab: nil,
      visibility: .always, target: .micReadiness, fallbacks: []),
    SettingsMapNode(
      id: .micReadiness30s, structure: .item, item: .choice,
      title: .resource(SettingsItemCopy.Microphone.readiness30s),
      parent: .micReadiness, destination: .dictation(.microphone), dictionaryTab: nil,
      visibility: .always, target: .micReadiness, fallbacks: []),
    SettingsMapNode(
      id: .micReadiness60s, structure: .item, item: .choice,
      title: .resource(SettingsItemCopy.Microphone.readiness60s),
      parent: .micReadiness, destination: .dictation(.microphone), dictionaryTab: nil,
      visibility: .always, target: .micReadiness, fallbacks: []),
    SettingsMapNode(
      id: .micReadinessAlways, structure: .item, item: .choice,
      title: .resource(SettingsItemCopy.Microphone.readinessAlways),
      parent: .micReadiness, destination: .dictation(.microphone), dictionaryTab: nil,
      visibility: .always, target: .micReadiness, fallbacks: []),
    SettingsMapNode(
      id: .bluetoothGuide, structure: .item, item: .feature,
      title: .resource(BluetoothTipsCopy.settingsHeaderResource),
      parent: .pageDictation, destination: .dictation(.microphone), dictionaryTab: nil,
      visibility: .always, target: .bluetoothGuide, fallbacks: []),
    SettingsMapNode(
      id: .bluetoothGuideLearnMore, structure: .item, item: .action,
      title: .resource(SettingsItemCopy.Microphone.bluetoothLearnMore),
      parent: .bluetoothGuide, destination: .dictation(.microphone), dictionaryTab: nil,
      visibility: .always, target: .bluetoothGuideLearnMore, fallbacks: []),
    SettingsMapNode(
      id: .livePreview, structure: .item, item: .setting,
      title: .resource(LivePreviewSettingsCopy.toggleLabelResource),
      parent: .pageDictation, destination: .dictation(.livePreview), dictionaryTab: nil,
      visibility: .always, target: .livePreview, fallbacks: []),
    SettingsMapNode(
      id: .livePreviewLanguage, structure: .item, item: .action,
      title: .dynamic(.previewLanguage),
      parent: .livePreview, destination: .dictation(.livePreview), dictionaryTab: nil,
      visibility: .livePreviewOn, target: .livePreviewLanguage, fallbacks: []),
    SettingsMapNode(
      id: .livePreviewBrowseDownloads, structure: .item, item: .action,
      title: .resource(LivePreviewSettingsCopy.browseDownloadsButtonResource),
      parent: .livePreview, destination: .dictation(.livePreview), dictionaryTab: nil,
      visibility: .previewLanguageMissing, target: .livePreviewBrowseDownloads, fallbacks: []),
    SettingsMapNode(
      id: .previewEngine, structure: .item, item: .setting,
      title: .resource(LivePreviewEngineCopy.sectionHeaderResource),
      parent: .pageDictation, destination: .dictation(.livePreview), dictionaryTab: nil,
      visibility: .always, target: .previewEngine, fallbacks: []),
    SettingsMapNode(
      id: .previewEngineChange, structure: .item, item: .action,
      title: .resource(SettingsItemCopy.Shared.change),
      parent: .previewEngine, destination: .dictation(.livePreview), dictionaryTab: nil,
      visibility: .always, target: .previewEngine, fallbacks: []),
    SettingsMapNode(
      id: .previewEngineCompare, structure: .item, item: .action,
      title: .resource(LivePreviewEngineCopy.learnMoreLabelResource),
      parent: .previewEngine, destination: .dictation(.livePreview), dictionaryTab: nil,
      visibility: .always, target: .previewEngineCompare, fallbacks: []),
    SettingsMapNode(
      id: .previewEngineApple, structure: .item, item: .choice,
      title: .verbatim(LivePreviewEngineCopy.appleTitle),
      parent: .previewEngine, destination: .dictation(.livePreview), dictionaryTab: nil,
      visibility: .previewChoicesExpanded, target: .previewEngine, fallbacks: []),
    SettingsMapNode(
      id: .previewEngineUniversal, structure: .item, item: .choice,
      title: .resource(LivePreviewEngineCopy.universalTitleResource),
      parent: .previewEngine, destination: .dictation(.livePreview), dictionaryTab: nil,
      visibility: .previewChoicesExpanded, target: .previewEngine, fallbacks: []),
    SettingsMapNode(
      id: .previewEngineKeepCurrent, structure: .item, item: .action,
      title: .resource(DictationSettingsCopy.Preview.keepCurrent),
      parent: .previewEngine, destination: .dictation(.livePreview), dictionaryTab: nil,
      visibility: .previewChoicesExpanded, target: .previewEngine, fallbacks: []),
    SettingsMapNode(
      id: .previewEngineUniversalDownload, structure: .item, item: .action,
      title: .resource(SettingsItemCopy.LivePreview.universalDownload),
      parent: .previewEngineUniversal, destination: .dictation(.livePreview), dictionaryTab: nil,
      visibility: .universalSetupState, target: .previewEngine, fallbacks: []),
    SettingsMapNode(
      id: .previewEngineUniversalCancel, structure: .item, item: .action,
      title: .resource(SettingsItemCopy.LivePreview.universalCancel),
      parent: .previewEngineUniversal, destination: .dictation(.livePreview), dictionaryTab: nil,
      visibility: .universalSetupState, target: .previewEngine, fallbacks: []),
    SettingsMapNode(
      id: .previewEngineUniversalResume, structure: .item, item: .action,
      title: .resource(SettingsItemCopy.LivePreview.universalResume),
      parent: .previewEngineUniversal, destination: .dictation(.livePreview), dictionaryTab: nil,
      visibility: .universalSetupState, target: .previewEngine, fallbacks: []),
    SettingsMapNode(
      id: .previewEngineUniversalRetry, structure: .item, item: .action,
      title: .resource(SettingsItemCopy.LivePreview.universalRetry),
      parent: .previewEngineUniversal, destination: .dictation(.livePreview), dictionaryTab: nil,
      visibility: .universalSetupState, target: .previewEngine, fallbacks: []),
    SettingsMapNode(
      id: .previewEngineUniversalRemove, structure: .item, item: .action,
      title: .resource(SettingsItemCopy.LivePreview.universalRemove),
      parent: .previewEngineUniversal, destination: .dictation(.livePreview), dictionaryTab: nil,
      visibility: .universalSetupState, target: .previewEngine, fallbacks: []),
    SettingsMapNode(
      id: .previewLanguages, structure: .item, item: .feature,
      title: .resource(LivePreviewSettingsCopy.packsHeaderResource),
      parent: .pageDictation, destination: .dictation(.livePreview), dictionaryTab: nil,
      visibility: .appleLanguagePacks, target: .previewLanguages, fallbacks: [.previewEngine]),
    SettingsMapNode(
      id: .previewLanguagesInstall, structure: .item, item: .action,
      title: .resource(LivePreviewSettingsCopy.packsInstallRowTitleResource),
      parent: .previewLanguages, destination: .dictation(.livePreview), dictionaryTab: nil,
      visibility: .appleLanguagePacks, target: .previewLanguages, fallbacks: []),
    SettingsMapNode(
      id: .pillPosition, structure: .item, item: .setting,
      title: .resource(DictationSettingsCopy.Pill.positionTitle),
      parent: .pageDictation, destination: .dictation(.pill), dictionaryTab: nil,
      visibility: .always, target: .pillPosition, fallbacks: []),
    SettingsMapNode(
      id: .pillPositionTop, structure: .item, item: .choice,
      title: .resource(SettingsItemCopy.Pill.top),
      parent: .pillPosition, destination: .dictation(.pill), dictionaryTab: nil,
      visibility: .always, target: .pillPosition, fallbacks: []),
    SettingsMapNode(
      id: .pillPositionBottom, structure: .item, item: .choice,
      title: .resource(SettingsItemCopy.Pill.bottom),
      parent: .pillPosition, destination: .dictation(.pill), dictionaryTab: nil,
      visibility: .always, target: .pillPosition, fallbacks: []),
    SettingsMapNode(
      id: .pillStyle, structure: .item, item: .setting,
      title: .resource(DictationSettingsCopy.Pill.styleTitle),
      parent: .pageDictation, destination: .dictation(.pill), dictionaryTab: nil,
      visibility: .always, target: .pillStyle, fallbacks: []),
    SettingsMapNode(
      id: .pillStyleCapsule, structure: .item, item: .choice,
      title: .resource(RecordingPillDesign.classic.displayNameResource),
      parent: .pillStyle, destination: .dictation(.pill), dictionaryTab: nil,
      visibility: .always, target: .pillStyle, fallbacks: []),
    SettingsMapNode(
      id: .pillStyleLevelRail, structure: .item, item: .choice,
      title: .resource(RecordingPillDesign.levelRail.displayNameResource),
      parent: .pillStyle, destination: .dictation(.pill), dictionaryTab: nil,
      visibility: .always, target: .pillStyle, fallbacks: []),
    SettingsMapNode(
      id: .pillStyleReadingWell, structure: .item, item: .choice,
      title: .resource(RecordingPillDesign.readingWell.displayNameResource),
      parent: .pillStyle, destination: .dictation(.pill), dictionaryTab: nil,
      visibility: .always, target: .pillStyle, fallbacks: []),
    SettingsMapNode(
      id: .pillStyleConfigureLivePreview, structure: .item, item: .action,
      title: .resource(SettingsItemCopy.Pill.configureLivePreview),
      parent: .pillStyle, destination: .dictation(.pill), dictionaryTab: nil,
      visibility: .always, target: .pillStyleConfigureLivePreview, fallbacks: [.pillStyle]),
    SettingsMapNode(
      id: .recordingChimes, structure: .item, item: .setting,
      title: .resource(DictationSettingsCopy.Chimes.toggleTitle),
      parent: .pageDictation, destination: .dictation(.chimes), dictionaryTab: nil,
      visibility: .always, target: .recordingChimes, fallbacks: []),
    SettingsMapNode(
      id: .recordingChime, structure: .item, item: .setting,
      title: .resource(DictationSettingsCopy.Chimes.sectionHeading),
      parent: .pageDictation, destination: .dictation(.chimes), dictionaryTab: nil,
      visibility: .always, target: .recordingChime, fallbacks: []),
    SettingsMapNode(
      id: .recordingChimeDustMote, structure: .item, item: .choice,
      title: .resource(displayNameResource(for: RecordingSoundPairing.dustMote)),
      parent: .recordingChime, destination: .dictation(.chimes), dictionaryTab: nil,
      visibility: .always, target: .recordingChime, fallbacks: []),
    SettingsMapNode(
      id: .recordingChimeVelvetHush, structure: .item, item: .choice,
      title: .resource(displayNameResource(for: RecordingSoundPairing.velvetHush)),
      parent: .recordingChime, destination: .dictation(.chimes), dictionaryTab: nil,
      visibility: .always, target: .recordingChime, fallbacks: []),
    SettingsMapNode(
      id: .recordingChimeMutedConfirm, structure: .item, item: .choice,
      title: .resource(displayNameResource(for: RecordingSoundPairing.mutedConfirm)),
      parent: .recordingChime, destination: .dictation(.chimes), dictionaryTab: nil,
      visibility: .always, target: .recordingChime, fallbacks: []),
    SettingsMapNode(
      id: .recordingChimeWhisperTick, structure: .item, item: .choice,
      title: .resource(displayNameResource(for: RecordingSoundPairing.whisperTick)),
      parent: .recordingChime, destination: .dictation(.chimes), dictionaryTab: nil,
      visibility: .always, target: .recordingChime, fallbacks: []),
    SettingsMapNode(
      id: .recordingChimeRoundPebble, structure: .item, item: .choice,
      title: .resource(displayNameResource(for: RecordingSoundPairing.roundPebble)),
      parent: .recordingChime, destination: .dictation(.chimes), dictionaryTab: nil,
      visibility: .always, target: .recordingChime, fallbacks: []),
    SettingsMapNode(
      id: .recordingChimePaperTap, structure: .item, item: .choice,
      title: .resource(displayNameResource(for: RecordingSoundPairing.paperTap)),
      parent: .recordingChime, destination: .dictation(.chimes), dictionaryTab: nil,
      visibility: .always, target: .recordingChime, fallbacks: []),
    SettingsMapNode(
      id: .recordingChimeSoftHush, structure: .item, item: .choice,
      title: .resource(displayNameResource(for: RecordingSoundPairing.softHush)),
      parent: .recordingChime, destination: .dictation(.chimes), dictionaryTab: nil,
      visibility: .always, target: .recordingChime, fallbacks: []),
    SettingsMapNode(
      id: .recordingChimeLowNod, structure: .item, item: .choice,
      title: .resource(displayNameResource(for: RecordingSoundPairing.lowNod)),
      parent: .recordingChime, destination: .dictation(.chimes), dictionaryTab: nil,
      visibility: .always, target: .recordingChime, fallbacks: []),
    SettingsMapNode(
      id: .recordingChimeCloudPop, structure: .item, item: .choice,
      title: .resource(displayNameResource(for: RecordingSoundPairing.cloudPop)),
      parent: .recordingChime, destination: .dictation(.chimes), dictionaryTab: nil,
      visibility: .always, target: .recordingChime, fallbacks: []),
    SettingsMapNode(
      id: .recordingChimeVelvetTap, structure: .item, item: .choice,
      title: .resource(displayNameResource(for: RecordingSoundPairing.velvetTap)),
      parent: .recordingChime, destination: .dictation(.chimes), dictionaryTab: nil,
      visibility: .always, target: .recordingChime, fallbacks: []),
    SettingsMapNode(
      id: .recordingChimeSatinShift, structure: .item, item: .choice,
      title: .resource(displayNameResource(for: RecordingSoundPairing.satinShift)),
      parent: .recordingChime, destination: .dictation(.chimes), dictionaryTab: nil,
      visibility: .always, target: .recordingChime, fallbacks: []),
    SettingsMapNode(
      id: .recordingChimeAirGlint, structure: .item, item: .choice,
      title: .resource(displayNameResource(for: RecordingSoundPairing.airGlint)),
      parent: .recordingChime, destination: .dictation(.chimes), dictionaryTab: nil,
      visibility: .always, target: .recordingChime, fallbacks: []),
    SettingsMapNode(
      id: .recordingChimePreview, structure: .item, item: .action,
      title: .dynamic(.chimePreview),
      parent: .recordingChime, destination: .dictation(.chimes), dictionaryTab: nil,
      visibility: .always, target: .recordingChime, fallbacks: []),
    SettingsMapNode(
      id: .autoCopyToClipboard, structure: .item, item: .setting,
      title: .resource(DictationSettingsCopy.Clipboard.autoCopyTitle),
      parent: .pageDictation, destination: .dictation(.clipboard), dictionaryTab: nil,
      visibility: .always, target: .autoCopyToClipboard, fallbacks: []),
    SettingsMapNode(
      id: .restoreClipboard, structure: .item, item: .setting,
      title: .resource(DictationSettingsCopy.Clipboard.restoreTitle),
      parent: .pageDictation, destination: .dictation(.clipboard), dictionaryTab: nil,
      visibility: .always, target: .restoreClipboard, fallbacks: []),
    SettingsMapNode(
      id: .smartInsertion, structure: .item, item: .setting,
      title: .resource(DictationSettingsCopy.Clipboard.smartInsertionTitle),
      parent: .pageDictation, destination: .dictation(.clipboard), dictionaryTab: nil,
      visibility: .always, target: .smartInsertion, fallbacks: []),
    SettingsMapNode(
      id: .quickAddClipboardFallback, structure: .item, item: .setting,
      title: .resource(DictationSettingsCopy.Clipboard.quickAddTitle),
      parent: .pageDictation, destination: .dictation(.clipboard), dictionaryTab: nil,
      visibility: .always, target: .quickAddClipboardFallback, fallbacks: []),
    SettingsMapNode(
      id: .recordingMode, structure: .item, item: .setting,
      title: .resource(KeybindsSettingsCopy.modeTitle),
      parent: .pageKeybinds, destination: .keybinds, dictionaryTab: nil,
      visibility: .always, target: .recordingMode, fallbacks: []),
    SettingsMapNode(
      id: .recordingModePushToTalk, structure: .item, item: .choice,
      title: .resource(SettingsItemCopy.Keybinds.pushToTalk),
      parent: .recordingMode, destination: .keybinds, dictionaryTab: nil,
      visibility: .always, target: .recordingMode, fallbacks: []),
    SettingsMapNode(
      id: .recordingModeToggle, structure: .item, item: .choice,
      title: .resource(SettingsItemCopy.Keybinds.toggle),
      parent: .recordingMode, destination: .keybinds, dictionaryTab: nil,
      visibility: .always, target: .recordingMode, fallbacks: []),
    SettingsMapNode(
      id: .recordKeybind, structure: .item, item: .setting,
      title: .resource(KeybindsSettingsCopy.recordTitle),
      parent: .pageKeybinds, destination: .keybinds, dictionaryTab: nil,
      visibility: .always, target: .recordKeybind, fallbacks: []),
    SettingsMapNode(
      id: .cancelKeybind, structure: .item, item: .setting,
      title: .resource(KeybindsSettingsCopy.cancelTitle),
      parent: .pageKeybinds, destination: .keybinds, dictionaryTab: nil,
      visibility: .always, target: .cancelKeybind, fallbacks: []),
    SettingsMapNode(
      id: .escapeRecovery, structure: .item, item: .setting,
      title: .resource(KeybindsSettingsCopy.recoveryTitle),
      parent: .pageKeybinds, destination: .keybinds, dictionaryTab: nil,
      visibility: .always, target: .escapeRecovery, fallbacks: []),
    SettingsMapNode(
      id: .quickAddKeybind, structure: .item, item: .setting,
      title: .resource(KeybindsSettingsCopy.addTitle),
      parent: .pageKeybinds, destination: .keybinds, dictionaryTab: nil,
      visibility: .always, target: .quickAddKeybind, fallbacks: []),
    SettingsMapNode(
      id: .pasteLastKeybind, structure: .item, item: .setting,
      title: .resource(KeybindsSettingsCopy.pasteTitle),
      parent: .pageKeybinds, destination: .keybinds, dictionaryTab: nil,
      visibility: .always, target: .pasteLastKeybind, fallbacks: []),
    SettingsMapNode(
      id: .copyLastKeybind, structure: .item, item: .setting,
      title: .resource(KeybindsSettingsCopy.copyTitle),
      parent: .pageKeybinds, destination: .keybinds, dictionaryTab: nil,
      visibility: .always, target: .copyLastKeybind, fallbacks: []),
    SettingsMapNode(
      id: .keybindResetToDefault, structure: .item, item: .action,
      title: .resource(SettingsItemCopy.Keybinds.resetToDefault),
      parent: .pageKeybinds, destination: .keybinds, dictionaryTab: nil,
      visibility: .always, target: .recordKeybind, fallbacks: []),
    SettingsMapNode(
      id: .transcribeFileSteps, structure: .item, item: .feature,
      title: .dynamic(.transcribeFileStep),
      parent: .pageTranscribeFile, destination: .transcribeFile, dictionaryTab: nil,
      visibility: .always, target: .transcribeFileSteps, fallbacks: []),
    SettingsMapNode(
      id: .enableAIPolish, structure: .item, item: .setting,
      title: .resource(SettingsItemCopy.AIPolish.enable),
      parent: .pageAiPolish, destination: .aiPolish, dictionaryTab: nil,
      visibility: .always, target: .enableAIPolish, fallbacks: []),
    SettingsMapNode(
      id: .aiPolishProvider, structure: .item, item: .setting,
      title: .dynamic(.providerName),
      parent: .pageAiPolish, destination: .aiPolish, dictionaryTab: nil,
      visibility: .aiPolishEnabled, target: .aiPolishProvider, fallbacks: []),
    SettingsMapNode(
      id: .aiPolishProviderEgOne, structure: .item, item: .choice,
      title: .verbatim(LLMProvider.egOne.displayName),
      parent: .aiPolishProvider, destination: .aiPolish, dictionaryTab: nil,
      visibility: .aiPolishEnabled, target: .aiPolishProvider, fallbacks: [.aiPolishProvider, .enableAIPolish]),
    SettingsMapNode(
      id: .aiPolishProviderS1Mini, structure: .item, item: .choice,
      title: .verbatim(LLMProvider.s1Mini.displayName),
      parent: .aiPolishProvider, destination: .aiPolish, dictionaryTab: nil,
      visibility: .aiPolishEnabled, target: .aiPolishProvider, fallbacks: [.aiPolishProvider, .enableAIPolish]),
    SettingsMapNode(
      id: .aiPolishProviderAppleIntelligence, structure: .item, item: .choice,
      title: .verbatim(LLMProvider.appleIntelligence.displayName),
      parent: .aiPolishProvider, destination: .aiPolish, dictionaryTab: nil,
      visibility: .aiPolishEnabled, target: .aiPolishProvider, fallbacks: [.aiPolishProvider, .enableAIPolish]),
    SettingsMapNode(
      id: .aiPolishProviderOllama, structure: .item, item: .choice,
      title: .verbatim(LLMProvider.ollama.displayName),
      parent: .aiPolishProvider, destination: .aiPolish, dictionaryTab: nil,
      visibility: .aiPolishEnabled, target: .aiPolishProvider, fallbacks: [.aiPolishProvider, .enableAIPolish]),
    SettingsMapNode(
      id: .aiPolishProviderOpenAI, structure: .item, item: .choice,
      title: .verbatim(LLMProvider.openAI.displayName),
      parent: .aiPolishProvider, destination: .aiPolish, dictionaryTab: nil,
      visibility: .aiPolishEnabled, target: .aiPolishProvider, fallbacks: [.aiPolishProvider, .enableAIPolish]),
    SettingsMapNode(
      id: .aiPolishProviderGemini, structure: .item, item: .choice,
      title: .verbatim(PolishRailCatalog.geminiName),
      parent: .aiPolishProvider, destination: .aiPolish, dictionaryTab: nil,
      visibility: .aiPolishEnabled, target: .aiPolishProvider, fallbacks: [.aiPolishProvider, .enableAIPolish]),
    SettingsMapNode(
      id: .aiPolishProviderClaude, structure: .item, item: .choice,
      title: .verbatim(LLMProvider.claude.displayName),
      parent: .aiPolishProvider, destination: .aiPolish, dictionaryTab: nil,
      visibility: .aiPolishEnabled, target: .aiPolishProvider, fallbacks: [.aiPolishProvider, .enableAIPolish]),
    SettingsMapNode(
      id: .aiPolishProviderSection, structure: .item, item: .feature,
      title: .dynamic(.providerSection),
      parent: .aiPolishProvider, destination: .aiPolish, dictionaryTab: nil,
      visibility: .providerSelected, target: .aiPolishProviderSection, fallbacks: [.aiPolishProvider, .enableAIPolish]),
    SettingsMapNode(
      id: .aiPolishWhyUseEgOne, structure: .item, item: .feature,
      title: .resource(SettingsItemCopy.AIPolish.whyEGOne),
      parent: .aiPolishProviderEgOne, destination: .aiPolish, dictionaryTab: nil,
      visibility: .providerSelected, target: .aiPolishWhyUseEgOne, fallbacks: [.aiPolishProvider, .enableAIPolish]),
    SettingsMapNode(
      id: .aiPolishWhyUseS1Mini, structure: .item, item: .feature,
      title: .resource(SettingsItemCopy.AIPolish.whyS1Mini),
      parent: .aiPolishProviderS1Mini, destination: .aiPolish, dictionaryTab: nil,
      visibility: .providerSelected, target: .aiPolishWhyUseS1Mini, fallbacks: [.aiPolishProvider, .enableAIPolish]),
    SettingsMapNode(
      id: .aiPolishWhyUseAppleIntelligence, structure: .item, item: .feature,
      title: .resource(SettingsItemCopy.AIPolish.whyAppleIntelligence),
      parent: .aiPolishProviderAppleIntelligence, destination: .aiPolish, dictionaryTab: nil,
      visibility: .providerSelected, target: .aiPolishWhyUseAppleIntelligence, fallbacks: [.aiPolishProvider, .enableAIPolish]),
    SettingsMapNode(
      id: .aiPolishWhyUseOllama, structure: .item, item: .feature,
      title: .resource(SettingsItemCopy.AIPolish.whyOllama),
      parent: .aiPolishProviderOllama, destination: .aiPolish, dictionaryTab: nil,
      visibility: .providerSelected, target: .aiPolishWhyUseOllama, fallbacks: [.aiPolishProvider, .enableAIPolish]),
    SettingsMapNode(
      id: .aiPolishWhyUseOpenAI, structure: .item, item: .feature,
      title: .resource(SettingsItemCopy.AIPolish.whyOpenAI),
      parent: .aiPolishProviderOpenAI, destination: .aiPolish, dictionaryTab: nil,
      visibility: .providerSelected, target: .aiPolishWhyUseOpenAI, fallbacks: [.aiPolishProvider, .enableAIPolish]),
    SettingsMapNode(
      id: .aiPolishWhyUseGemini, structure: .item, item: .feature,
      title: .resource(SettingsItemCopy.AIPolish.whyGemini),
      parent: .aiPolishProviderGemini, destination: .aiPolish, dictionaryTab: nil,
      visibility: .providerSelected, target: .aiPolishWhyUseGemini, fallbacks: [.aiPolishProvider, .enableAIPolish]),
    SettingsMapNode(
      id: .aiPolishWhyUseClaude, structure: .item, item: .feature,
      title: .resource(SettingsItemCopy.AIPolish.whyClaude),
      parent: .aiPolishProviderClaude, destination: .aiPolish, dictionaryTab: nil,
      visibility: .providerSelected, target: .aiPolishWhyUseClaude, fallbacks: [.aiPolishProvider, .enableAIPolish]),
    SettingsMapNode(
      id: .aiPolishLinkAboutAppleIntelligence, structure: .item, item: .action,
      title: .resource(SettingsItemCopy.AIPolish.aboutAppleIntelligence),
      parent: .aiPolishWhyUseAppleIntelligence, destination: .aiPolish, dictionaryTab: nil,
      visibility: .providerSelected, target: .aiPolishWhyUseAppleIntelligence, fallbacks: [.aiPolishProvider, .enableAIPolish]),
    SettingsMapNode(
      id: .aiPolishLinkOllamaLibrary, structure: .item, item: .action,
      title: .resource(SettingsItemCopy.AIPolish.ollamaLibrary),
      parent: .aiPolishWhyUseOllama, destination: .aiPolish, dictionaryTab: nil,
      visibility: .providerSelected, target: .aiPolishWhyUseOllama, fallbacks: [.aiPolishProvider, .enableAIPolish]),
    SettingsMapNode(
      id: .aiPolishLinkOpenAIRateLimits, structure: .item, item: .action,
      title: .resource(SettingsItemCopy.AIPolish.openAIRateLimits),
      parent: .aiPolishWhyUseOpenAI, destination: .aiPolish, dictionaryTab: nil,
      visibility: .providerSelected, target: .aiPolishWhyUseOpenAI, fallbacks: [.aiPolishProvider, .enableAIPolish]),
    SettingsMapNode(
      id: .aiPolishLinkGeminiRateLimits, structure: .item, item: .action,
      title: .resource(SettingsItemCopy.AIPolish.geminiRateLimits),
      parent: .aiPolishWhyUseGemini, destination: .aiPolish, dictionaryTab: nil,
      visibility: .providerSelected, target: .aiPolishWhyUseGemini, fallbacks: [.aiPolishProvider, .enableAIPolish]),
    SettingsMapNode(
      id: .aiPolishLinkClaudeRateLimits, structure: .item, item: .action,
      title: .resource(SettingsItemCopy.AIPolish.claudeRateLimits),
      parent: .aiPolishWhyUseClaude, destination: .aiPolish, dictionaryTab: nil,
      visibility: .providerSelected, target: .aiPolishWhyUseClaude, fallbacks: [.aiPolishProvider, .enableAIPolish]),
    SettingsMapNode(
      id: .localModelDownload, structure: .item, item: .action,
      title: .dynamic(.localModelPrimaryAction),
      parent: .pageAiPolish, destination: .aiPolish, dictionaryTab: nil,
      visibility: .providerSetupState, target: .localModelDownload, fallbacks: [.aiPolishProvider, .enableAIPolish]),
    SettingsMapNode(
      id: .localModelCancel, structure: .item, item: .action,
      title: .dynamic(.localModelPrimaryAction),
      parent: .pageAiPolish, destination: .aiPolish, dictionaryTab: nil,
      visibility: .providerSetupState, target: .localModelCancel, fallbacks: [.aiPolishProvider, .enableAIPolish]),
    SettingsMapNode(
      id: .localModelResume, structure: .item, item: .action,
      title: .dynamic(.localModelPrimaryAction),
      parent: .pageAiPolish, destination: .aiPolish, dictionaryTab: nil,
      visibility: .providerSetupState, target: .localModelResume, fallbacks: [.aiPolishProvider, .enableAIPolish]),
    SettingsMapNode(
      id: .localModelResumeUpgrade, structure: .item, item: .action,
      title: .dynamic(.localModelPrimaryAction),
      parent: .pageAiPolish, destination: .aiPolish, dictionaryTab: nil,
      visibility: .providerSetupState, target: .aiPolishProvider, fallbacks: [.aiPolishProvider, .enableAIPolish]),
    SettingsMapNode(
      id: .localModelFinishUpgrade, structure: .item, item: .action,
      title: .dynamic(.localModelPrimaryAction),
      parent: .pageAiPolish, destination: .aiPolish, dictionaryTab: nil,
      visibility: .providerSetupState, target: .aiPolishProvider, fallbacks: [.aiPolishProvider, .enableAIPolish]),
    SettingsMapNode(
      id: .localModelTryAgain, structure: .item, item: .action,
      title: .dynamic(.localModelPrimaryAction),
      parent: .pageAiPolish, destination: .aiPolish, dictionaryTab: nil,
      visibility: .providerSetupState, target: .localModelTryAgain, fallbacks: [.aiPolishProvider, .enableAIPolish]),
    SettingsMapNode(
      id: .localModelTestLive, structure: .item, item: .action,
      title: .dynamic(.localModelTest),
      parent: .pageAiPolish, destination: .aiPolish, dictionaryTab: nil,
      visibility: .providerSetupState, target: .localModelTestLive, fallbacks: [.aiPolishProvider, .enableAIPolish]),
    SettingsMapNode(
      id: .s1Tone, structure: .item, item: .setting,
      title: .resource(S1ControlCopy.stylingLabelResource),
      parent: .pageAiPolish, destination: .aiPolish, dictionaryTab: nil,
      visibility: .providerSelected, target: .s1Tone, fallbacks: [.aiPolishProvider, .enableAIPolish]),
    SettingsMapNode(
      id: .s1ToneCasual, structure: .item, item: .choice,
      title: .resource(S1ControlCopy.labelResource(for: S1Styling.casual)),
      parent: .s1Tone, destination: .aiPolish, dictionaryTab: nil,
      visibility: .providerSelected, target: .s1Tone, fallbacks: [.aiPolishProvider, .enableAIPolish]),
    SettingsMapNode(
      id: .s1ToneSemiCasual, structure: .item, item: .choice,
      title: .resource(S1ControlCopy.labelResource(for: S1Styling.semiCasual)),
      parent: .s1Tone, destination: .aiPolish, dictionaryTab: nil,
      visibility: .providerSelected, target: .s1Tone, fallbacks: [.aiPolishProvider, .enableAIPolish]),
    SettingsMapNode(
      id: .s1ToneSemiFormal, structure: .item, item: .choice,
      title: .resource(S1ControlCopy.labelResource(for: S1Styling.semiFormal)),
      parent: .s1Tone, destination: .aiPolish, dictionaryTab: nil,
      visibility: .providerSelected, target: .s1Tone, fallbacks: [.aiPolishProvider, .enableAIPolish]),
    SettingsMapNode(
      id: .s1ToneFormal, structure: .item, item: .choice,
      title: .resource(S1ControlCopy.labelResource(for: S1Styling.formal)),
      parent: .s1Tone, destination: .aiPolish, dictionaryTab: nil,
      visibility: .providerSelected, target: .s1Tone, fallbacks: [.aiPolishProvider, .enableAIPolish]),
    SettingsMapNode(
      id: .s1Structure, structure: .item, item: .setting,
      title: .resource(S1ControlCopy.structureLabelResource),
      parent: .pageAiPolish, destination: .aiPolish, dictionaryTab: nil,
      visibility: .providerSelected, target: .s1Structure, fallbacks: [.aiPolishProvider, .enableAIPolish]),
    SettingsMapNode(
      id: .s1StructureProse, structure: .item, item: .choice,
      title: .resource(S1ControlCopy.labelResource(for: S1Structure.prose)),
      parent: .s1Structure, destination: .aiPolish, dictionaryTab: nil,
      visibility: .providerSelected, target: .s1Structure, fallbacks: [.aiPolishProvider, .enableAIPolish]),
    SettingsMapNode(
      id: .s1StructureLists, structure: .item, item: .choice,
      title: .resource(S1ControlCopy.labelResource(for: S1Structure.lists)),
      parent: .s1Structure, destination: .aiPolish, dictionaryTab: nil,
      visibility: .providerSelected, target: .s1Structure, fallbacks: [.aiPolishProvider, .enableAIPolish]),
    SettingsMapNode(
      id: .s1Context, structure: .item, item: .setting,
      title: .resource(S1ControlCopy.contextLabelResource),
      parent: .pageAiPolish, destination: .aiPolish, dictionaryTab: nil,
      visibility: .providerSelected, target: .s1Context, fallbacks: [.aiPolishProvider, .enableAIPolish]),
    SettingsMapNode(
      id: .s1ContextGeneral, structure: .item, item: .choice,
      title: .resource(S1ControlCopy.labelResource(for: S1Context.general)),
      parent: .s1Context, destination: .aiPolish, dictionaryTab: nil,
      visibility: .providerSelected, target: .s1Context, fallbacks: [.aiPolishProvider, .enableAIPolish]),
    SettingsMapNode(
      id: .s1ContextEmail, structure: .item, item: .choice,
      title: .resource(S1ControlCopy.labelResource(for: S1Context.email)),
      parent: .s1Context, destination: .aiPolish, dictionaryTab: nil,
      visibility: .providerSelected, target: .s1Context, fallbacks: [.aiPolishProvider, .enableAIPolish]),
    SettingsMapNode(
      id: .appleIntelligenceStatus, structure: .item, item: .feature,
      title: .dynamic(.appleIntelligenceStatus),
      parent: .aiPolishProviderAppleIntelligence, destination: .aiPolish, dictionaryTab: nil,
      visibility: .providerSetupState, target: .appleIntelligenceStatus, fallbacks: [.aiPolishProvider, .enableAIPolish]),
    SettingsMapNode(
      id: .appleIntelligenceRecheck, structure: .item, item: .action,
      title: .resource(SettingsItemCopy.AIPolish.appleRecheck),
      parent: .appleIntelligenceStatus, destination: .aiPolish, dictionaryTab: nil,
      visibility: .providerSetupState, target: .appleIntelligenceRecheck, fallbacks: [.aiPolishProvider, .enableAIPolish]),
    SettingsMapNode(
      id: .ollamaDownloadOllama, structure: .item, item: .action,
      title: .resource(SettingsItemCopy.AIPolish.downloadOllama),
      parent: .aiPolishProviderOllama, destination: .aiPolish, dictionaryTab: nil,
      visibility: .providerSetupState, target: .ollamaDownloadOllama, fallbacks: [.aiPolishProvider, .enableAIPolish]),
    SettingsMapNode(
      id: .ollamaStart, structure: .item, item: .action,
      title: .resource(SettingsItemCopy.AIPolish.startOllama),
      parent: .aiPolishProviderOllama, destination: .aiPolish, dictionaryTab: nil,
      visibility: .providerSetupState, target: .ollamaStart, fallbacks: [.aiPolishProvider, .enableAIPolish]),
    SettingsMapNode(
      id: .ollamaDownloadModel, structure: .item, item: .action,
      title: .dynamic(.ollamaModelDownload),
      parent: .aiPolishProviderOllama, destination: .aiPolish, dictionaryTab: nil,
      visibility: .providerSetupState, target: .ollamaDownloadModel, fallbacks: [.aiPolishProvider, .enableAIPolish]),
    SettingsMapNode(
      id: .ollamaCancelPull, structure: .item, item: .action,
      title: .resource(SettingsItemCopy.AIPolish.ollamaCancel),
      parent: .aiPolishProviderOllama, destination: .aiPolish, dictionaryTab: nil,
      visibility: .providerSetupState, target: .ollamaCancelPull, fallbacks: [.aiPolishProvider, .enableAIPolish]),
    SettingsMapNode(
      id: .ollamaServer, structure: .item, item: .feature,
      title: .resource(SettingsItemCopy.AIPolish.ollamaServer),
      parent: .aiPolishProviderOllama, destination: .aiPolish, dictionaryTab: nil,
      visibility: .providerSetupState, target: .ollamaServer, fallbacks: [.aiPolishProvider, .enableAIPolish]),
    SettingsMapNode(
      id: .ollamaRecheck, structure: .item, item: .action,
      title: .resource(SettingsItemCopy.AIPolish.ollamaRecheck),
      parent: .aiPolishProviderOllama, destination: .aiPolish, dictionaryTab: nil,
      visibility: .providerSetupState, target: .ollamaRecheck, fallbacks: [.aiPolishProvider, .enableAIPolish]),
    SettingsMapNode(
      id: .ollamaTryAgain, structure: .item, item: .action,
      title: .resource(SettingsItemCopy.AIPolish.ollamaTryAgain),
      parent: .aiPolishProviderOllama, destination: .aiPolish, dictionaryTab: nil,
      visibility: .providerSetupState, target: .ollamaTryAgain, fallbacks: [.aiPolishProvider, .enableAIPolish]),
    SettingsMapNode(
      id: .ollamaBrowseModels, structure: .item, item: .action,
      title: .resource(SettingsItemCopy.AIPolish.ollamaBrowseModels),
      parent: .aiPolishProviderOllama, destination: .aiPolish, dictionaryTab: nil,
      visibility: .providerSetupState, target: .ollamaBrowseModels, fallbacks: [.aiPolishProvider, .enableAIPolish]),
    SettingsMapNode(
      id: .ollamaPrepareModel, structure: .item, item: .action,
      title: .resource(SettingsItemCopy.AIPolish.ollamaPrepareModel),
      parent: .polishModel, destination: .aiPolish, dictionaryTab: nil,
      visibility: .providerSetupState, target: .ollamaPrepareModel, fallbacks: [.aiPolishProvider, .enableAIPolish]),
    SettingsMapNode(
      id: .apiKeyOpenAI, structure: .item, item: .setting,
      title: .resource(SettingsItemCopy.AIPolish.openAIKey),
      parent: .pageAiPolish, destination: .aiPolish, dictionaryTab: nil,
      visibility: .apiKeyProvider, target: .apiKeyOpenAI, fallbacks: [.aiPolishProvider, .enableAIPolish]),
    SettingsMapNode(
      id: .apiKeyGemini, structure: .item, item: .setting,
      title: .resource(SettingsItemCopy.AIPolish.geminiKey),
      parent: .pageAiPolish, destination: .aiPolish, dictionaryTab: nil,
      visibility: .apiKeyProvider, target: .apiKeyGemini, fallbacks: [.aiPolishProvider, .enableAIPolish]),
    SettingsMapNode(
      id: .apiKeyClaude, structure: .item, item: .setting,
      title: .resource(SettingsItemCopy.AIPolish.claudeKey),
      parent: .pageAiPolish, destination: .aiPolish, dictionaryTab: nil,
      visibility: .apiKeyProvider, target: .apiKeyClaude, fallbacks: [.aiPolishProvider, .enableAIPolish]),
    SettingsMapNode(
      id: .apiKeySave, structure: .item, item: .action,
      title: .resource(SettingsItemCopy.AIPolish.keySave),
      parent: .pageAiPolish, destination: .aiPolish, dictionaryTab: nil,
      visibility: .apiKeyProvider, target: .apiKeySave, fallbacks: [.aiPolishProvider, .enableAIPolish]),
    SettingsMapNode(
      id: .apiKeyClear, structure: .item, item: .action,
      title: .resource(SettingsItemCopy.AIPolish.keyClear),
      parent: .pageAiPolish, destination: .aiPolish, dictionaryTab: nil,
      visibility: .apiKeySaved, target: .apiKeyClear, fallbacks: [.aiPolishProvider, .enableAIPolish]),
    SettingsMapNode(
      id: .apiKeyReveal, structure: .item, item: .action,
      title: .dynamic(.apiKeyReveal),
      parent: .pageAiPolish, destination: .aiPolish, dictionaryTab: nil,
      visibility: .apiKeySaved, target: .apiKeyReveal, fallbacks: [.aiPolishProvider, .enableAIPolish]),
    SettingsMapNode(
      id: .apiKeyGetKeyLink, structure: .item, item: .action,
      title: .dynamic(.apiKeyLink),
      parent: .pageAiPolish, destination: .aiPolish, dictionaryTab: nil,
      visibility: .apiKeyProvider, target: .apiKeyGetKeyLink, fallbacks: [.aiPolishProvider, .enableAIPolish]),
    SettingsMapNode(
      id: .polishModel, structure: .item, item: .setting,
      title: .resource(SettingsItemCopy.AIPolish.model),
      parent: .pageAiPolish, destination: .aiPolish, dictionaryTab: nil,
      visibility: .providerSelected, target: .polishModel, fallbacks: [.aiPolishProvider, .enableAIPolish]),
    SettingsMapNode(
      id: .polishModelRefresh, structure: .item, item: .action,
      title: .resource(SettingsItemCopy.AIPolish.refreshModels),
      parent: .polishModel, destination: .aiPolish, dictionaryTab: nil,
      visibility: .providerSelected, target: .polishModelRefresh, fallbacks: [.aiPolishProvider, .enableAIPolish]),
    SettingsMapNode(
      id: .enableDictionary, structure: .item, item: .setting,
      title: .resource(SettingsShellCopy.Dictionary.enableTitle),
      parent: .pageDictionary, destination: .dictionary, dictionaryTab: nil,
      visibility: .always, target: .enableDictionary, fallbacks: []),
    SettingsMapNode(
      id: .dictionaryTabYourWords, structure: .tab, item: .feature,
      title: .resource(DictionaryTab.yourWords.labelResource),
      parent: .pageDictionary, destination: .dictionary, dictionaryTab: .yourWords,
      visibility: .always, target: .dictionaryTabYourWords, fallbacks: []),
    SettingsMapNode(
      id: .dictionaryTabVocabularyPacks, structure: .tab, item: .feature,
      title: .resource(DictionaryTab.vocabularyPacks.labelResource),
      parent: .pageDictionary, destination: .dictionary, dictionaryTab: .vocabularyPacks,
      visibility: .always, target: .dictionaryTabVocabularyPacks, fallbacks: []),
    SettingsMapNode(
      id: .dictionaryTabLearnFrom, structure: .tab, item: .feature,
      title: .resource(DictionaryTab.learnFrom.labelResource),
      parent: .pageDictionary, destination: .dictionary, dictionaryTab: .learnFrom,
      visibility: .always, target: .dictionaryTabLearnFrom, fallbacks: []),
    SettingsMapNode(
      id: .dictionaryTabQuickAdd, structure: .tab, item: .feature,
      title: .resource(DictionaryTab.quickAdd.labelResource),
      parent: .pageDictionary, destination: .dictionary, dictionaryTab: .quickAdd,
      visibility: .always, target: .dictionaryTabQuickAdd, fallbacks: []),
    SettingsMapNode(
      id: .yourWordsAdd, structure: .item, item: .action,
      title: .resource(SettingsItemCopy.Dictionary.addWord),
      parent: .pageDictionary, destination: .dictionary, dictionaryTab: .yourWords,
      visibility: .always, target: .yourWordsAdd, fallbacks: []),
    SettingsMapNode(
      id: .yourWordsImport, structure: .item, item: .action,
      title: .resource(SettingsItemCopy.Dictionary.importWords),
      parent: .pageDictionary, destination: .dictionary, dictionaryTab: .yourWords,
      visibility: .always, target: .yourWordsImport, fallbacks: []),
    SettingsMapNode(
      id: .yourWordsExport, structure: .item, item: .action,
      title: .resource(SettingsItemCopy.Dictionary.exportWords),
      parent: .pageDictionary, destination: .dictionary, dictionaryTab: .yourWords,
      visibility: .always, target: .yourWordsExport, fallbacks: []),
    SettingsMapNode(
      id: .yourWordsSearch, structure: .item, item: .setting,
      title: .resource(SettingsItemCopy.Dictionary.searchWords),
      parent: .pageDictionary, destination: .dictionary, dictionaryTab: .yourWords,
      visibility: .always, target: .yourWordsSearch, fallbacks: []),
    SettingsMapNode(
      id: .yourWordsClearSearch, structure: .item, item: .action,
      title: .resource(SettingsItemCopy.Dictionary.clearSearch),
      parent: .yourWordsSearch, destination: .dictionary, dictionaryTab: .yourWords,
      visibility: .searchHasQuery, target: .yourWordsClearSearch, fallbacks: []),
    SettingsMapNode(
      id: .yourWordsCategoryFilter, structure: .item, item: .setting,
      title: .resource(SettingsItemCopy.Dictionary.allCategories),
      parent: .pageDictionary, destination: .dictionary, dictionaryTab: .yourWords,
      visibility: .always, target: .yourWordsCategoryFilter, fallbacks: []),
    SettingsMapNode(
      id: .yourWordsCategoryAll, structure: .item, item: .choice,
      title: .resource(SettingsItemCopy.Dictionary.allCategories),
      parent: .yourWordsCategoryFilter, destination: .dictionary, dictionaryTab: .yourWords,
      visibility: .always, target: .yourWordsCategoryFilter, fallbacks: []),
    SettingsMapNode(
      id: .yourWordsCategoryGeneral, structure: .item, item: .choice,
      title: .resource(WordCategory.general.displayNameResource),
      parent: .yourWordsCategoryFilter, destination: .dictionary, dictionaryTab: .yourWords,
      visibility: .always, target: .yourWordsCategoryFilter, fallbacks: []),
    SettingsMapNode(
      id: .yourWordsCategoryPerson, structure: .item, item: .choice,
      title: .resource(WordCategory.person.displayNameResource),
      parent: .yourWordsCategoryFilter, destination: .dictionary, dictionaryTab: .yourWords,
      visibility: .always, target: .yourWordsCategoryFilter, fallbacks: []),
    SettingsMapNode(
      id: .yourWordsCategoryBrand, structure: .item, item: .choice,
      title: .resource(WordCategory.brand.displayNameResource),
      parent: .yourWordsCategoryFilter, destination: .dictionary, dictionaryTab: .yourWords,
      visibility: .always, target: .yourWordsCategoryFilter, fallbacks: []),
    SettingsMapNode(
      id: .yourWordsCategoryAcronym, structure: .item, item: .choice,
      title: .resource(WordCategory.acronym.displayNameResource),
      parent: .yourWordsCategoryFilter, destination: .dictionary, dictionaryTab: .yourWords,
      visibility: .always, target: .yourWordsCategoryFilter, fallbacks: []),
    SettingsMapNode(
      id: .yourWordsCategoryDomain, structure: .item, item: .choice,
      title: .resource(WordCategory.domain.displayNameResource),
      parent: .yourWordsCategoryFilter, destination: .dictionary, dictionaryTab: .yourWords,
      visibility: .always, target: .yourWordsCategoryFilter, fallbacks: []),
    SettingsMapNode(
      id: .yourWordsCategoryAutoLearned, structure: .item, item: .choice,
      title: .resource(CustomTermProvenanceCopy.filterPillResource),
      parent: .yourWordsCategoryFilter, destination: .dictionary, dictionaryTab: .yourWords,
      visibility: .always, target: .yourWordsCategoryFilter, fallbacks: []),
    SettingsMapNode(
      id: .yourWordsMassEdit, structure: .item, item: .action,
      title: .resource(SettingsItemCopy.Dictionary.massEdit),
      parent: .pageDictionary, destination: .dictionary, dictionaryTab: .yourWords,
      visibility: .wordsListed, target: .yourWordsMassEdit, fallbacks: []),
    SettingsMapNode(
      id: .learnFrom, structure: .item, item: .feature,
      title: .resource(SettingsItemCopy.Dictionary.learnFromPanel),
      parent: .pageDictionary, destination: .dictionary, dictionaryTab: .learnFrom,
      visibility: .always, target: .learnFrom, fallbacks: []),
    SettingsMapNode(
      id: .selfLearningDictionary, structure: .item, item: .setting,
      title: .resource(LearnFromEditsSettingsPresentation.rowTitleResource),
      parent: .pageDictionary, destination: .dictionary, dictionaryTab: .learnFrom,
      visibility: .always, target: .selfLearningDictionary, fallbacks: []),
    SettingsMapNode(
      id: .selfLearningDictionaryLearnMore, structure: .item, item: .action,
      title: .resource(LearnFromEditsSettingsPresentation.learnMoreLabelResource),
      parent: .selfLearningDictionary, destination: .dictionary, dictionaryTab: .learnFrom,
      visibility: .always, target: .selfLearningDictionaryLearnMore, fallbacks: []),
    SettingsMapNode(
      id: .importContacts, structure: .item, item: .feature,
      title: .resource(SettingsItemCopy.Dictionary.importContacts),
      parent: .pageDictionary, destination: .dictionary, dictionaryTab: .learnFrom,
      visibility: .always, target: .importContacts, fallbacks: []),
    SettingsMapNode(
      id: .contactsSyncOnLaunch, structure: .item, item: .setting,
      title: .resource(SettingsItemCopy.Dictionary.syncOnLaunch),
      parent: .importContacts, destination: .dictionary, dictionaryTab: .learnFrom,
      visibility: .always, target: .contactsSyncOnLaunch, fallbacks: []),
    SettingsMapNode(
      id: .quickAddStep1, structure: .item, item: .feature,
      title: .resource(SettingsItemCopy.Dictionary.quickAddStep1),
      parent: .pageDictionary, destination: .dictionary, dictionaryTab: .quickAdd,
      visibility: .always, target: .quickAddStep1, fallbacks: []),
    SettingsMapNode(
      id: .quickAddStep2, structure: .item, item: .feature,
      title: .resource(SettingsItemCopy.Dictionary.quickAddStep2),
      parent: .pageDictionary, destination: .dictionary, dictionaryTab: .quickAdd,
      visibility: .always, target: .quickAddStep2, fallbacks: []),
    SettingsMapNode(
      id: .quickAddStep3, structure: .item, item: .feature,
      title: .resource(SettingsItemCopy.Dictionary.quickAddStep3),
      parent: .pageDictionary, destination: .dictionary, dictionaryTab: .quickAdd,
      visibility: .always, target: .quickAddStep3, fallbacks: []),
    SettingsMapNode(
      id: .quickAddShortcut, structure: .item, item: .action,
      title: .resource(SettingsItemCopy.Dictionary.quickAddShortcut),
      parent: .pageDictionary, destination: .dictionary, dictionaryTab: .quickAdd,
      visibility: .always, target: .quickAddShortcut, fallbacks: []),
    SettingsMapNode(
      id: .quickAddMenuBar, structure: .item, item: .feature,
      title: .resource(SettingsItemCopy.Dictionary.quickAddMenuBar),
      parent: .pageDictionary, destination: .dictionary, dictionaryTab: .quickAdd,
      visibility: .always, target: .quickAddMenuBar, fallbacks: []),
    SettingsMapNode(
      id: .snippets, structure: .item, item: .feature,
      title: .resource(SnippetsSettingsCopy.headline),
      parent: .pageSnippets, destination: .snippets, dictionaryTab: nil,
      visibility: .always, target: .snippets, fallbacks: []),
    SettingsMapNode(
      id: .snippetKeyword, structure: .item, item: .setting,
      title: .resource(SettingsItemCopy.Snippets.keyword),
      parent: .pageSnippets, destination: .snippets, dictionaryTab: nil,
      visibility: .always, target: .snippetKeyword, fallbacks: []),
    SettingsMapNode(
      id: .yourSnippets, structure: .item, item: .feature,
      title: .resource(SettingsItemCopy.Snippets.yourSnippets),
      parent: .pageSnippets, destination: .snippets, dictionaryTab: nil,
      visibility: .always, target: .yourSnippets, fallbacks: []),
    SettingsMapNode(
      id: .snippetsSearch, structure: .item, item: .setting,
      title: .resource(SettingsItemCopy.Snippets.search),
      parent: .pageSnippets, destination: .snippets, dictionaryTab: nil,
      visibility: .always, target: .snippetsSearch, fallbacks: []),
    SettingsMapNode(
      id: .snippetsImport, structure: .item, item: .action,
      title: .resource(SettingsItemCopy.Snippets.importSnippets),
      parent: .pageSnippets, destination: .snippets, dictionaryTab: nil,
      visibility: .always, target: .snippetsImport, fallbacks: []),
    SettingsMapNode(
      id: .snippetsExport, structure: .item, item: .action,
      title: .resource(SettingsItemCopy.Snippets.exportSnippets),
      parent: .pageSnippets, destination: .snippets, dictionaryTab: nil,
      visibility: .always, target: .snippetsExport, fallbacks: []),
    SettingsMapNode(
      id: .snippetsAdd, structure: .item, item: .action,
      title: .resource(SettingsItemCopy.Snippets.add),
      parent: .pageSnippets, destination: .snippets, dictionaryTab: nil,
      visibility: .always, target: .snippetsAdd, fallbacks: []),
    SettingsMapNode(
      id: .snippetsAddFirst, structure: .item, item: .action,
      title: .resource(SettingsItemCopy.Snippets.addFirst),
      parent: .pageSnippets, destination: .snippets, dictionaryTab: nil,
      visibility: .snippetsEmpty, target: .snippetsAddFirst, fallbacks: []),
    SettingsMapNode(
      id: .snippetsClearSearch, structure: .item, item: .action,
      title: .resource(SettingsItemCopy.Snippets.clearSearch),
      parent: .snippetsSearch, destination: .snippets, dictionaryTab: nil,
      visibility: .searchHasQuery, target: .snippetsClearSearch, fallbacks: []),
    SettingsMapNode(
      id: .appSettingsTabAppearance, structure: .tab, item: .feature,
      title: .resource(AppSettingsTab.appearance.label),
      parent: .pageAppSettings, destination: .appSettings(.appearance), dictionaryTab: nil,
      visibility: .always, target: .appSettingsTabAppearance, fallbacks: []),
    SettingsMapNode(
      id: .appSettingsTabPermissions, structure: .tab, item: .feature,
      title: .resource(AppSettingsTab.permissions.label),
      parent: .pageAppSettings, destination: .appSettings(.permissions), dictionaryTab: nil,
      visibility: .always, target: .appSettingsTabPermissions, fallbacks: []),
    SettingsMapNode(
      id: .appSettingsTabPrivacy, structure: .tab, item: .feature,
      title: .resource(AppSettingsTab.privacy.label),
      parent: .pageAppSettings, destination: .appSettings(.privacy), dictionaryTab: nil,
      visibility: .always, target: .appSettingsTabPrivacy, fallbacks: []),
    SettingsMapNode(
      id: .appSettingsTabLicenses, structure: .tab, item: .feature,
      title: .resource(AppSettingsTab.licenses.label),
      parent: .pageAppSettings, destination: .appSettings(.licenses), dictionaryTab: nil,
      visibility: .always, target: .appSettingsTabLicenses, fallbacks: []),
    SettingsMapNode(
      id: .theme, structure: .item, item: .setting,
      title: .resource(SettingsItemCopy.AppSettings.theme),
      parent: .pageAppSettings, destination: .appSettings(.appearance), dictionaryTab: nil,
      visibility: .always, target: .theme, fallbacks: []),
    SettingsMapNode(
      id: .themeSystem, structure: .item, item: .choice,
      title: .resource(ThemeChoicePresentation.choices[0].label),
      parent: .theme, destination: .appSettings(.appearance), dictionaryTab: nil,
      visibility: .always, target: .theme, fallbacks: []),
    SettingsMapNode(
      id: .themeLight, structure: .item, item: .choice,
      title: .resource(ThemeChoicePresentation.choices[1].label),
      parent: .theme, destination: .appSettings(.appearance), dictionaryTab: nil,
      visibility: .always, target: .theme, fallbacks: []),
    SettingsMapNode(
      id: .themeDark, structure: .item, item: .choice,
      title: .resource(ThemeChoicePresentation.choices[2].label),
      parent: .theme, destination: .appSettings(.appearance), dictionaryTab: nil,
      visibility: .always, target: .theme, fallbacks: []),
    SettingsMapNode(
      id: .appLanguage, structure: .item, item: .setting,
      title: .resource(SettingsItemCopy.AppSettings.language),
      parent: .pageAppSettings, destination: .appSettings(.appearance), dictionaryTab: nil,
      visibility: .always, target: .appLanguage, fallbacks: []),
    SettingsMapNode(
      id: .appLanguageSystemDefault, structure: .item, item: .choice,
      title: .resource(SettingsItemCopy.AppSettings.systemDefault),
      parent: .appLanguage, destination: .appSettings(.appearance), dictionaryTab: nil,
      visibility: .always, target: .appLanguage, fallbacks: []),
    SettingsMapNode(
      id: .appLanguageShipped, structure: .item, item: .choice,
      title: .dynamic(.appLanguageName),
      parent: .appLanguage, destination: .appSettings(.appearance), dictionaryTab: nil,
      visibility: .always, target: .appLanguage, fallbacks: []),
    SettingsMapNode(
      id: .appLanguageRelaunch, structure: .item, item: .action,
      title: .resource(SettingsItemCopy.AppSettings.relaunch),
      parent: .appLanguage, destination: .appSettings(.appearance), dictionaryTab: nil,
      visibility: .relaunchNeeded, target: .appLanguageRelaunch, fallbacks: []),
    SettingsMapNode(
      id: .showInDock, structure: .item, item: .setting,
      title: .resource(SettingsItemCopy.AppSettings.showInDock),
      parent: .pageAppSettings, destination: .appSettings(.appearance), dictionaryTab: nil,
      visibility: .always, target: .showInDock, fallbacks: []),
    SettingsMapNode(
      id: .updateAlertInMenuBar, structure: .item, item: .setting,
      title: .resource(SettingsItemCopy.AppSettings.updateAlert),
      parent: .pageAppSettings, destination: .appSettings(.appearance), dictionaryTab: nil,
      visibility: .always, target: .updateAlertInMenuBar, fallbacks: []),
    SettingsMapNode(
      id: .permissionMicrophone, structure: .item, item: .feature,
      title: .resource(SettingsItemCopy.AppSettings.microphonePermission),
      parent: .pageAppSettings, destination: .appSettings(.permissions), dictionaryTab: nil,
      visibility: .always, target: .permissionMicrophone, fallbacks: []),
    SettingsMapNode(
      id: .permissionMicrophoneRequest, structure: .item, item: .action,
      title: .resource(SettingsItemCopy.AppSettings.requestAccess),
      parent: .permissionMicrophone, destination: .appSettings(.permissions), dictionaryTab: nil,
      visibility: .permissionState, target: .permissionMicrophoneRequest, fallbacks: []),
    SettingsMapNode(
      id: .permissionAccessibility, structure: .item, item: .feature,
      title: .resource(SettingsItemCopy.AppSettings.accessibilityPermission),
      parent: .pageAppSettings, destination: .appSettings(.permissions), dictionaryTab: nil,
      visibility: .always, target: .permissionAccessibility, fallbacks: []),
    SettingsMapNode(
      id: .permissionAccessibilityOpenSettings, structure: .item, item: .action,
      title: .resource(SettingsItemCopy.AppSettings.openSystemSettings),
      parent: .permissionAccessibility, destination: .appSettings(.permissions), dictionaryTab: nil,
      visibility: .permissionState, target: .permissionAccessibilityOpenSettings, fallbacks: []),
    SettingsMapNode(
      id: .shareUsageMetrics, structure: .item, item: .setting,
      title: .resource(PrivacySettingsCopy.metricsLabelResource),
      parent: .pageAppSettings, destination: .appSettings(.privacy), dictionaryTab: nil,
      visibility: .always, target: .shareUsageMetrics, fallbacks: []),
    SettingsMapNode(
      id: .sendCrashReports, structure: .item, item: .setting,
      title: .resource(PrivacySettingsCopy.crashLabelResource),
      parent: .pageAppSettings, destination: .appSettings(.privacy), dictionaryTab: nil,
      visibility: .always, target: .sendCrashReports, fallbacks: []),
    SettingsMapNode(
      id: .sendCrashReportsRestart, structure: .item, item: .action,
      title: .resource(PrivacySettingsCopy.restartActionResource),
      parent: .sendCrashReports, destination: .appSettings(.privacy), dictionaryTab: nil,
      visibility: .crashReportsChanged, target: .sendCrashReportsRestart, fallbacks: []),
    SettingsMapNode(
      id: .whatWeCollect, structure: .item, item: .feature,
      title: .resource(PrivacySettingsCopy.collectTitleResource),
      parent: .pageAppSettings, destination: .appSettings(.privacy), dictionaryTab: nil,
      visibility: .always, target: .whatWeCollect, fallbacks: []),
    SettingsMapNode(
      id: .whatWeCollectSeeDetails, structure: .item, item: .action,
      title: .resource(PrivacySettingsCopy.seeDetailsLabelResource),
      parent: .whatWeCollect, destination: .appSettings(.privacy), dictionaryTab: nil,
      visibility: .always, target: .whatWeCollectSeeDetails, fallbacks: []),
    SettingsMapNode(
      id: .licenseGpl, structure: .item, item: .feature,
      title: .resource(SettingsItemCopy.AppSettings.gplLicense),
      parent: .pageAppSettings, destination: .appSettings(.licenses), dictionaryTab: nil,
      visibility: .always, target: .licenseGpl, fallbacks: []),
    SettingsMapNode(
      id: .licenseGplView, structure: .item, item: .action,
      title: .resource(SettingsItemCopy.AppSettings.viewLicense),
      parent: .licenseGpl, destination: .appSettings(.licenses), dictionaryTab: nil,
      visibility: .always, target: .licenseGplView, fallbacks: []),
    SettingsMapNode(
      id: .licenseNotices, structure: .item, item: .feature,
      title: .resource(SettingsItemCopy.AppSettings.thirdPartyNotices),
      parent: .pageAppSettings, destination: .appSettings(.licenses), dictionaryTab: nil,
      visibility: .always, target: .licenseNotices, fallbacks: []),
    SettingsMapNode(
      id: .licenseNoticesView, structure: .item, item: .action,
      title: .resource(SettingsItemCopy.AppSettings.viewNotices),
      parent: .licenseNotices, destination: .appSettings(.licenses), dictionaryTab: nil,
      visibility: .always, target: .licenseNoticesView, fallbacks: []),
  ]

  /// Every node by id. Building it traps on a duplicate id, which the map tests also check.
  static let byID: [SettingsMapID: SettingsMapNode] = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) })

  static func node(_ id: SettingsMapID) -> SettingsMapNode {
    guard let node = byID[id] else { preconditionFailure("Settings Map has no node \(id.rawValue)") }
    return node
  }
}
