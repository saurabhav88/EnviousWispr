import Foundation

/// What a Settings Map node is in the window's structure (#3482 plan §3.6).
enum SettingsMapStructure: Sendable {
  case window
  case page
  case tab
  case section
  case item
}

/// What a searchable item is, when the node is one. Structural nodes such as a tab can also be
/// searchable features.
enum SettingsMapItemKind: String, Sendable {
  case setting
  case choice
  case feature
  case action
}

/// Where a node's visible name comes from. Never an independently authored copy of a title the
/// interface already shows: a resource is the interface's own resource (same key, default value
/// and comment), a verbatim name is a shared product-name constant, and a dynamic name is
/// resolved by the interface's own resolver from typed runtime context.
enum SettingsMapTitle: Sendable {
  case resource(LocalizedStringResource)
  case verbatim(String)
  case dynamic(SettingsMapDynamicTitle)
}

/// The runtime-named nodes. Each case names one resolver; `SettingsMapTitleContext` carries its
/// inputs. The static map never stores a sampled runtime value.
enum SettingsMapDynamicTitle: Sendable {
  case currentEngineHeading
  case lockedLanguage
  case startWordLanguage
  case inputDeviceName
  case inputSocketOption
  case appLanguageName
  case previewLanguage
  case providerName
  case providerSection
  case localModelPrimaryAction
  case localModelTest
  case ollamaModelDownload
  case chimePreview
  case appleIntelligenceStatus
  case apiKeyReveal
  case apiKeyLink
  case transcribeFileStep
}

/// When a node's control is on screen. Named conditions only, so the render tests can put the
/// window in each state; `.always` controls are present whenever their destination is shown.
enum SettingsMapVisibility: Sendable {
  case always
  case engineChoicesExpanded
  case fastSelected
  case fastDeliveryAction
  case whisperSetupState
  case languageSectionAvailable
  case languageLocked
  case stopOnSilenceOn
  case spokenPunctuationOn
  case multiInputDevice
  case previewChoicesExpanded
  case universalSetupState
  case appleLanguagePacks
  case livePreviewOn
  case previewLanguageMissing
  case aiPolishEnabled
  case providerSelected
  case providerSetupState
  case apiKeyProvider
  case apiKeySaved
  case relaunchNeeded
  case permissionState
  case crashReportsChanged
  case snippetsEmpty
  case wordsListed
  case searchHasQuery
}

/// One node of the Settings Map.
struct SettingsMapNode: Sendable {
  let id: SettingsMapID
  let structure: SettingsMapStructure
  /// Set when the node is a searchable entry.
  let item: SettingsMapItemKind?
  let title: SettingsMapTitle
  let parent: SettingsMapID?
  /// The page (and Dictation or App tab) the node lives on.
  let destination: SettingsDestination?
  /// The Dictionary tab, for Dictionary nodes. PR A records it; selection stays where it is.
  let dictionaryTab: DictionaryTab?
  let visibility: SettingsMapVisibility
  /// The registered control an arrival points at: the node itself or its row or card. Every
  /// searchable entry has one; structural nodes need none.
  let target: SettingsMapID?
  /// Where an arrival goes, in order, when the target is not on screen.
  let fallbacks: [SettingsMapID]
}

/// Why a shared settings control deliberately has no Settings Map identity. Only reasons the
/// approved plan names (§3.4, §5); never "test", "legacy" or "not migrated yet".
enum SettingsMapExemption: String, Sendable {
  /// Transcribe a File: only the page and its fixed step bar are indexed; wizard controls are not.
  case transcribeFileWizard
  /// Vocabulary pack list and detail (plan §5).
  case vocabularyPackContent
  /// Learning setup actions such as model download and contacts import (plan §5).
  case learningSetupAction
  /// An individual snippet or other user record; its content is never indexed.
  case userContent
  /// A control inside a sheet or popover, which is not an arrival target (§3.4).
  case sheetOrPopoverContent
  /// A row that only reports state and offers no setting or action.
  case statusLine
  /// The bundled model's Remove action (plan §5).
  case bundledModelRemove
  /// The saved-key retry action (plan §5).
  case savedKeyRetry
  /// Test-host render fixtures only (catalog German in the English test host, layout stress
  /// strings). No shipped page may report it; SettingsMapRenderingTests fails if one does, and
  /// SettingsMapRegistrationTests forbids the fixture forms in shipped code.
  case renderFixture
}
