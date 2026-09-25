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
  static let defaultValue: @MainActor (SettingsSection) -> Void = { _ in }
}

extension EnvironmentValues {
  var settingsNavigate: @MainActor (SettingsSection) -> Void {
    get { self[SettingsNavigateKey.self] }
    set { self[SettingsNavigateKey.self] = newValue }
  }
}

/// Sidebar navigation sections for the unified window.
enum SettingsSection: String, CaseIterable, Identifiable {
  case history
  case whatsNew
  case appearance
  case speechEngine
  case transcribeFile
  case livePreview
  case audio
  case recordingSounds
  case keybinds
  case aiPolish
  case wordCorrection
  case snippets
  case clipboard
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
    case .speechEngine:
      return String(localized: "Transcription", comment: "Settings sidebar: a page name.")
    case .transcribeFile:
      return String(localized: "Transcribe a File", comment: "Settings sidebar: a page name.")
    case .livePreview:
      return String(localized: "Live Preview", comment: "Settings sidebar: a page name.")
    case .audio: return String(localized: "Microphone", comment: "Settings sidebar: a page name.")
    case .recordingSounds:
      return String(localized: "Sounds", comment: "Settings sidebar: a page name.")
    case .keybinds: return String(localized: "Keybinds", comment: "Settings sidebar: a page name.")
    case .aiPolish: return String(localized: "AI Polish", comment: "Settings sidebar: a page name.")
    case .wordCorrection:
      return String(localized: "Dictionary", comment: "Settings sidebar: a page name.")
    case .snippets: return String(localized: "Snippets", comment: "Settings sidebar: a page name.")
    case .clipboard:
      return String(localized: "Clipboard", comment: "Settings sidebar: a page name.")
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
    case .speechEngine: return "waveform"
    case .transcribeFile: return "waveform.badge.plus"
    case .livePreview: return "text.viewfinder"
    case .audio: return "mic"
    case .recordingSounds: return "bell.and.waveform"
    case .keybinds: return "keyboard"
    case .aiPolish: return "sparkles"
    case .wordCorrection: return "textformat.abc"
    case .snippets: return "curlybraces"
    case .clipboard: return "clipboard"
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
    case .speechEngine:
      return String(
        localized: "The speech engine that turns your voice into text.",
        comment: "Settings: the one-line description under a page title.")
    // #2648. Says what the user gets, not what the feature is: eight of thirteen
    // competitors accept a file and the three r/macapps requests were a walk, a
    // lecture and a meeting.
    case .transcribeFile:
      return String(
        localized: "Turn a recording you already have into clean text.",
        comment: "Settings: the one-line description under a page title.")
    case .livePreview:
      return String(
        localized: "See your words on screen while you are still speaking.",
        comment: "Settings: the one-line description under a page title.")
    case .audio:
      return String(
        localized: "Choose your input source and readiness behavior.",
        comment: "Settings: the one-line description under a page title.")
    case .recordingSounds:
      return String(
        localized: "Play a short sound when recording starts and stops.",
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
    case .clipboard:
      return String(
        localized: "How your dictation reaches the clipboard and the app you're in.",
        comment: "Settings: the one-line description under a page title.")
    case .permissions:
      return String(
        localized: "The microphone and accessibility access EnviousWispr needs.",
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
    case .speechEngine, .transcribeFile, .livePreview, .audio, .recordingSounds, .keybinds:
      return .record
    case .aiPolish, .wordCorrection, .snippets: return .process
    case .clipboard: return .output
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
  case output = "OUTPUT"
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
    case .output:
      return String(localized: "OUTPUT", comment: "Settings sidebar: group heading, in capitals.")
    case .system:
      return String(localized: "SYSTEM", comment: "Settings sidebar: group heading, in capitals.")
    }
  }
}
