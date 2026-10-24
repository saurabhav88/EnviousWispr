import SwiftUI

/// The EnviousMeet tabs (#4058), in display order. Selection belongs to the window shell.
enum MeetingsTab: String, CaseIterable, Hashable, Identifiable {
  case general
  case callApps
  case permissions

  var id: Self { self }

  /// The tab's Settings Map identity (#3482). Exhaustive, so a new tab must be given a node.
  var mapID: SettingsMapID {
    switch self {
    case .general: .meetingsTabGeneral
    case .callApps: .meetingsTabCallApps
    case .permissions: .meetingsTabPermissions
    }
  }

  var label: LocalizedStringResource {
    switch self {
    case .general:
      LocalizedStringResource("General", comment: "EnviousMeet settings: tab name.")
    case .callApps:
      LocalizedStringResource(
        "Call Apps", comment: "EnviousMeet settings: tab name for the per-app call switches.")
    case .permissions:
      LocalizedStringResource(
        "Permissions",
        comment: "EnviousMeet settings: tab name for the macOS permissions EnviousMeet uses.")
    }
  }

  var icon: String {
    switch self {
    case .general: "gearshape"
    case .callApps: "phone.badge.waveform"
    case .permissions: "hand.raised"
    }
  }
}
