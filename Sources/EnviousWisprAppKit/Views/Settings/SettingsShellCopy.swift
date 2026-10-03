import Foundation

/// Copy for the Settings window's frame (#3385): the Dictionary page's heading row, which
/// replaced its banner when page headers went away, and what a sidebar row says to VoiceOver.
enum SettingsShellCopy {
  enum Dictionary {
    static let heading = LocalizedStringResource(
      "Dictionary",
      comment: "Dictionary settings: section heading at the top of the page, shown in capitals.")
    static let enableTitle = LocalizedStringResource(
      "Enable Dictionary",
      comment: "Dictionary settings: the switch that turns Dictionary on or off.")
    static let enableShort = LocalizedStringResource(
      "Use your words and vocabulary to improve recognition.",
      comment: "Dictionary settings: short line under Enable Dictionary.")
    /// The sentence the page header showed under "Dictionary" before #3385, unchanged.
    static let enableHelp = LocalizedStringResource(
      "Improve recognition with your words and vocabulary.",
      comment: "Dictionary settings: explains Enable Dictionary.")
  }

  /// What a sidebar row is doing in the background, if anything. One value drives both the
  /// row's dot and the words VoiceOver says about it, so the two cannot disagree.
  enum SidebarActivity: Equatable {
    case none
    case dictionaryEnrichment
    case fileImport
  }

  static let dictionaryEnrichment = LocalizedStringResource(
    "Dictionary enrichment in progress",
    comment: "Settings sidebar, VoiceOver: Dictionary is still looking up words added in bulk.")
  static let fileImport = LocalizedStringResource(
    "Importing in progress", comment: "Settings sidebar: file import is running.")

  /// A sidebar row's accessibility value: "Selected" or "Not selected", then the activity.
  static func sidebarValue(isSelected: Bool, activity: SidebarActivity) -> String {
    let selection = isSelected ? SettingsCopy.selectedValue : SettingsCopy.notSelectedValue
    let detail: String
    switch activity {
    case .none: return selection
    case .dictionaryEnrichment: detail = String(localized: dictionaryEnrichment)
    case .fileImport: detail = String(localized: fileImport)
    }
    return String(
      localized: "\(selection). \(detail)",
      comment:
        "Settings sidebar, VoiceOver: a row's value. The first %@ is Selected or Not selected; the second says what is running on that page."
    )
  }
}
