import SwiftUI

/// A way for a page to send the user to ANOTHER page.
///
/// **Added for the Appearance page's link to Live Preview** (#2446). Picking the
/// pill that shows words switches Live Preview on, and the user then needs
/// somewhere to configure it — which lives on a different page. Threading a
/// binding down through `AppearanceSettingsView` into a panel would put window
/// navigation in the signature of every view in between; the environment is where
/// this window already keeps `settingsPageSection`, one level up.
/// (#3385: the page-header environment value is gone with the page headers;
/// this key is set by `UnifiedWindowView.page` for every page.)
///
/// Defaults to a no-op rather than to `nil`, so a preview or a test that hosts a
/// panel on its own gets a dead link instead of a crash.
private struct SettingsNavigateKey: EnvironmentKey {
  static let defaultValue: @MainActor (SettingsDestination) -> Void = { _ in }
}

extension EnvironmentValues {
  var settingsNavigate: @MainActor (SettingsDestination) -> Void {
    get { self[SettingsNavigateKey.self] }
    set { self[SettingsNavigateKey.self] = newValue }
  }
}

/// The final sidebar pages. History is ungrouped; Diagnostics is development only.
enum SettingsPage: String, CaseIterable, Identifiable {
  case history
  case dictation
  case keybinds
  case transcribeFile
  case aiPolish
  case dictionary
  case snippets
  case appSettings
  #if DEBUG
    case diagnostics
  #endif

  var id: String { rawValue }

  /// The page's name as a resource, so the sidebar and the Settings Map (#3482) share one
  /// owner. Diagnostics is a DEBUG-only developer page with no catalog entry, so it has none.
  var labelResource: LocalizedStringResource? {
    switch self {
    case .history: "History"
    case .dictation: "Dictation Settings"
    case .keybinds: "Keybinds"
    case .transcribeFile: "Transcribe a File"
    case .aiPolish: "AI Polish"
    case .dictionary: "Dictionary"
    case .snippets: "Snippets"
    case .appSettings: "App Settings"
    #if DEBUG
      case .diagnostics: nil
    #endif
    }
  }

  var label: String {
    labelResource.map { String(localized: $0) } ?? "Diagnostics"
  }

  var icon: String {
    switch self {
    case .history: "clock.arrow.circlepath"
    case .dictation: "waveform"
    case .keybinds: "keyboard"
    case .transcribeFile: "waveform.badge.plus"
    case .aiPolish: "sparkles"
    // A square glyph: "textformat.abc" is wider than the 19pt icon column and sat
    // out of line with every other row (#3385 audit, 2026-10-03).
    case .dictionary: "text.book.closed"
    case .snippets: "curlybraces"
    case .appSettings: "gearshape"
    #if DEBUG
      case .diagnostics: "ladybug"
    #endif
    }
  }

  var group: SettingsGroup? {
    switch self {
    case .history: nil
    case .dictation, .keybinds, .transcribeFile: .record
    case .aiPolish, .dictionary, .snippets: .process
    case .appSettings: .system
    #if DEBUG
      case .diagnostics: .system
    #endif
    }
  }
}

enum SettingsGroup: String, CaseIterable {
  case record = "RECORD"
  case process = "PROCESS"
  case system = "SYSTEM"

  var sections: [SettingsPage] {
    SettingsPage.allCases.filter { $0.group == self }
  }

  var heading: String {
    switch self {
    case .record: String(localized: "RECORD")
    case .process: String(localized: "PROCESS")
    case .system: String(localized: "SYSTEM")
    }
  }
}

/// The six tabs of Dictation Settings (#3385). The identity is stable; the
/// visible names are the founder's 2026-10-02 decisions.
enum DictationTab: String, CaseIterable, Hashable, Identifiable {
  case engine
  case microphone
  case livePreview
  case pill
  case chimes
  case clipboard

  var id: Self { self }

  /// The tab's Settings Map identity (#3482). Exhaustive, so a new tab must be given a node.
  var mapID: SettingsMapID {
    switch self {
    case .engine: .dictationTabEngine
    case .microphone: .dictationTabMicrophone
    case .livePreview: .dictationTabLivePreview
    case .pill: .dictationTabPill
    case .chimes: .dictationTabChimes
    case .clipboard: .dictationTabClipboard
    }
  }

  var label: LocalizedStringResource {
    switch self {
    case .engine:
      return LocalizedStringResource("Engine", comment: "Dictation Settings: tab name.")
    case .microphone:
      return LocalizedStringResource(
        "Microphone",
        comment: "Dictation Settings: tab name for the microphone and what other audio does.")
    case .livePreview:
      return LocalizedStringResource("Live Preview", comment: "Dictation Settings: tab name.")
    case .pill:
      return LocalizedStringResource(
        "Recording Pill",
        comment: "Dictation Settings: tab name for the floating pill shown while recording.")
    case .chimes:
      return LocalizedStringResource(
        "Chimes", comment: "Dictation Settings: tab name for the start and stop sounds.")
    case .clipboard:
      return LocalizedStringResource("Clipboard", comment: "Dictation Settings: tab name.")
    }
  }

  var icon: String {
    switch self {
    case .engine: return "waveform"
    case .microphone: return "mic"
    case .livePreview: return "text.viewfinder"
    case .pill: return "capsule"
    case .chimes: return "bell.and.waveform"
    case .clipboard: return "clipboard"
    }
  }
}

/// Where a request to open Settings lands: a page, and for Dictation Settings
/// the tab. A tab that does not belong to its page cannot be written down.
/// "Check for Updates" is an action, never a place, so it has no case.
enum SettingsDestination: Equatable {
  case history
  case dictation(DictationTab)
  case keybinds
  case transcribeFile
  case aiPolish
  case dictionary
  case snippets
  case appSettings(AppSettingsTab)
  #if DEBUG
    case diagnostics
  #endif

  var page: SettingsPage {
    switch self {
    case .history: .history
    case .dictation: .dictation
    case .keybinds: .keybinds
    case .transcribeFile: .transcribeFile
    case .aiPolish: .aiPolish
    case .dictionary: .dictionary
    case .snippets: .snippets
    case .appSettings: .appSettings
    #if DEBUG
      case .diagnostics: .diagnostics
    #endif
    }
  }
}

/// Window-life selection, never persisted. Sidebar returns remember each page's tab;
/// an explicit destination overrides that page's remembered tab.
struct SettingsNavigationState: Equatable {
  var selectedPage: SettingsPage = .history
  var dictationTab: DictationTab = .engine
  var appSettingsTab: AppSettingsTab = .appearance

  mutating func selectSidebar(_ page: SettingsPage) {
    selectedPage = page
  }

  mutating func apply(_ destination: SettingsDestination) {
    selectedPage = destination.page
    switch destination {
    case .dictation(let tab): dictationTab = tab
    case .appSettings(let tab): appSettingsTab = tab
    case .history, .keybinds, .transcribeFile, .aiPolish, .dictionary, .snippets: break
    #if DEBUG
      case .diagnostics: break
    #endif
    }
  }
}
