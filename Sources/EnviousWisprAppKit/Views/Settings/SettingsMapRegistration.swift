import EnviousWisprCore
import SwiftUI

/// One semantic control on screen, as the Settings Map sees it (#3482 plan §3.6 item 4): a
/// mapped identity, or an approved exemption. Render tests collect these independently of
/// arrival targets, so a control that never registers is caught by the inventory instead.
enum SettingsMapRegistration: Hashable, Sendable {
  case mapped(SettingsMapID)
  case exempt(SettingsMapExemption)
}

/// Collects every registration under a view. Appends, so a container never hides its children.
struct SettingsMapRegistrationKey: PreferenceKey {
  static let defaultValue: [SettingsMapRegistration] = []

  static func reduce(
    value: inout [SettingsMapRegistration], nextValue: () -> [SettingsMapRegistration]
  ) {
    value.append(contentsOf: nextValue())
  }
}

extension View {
  /// Registers this control with the Settings Map. A preference only: no layout, hit testing,
  /// accessibility or focus change.
  func settingsMapRegistration(_ id: SettingsMapID) -> some View {
    settingsMapRegistration(.mapped(id))
  }

  func settingsMapRegistration(_ registration: SettingsMapRegistration) -> some View {
    transformPreference(SettingsMapRegistrationKey.self) { $0.append(registration) }
  }

  /// Records that this control deliberately has no map identity, and why.
  /// Inside a region the map leaves out (for example a wizard step that reuses a settings
  /// card), every registration below counts as that exemption instead of its mapped identity.
  func settingsMapExemptScope(_ reason: SettingsMapExemption, when condition: Bool) -> some View {
    transformPreference(SettingsMapRegistrationKey.self) { value in
      if condition { value = value.map { _ in .exempt(reason) } }
    }
  }

  func settingsMapExemption(_ reason: SettingsMapExemption) -> some View {
    settingsMapRegistration(.exempt(reason))
  }
}

/// How a mapped control names itself: by id, or by id plus the typed runtime input its node's
/// resolver needs. The title always comes from the node; a control never supplies its own.
enum SettingsMapRef: Sendable {
  case id(SettingsMapID)
  case dynamic(SettingsMapID, SettingsMapTitleContext)

  var id: SettingsMapID {
    switch self {
    case .id(let id), .dynamic(let id, _): id
    }
  }

  /// The visible title, resolved through the node's own owner.
  var title: String { SettingsMap.title(of: self) }
}

/// Typed runtime inputs for the dynamic resolvers. Each case belongs to exactly one
/// `SettingsMapDynamicTitle`; `SettingsMap.title(of:)` traps on a mismatch.
enum SettingsMapTitleContext: Sendable {
  case currentEngine(EngineChoicePresentation.Choice)
  case lockedLanguage(code: String, spelling: EnglishSpelling)
  case appleIntelligenceStatus(unavailable: Bool)
  /// The Live Preview language catalog's load state, which renames the install row.
  case livePreviewPacks(loading: Bool, failed: Bool)
}

extension SettingsMap {
  /// The visible title for a reference. A static node ignores context; a dynamic node requires
  /// the context its resolver takes.
  static func title(of ref: SettingsMapRef) -> String {
    let node = node(ref.id)
    switch (node.title, ref) {
    case (.resource(let resource), .id):
      return String(localized: resource)
    case (.verbatim(let text), .id):
      return text
    case (.dynamic(.currentEngineHeading), .dynamic(_, .currentEngine(let choice))):
      let name = String(localized: choice.title)
      return String(
        localized: "\(name) · \(choice.model)",
        comment:
          "Speech engine settings: heading naming the current engine, then its model. Shown in capitals."
      ).uppercased()
    case (.dynamic(.lockedLanguage), .dynamic(_, .lockedLanguage(let code, let spelling))):
      return LanguageCatalog.lockDisplayName(
        for: LanguageCatalog.entry(forLockedCode: code, spelling: spelling))
    case (
      .dynamic(.appleIntelligenceStatus), .dynamic(_, .appleIntelligenceStatus(let unavailable))
    ):
      return unavailable
        ? String(
          localized: "Not available on this Mac",
          comment:
            "AI Polish, Apple Intelligence: the status row's title when this Mac reports it unavailable."
        )
        : String(
          localized: "Status", comment: "AI Polish, Apple Intelligence: the status row's title.")
    case (.resource(let resource), .dynamic(.previewLanguagesInstall, .livePreviewPacks(let loading, let failed))):
      if loading { return LivePreviewSettingsCopy.packsLoading }
      if failed { return LivePreviewSettingsCopy.packsUnavailable }
      return String(localized: resource)
    default:
      preconditionFailure(
        "Settings Map: \(ref.id.rawValue) was named with the wrong reference kind")
    }
  }
}
