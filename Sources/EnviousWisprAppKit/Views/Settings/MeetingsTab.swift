import SwiftUI

/// The EnviousMeet tabs (#4058), in display order. Selection belongs to the window shell.
enum MeetingsTab: String, CaseIterable, Hashable, Identifiable {
  case general
  case models
  /// #4287: the summary engine, chosen independently of dictation's AI Polish.
  case summaries
  case callApps
  case permissions

  var id: Self { self }

  /// The tab's Settings Map identity (#3482). Exhaustive, so a new tab must be given a node.
  var mapID: SettingsMapID {
    switch self {
    case .general: .meetingsTabGeneral
    case .models: .meetingsTabModels
    case .summaries: .meetingsTabSummaries
    case .callApps: .meetingsTabCallApps
    case .permissions: .meetingsTabPermissions
    }
  }

  var label: LocalizedStringResource {
    switch self {
    case .general:
      LocalizedStringResource("General", comment: "EnviousMeet settings: tab name.")
    case .models:
      LocalizedStringResource(
        "Models",
        comment: "EnviousMeet settings: tab name for the speech engines and languages.")
    case .summaries:
      LocalizedStringResource(
        "Summaries",
        comment: "EnviousMeet settings: tab name for the engine that writes meeting summaries.")
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
    case .models: "cpu"
    case .summaries: "sparkles"
    case .callApps: "phone.badge.waveform"
    case .permissions: "hand.raised"
    }
  }
}
