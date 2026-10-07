import SwiftUI

/// The App Settings tabs, in display order. Selection belongs to the window shell.
enum AppSettingsTab: String, CaseIterable, Hashable, Identifiable {
  case appearance
  case permissions
  case privacy
  case licenses

  var id: Self { self }

  /// The tab's Settings Map identity (#3482). Exhaustive, so a new tab must be given a node.
  var mapID: SettingsMapID {
    switch self {
    case .appearance: .appSettingsTabAppearance
    case .permissions: .appSettingsTabPermissions
    case .privacy: .appSettingsTabPrivacy
    case .licenses: .appSettingsTabLicenses
    }
  }

  var label: LocalizedStringResource {
    switch self {
    case .appearance: "Appearance"
    case .permissions: "Permissions"
    case .privacy: "Privacy"
    case .licenses: "Licenses"
    }
  }

  var icon: String {
    switch self {
    case .appearance: "circle.lefthalf.filled"
    case .permissions: "hand.raised"
    case .privacy: "lock.shield"
    case .licenses: "doc.text"
    }
  }
}
