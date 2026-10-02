import SwiftUI

/// The section a settings page belongs to, set by `UnifiedWindowView` on each
/// page's content so `SettingsContentView` can render the page-header card as
/// its first item without every page wiring it up by hand.
private struct SettingsPageSectionKey: EnvironmentKey {
  static let defaultValue: SettingsSection? = nil
}

extension EnvironmentValues {
  var settingsPageSection: SettingsSection? {
    get { self[SettingsPageSectionKey.self] }
    set { self[SettingsPageSectionKey.self] = newValue }
  }
}

/// A way for a page to send the user to ANOTHER page.
///
/// **Added for the Appearance page's link to Live Preview** (#2446). Picking the
/// pill that shows words switches Live Preview on, and the user then needs
/// somewhere to configure it — which lives on a different page. Threading a
/// binding down through `AppearanceSettingsView` into a panel would put window
/// navigation in the signature of every view in between; the environment is where
/// this window already keeps `settingsPageSection`, one level up.
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

/// Sidebar navigation sections for the unified window.
enum SettingsSection: String, CaseIterable, Identifiable {
  case history
  case whatsNew
  case appearance
  // #3385: one page with six tabs replaces Transcription, Live Preview,
  // Microphone, Sounds and Clipboard (and takes the pill from Appearance).
  case dictation
  case keybinds
  case transcribeFile
  case aiPolish
  case wordCorrection
  case snippets
  case permissions
  case checkForUpdates
  case openSourceLicenses
  #if DEBUG
    case diagnostics
  #endif

  var id: String { rawValue }

  var label: String {
    switch self {
    case .history: return String(localized: "History", comment: "Settings sidebar: a page name.")
    case .whatsNew:
      return String(localized: "What's New", comment: "Settings sidebar: a page name.")
    case .appearance:
      return String(localized: "Appearance", comment: "Settings sidebar: a page name.")
    case .dictation:
      return String(localized: "Dictation Settings", comment: "Settings sidebar: a page name.")
    case .transcribeFile:
      return String(localized: "Transcribe a File", comment: "Settings sidebar: a page name.")
    case .keybinds: return String(localized: "Keybinds", comment: "Settings sidebar: a page name.")
    case .aiPolish: return String(localized: "AI Polish", comment: "Settings sidebar: a page name.")
    case .wordCorrection:
      return String(localized: "Dictionary", comment: "Settings sidebar: a page name.")
    case .snippets: return String(localized: "Snippets", comment: "Settings sidebar: a page name.")
    case .permissions:
      return String(localized: "Permissions", comment: "Settings sidebar: a page name.")
    case .checkForUpdates:
      return String(localized: "Check for Updates", comment: "Settings sidebar: a page name.")
    case .openSourceLicenses:
      return String(localized: "Open Source Licenses", comment: "Settings sidebar: a page name.")
    #if DEBUG
      case .diagnostics:
        return String(localized: "Diagnostics", comment: "Settings sidebar: a page name.")
    #endif
    }
  }

  var icon: String {
    switch self {
    case .history: return "clock.arrow.circlepath"
    case .whatsNew: return "sparkle.magnifyingglass"
    case .appearance: return "circle.lefthalf.filled"
    // The design gives the page the engine glyph today's Transcription row uses.
    case .dictation: return "waveform"
    case .transcribeFile: return "waveform.badge.plus"
    case .keybinds: return "keyboard"
    case .aiPolish: return "sparkles"
    case .wordCorrection: return "textformat.abc"
    case .snippets: return "curlybraces"
    case .permissions: return "lock.shield"
    case .checkForUpdates: return "arrow.triangle.2.circlepath"
    case .openSourceLicenses: return "doc.text.magnifyingglass"
    #if DEBUG
      case .diagnostics: return "ladybug"
    #endif
    }
  }

  /// One-line orientation shown under the title in each page's header.
  var subtitle: String {
    switch self {
    case .history:
      return String(
        localized: "Your past dictations, searchable and ready to reuse.",
        comment: "Settings: the one-line description under a page title.")
    case .whatsNew:
      return String(
        localized: "The latest improvements and fixes in this release.",
        comment: "Settings: the one-line description under a page title.")
    // #2376: widened from "in light and dark" when the recording-pill picker
    // joined this page. The old line described one section rather than the page.
    case .appearance:
      return String(
        localized: "How the app looks, and the pill you see while dictating.",
        comment: "Settings: the one-line description under a page title.")
    // #3385: no header paragraph; the tabs say what the page holds, and the
    // page header itself goes away in this same change.
    case .dictation: return ""
    // #2648. Says what the user gets, not what the feature is: eight of thirteen
    // competitors accept a file and the three r/macapps requests were a walk, a
    // lecture and a meeting.
    case .transcribeFile:
      return String(
        localized: "Turn a recording you already have into clean text.",
        comment: "Settings: the one-line description under a page title.")
    case .keybinds:
      return String(
        localized: "Set the keybinds that start, stop, and cancel dictation.",
        comment: "Settings: the one-line description under a page title.")
    case .aiPolish:
      return String(
        localized: "Clean up and rewrite your dictation with AI.",
        comment: "Settings: the one-line description under a page title.")
    case .wordCorrection:
      return String(
        localized: "Improve recognition with your words and vocabulary.",
        comment: "Settings: the one-line description under a page title.")
    case .snippets:
      return String(
        localized: "Say your keyword, then a snippet. The saved text lands for you.",
        comment: "Settings: the one-line description under a page title.")
    case .permissions:
      return String(
        localized: "Manage app permissions and privacy settings.",
        comment: "Settings: the one-line description under a page title.")
    case .checkForUpdates: return ""
    case .openSourceLicenses:
      return String(
        localized: "EnviousWispr is GPLv3 open source. The license and third-party notices.",
        comment: "Settings: the one-line description under a page title.")
    #if DEBUG
      case .diagnostics:
        return String(
          localized: "Logs, benchmarks, and debug tools.",
          comment: "Settings: the one-line description under a page title.")
    #endif
    }
  }

  var group: SettingsGroup {
    switch self {
    case .history, .whatsNew, .appearance: return .app
    case .dictation, .keybinds, .transcribeFile: return .record
    case .aiPolish, .wordCorrection, .snippets: return .process
    case .permissions, .checkForUpdates, .openSourceLicenses: return .system
    #if DEBUG
      case .diagnostics: return .system
    #endif
    }
  }
}

enum SettingsGroup: String, CaseIterable {
  case app = "APP"
  case record = "RECORD"
  case process = "PROCESS"
  case system = "SYSTEM"

  var sections: [SettingsSection] {
    SettingsSection.allCases.filter { $0.group == self }
  }

  /// The sidebar heading. The raw value is the group's identity and stays English (#3142).
  var heading: String {
    switch self {
    case .app:
      return String(localized: "APP", comment: "Settings sidebar: group heading, in capitals.")
    case .record:
      return String(localized: "RECORD", comment: "Settings sidebar: group heading, in capitals.")
    case .process:
      return String(localized: "PROCESS", comment: "Settings sidebar: group heading, in capitals.")
    case .system:
      return String(localized: "SYSTEM", comment: "Settings sidebar: group heading, in capitals.")
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

  var label: LocalizedStringResource {
    switch self {
    case .engine:
      return LocalizedStringResource("Engine", comment: "Dictation Settings: tab name.")
    case .microphone:
      return LocalizedStringResource(
        "Microphone & Media",
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
  case whatsNew
  case appearance
  case dictation(DictationTab)
  case keybinds
  case transcribeFile
  case aiPolish
  case wordCorrection
  case snippets
  case permissions
  case openSourceLicenses
  #if DEBUG
    case diagnostics
  #endif

  var page: SettingsSection {
    switch self {
    case .history: return .history
    case .whatsNew: return .whatsNew
    case .appearance: return .appearance
    case .dictation: return .dictation
    case .keybinds: return .keybinds
    case .transcribeFile: return .transcribeFile
    case .aiPolish: return .aiPolish
    case .wordCorrection: return .wordCorrection
    case .snippets: return .snippets
    case .permissions: return .permissions
    case .openSourceLicenses: return .openSourceLicenses
    #if DEBUG
      case .diagnostics: return .diagnostics
    #endif
    }
  }
}

/// The window's one answer to "which page, and which tab" (#3385). Lives for
/// the window only and is never saved: a fresh window opens on History.
/// Choosing a page in the sidebar returns to the tab used last on that page;
/// a request for a specific tab goes there and becomes the remembered tab.
struct SettingsNavigationState: Equatable {
  var selectedPage: SettingsSection = .history
  var dictationTab: DictationTab = .engine

  mutating func selectSidebar(_ page: SettingsSection) {
    // The update check is an action row; it never becomes the page on screen.
    guard page != .checkForUpdates else { return }
    selectedPage = page
  }

  mutating func apply(_ destination: SettingsDestination) {
    selectedPage = destination.page
    if case .dictation(let tab) = destination {
      dictationTab = tab
    }
  }
}
