import EnviousWisprCore
import EnviousWisprServices
import Foundation

/// Window-life presentation only. Opening does no update check; Sparkle owns
/// update work independently of whether this menu stays on screen (#3385).
struct WhatsNewMenuPresentation {
  var isPresented = false

  mutating func requestOpen() { isPresented = true }
  mutating func dismiss() { isPresented = false }

  /// Called by the presented content's appearance, not the toolbar's render.
  @MainActor
  func didOpen(settings: SettingsManager) {
    guard isPresented else { return }
    settings.markWhatsNewSeen()
  }

  struct ReleaseEntry: Identifiable, Equatable {
    let id: String
    let icon: String
    let title: String
    let description: String
    let version: String
  }

  static func entries(
    from source: [WhatsNewContent.Entry] = WhatsNewContent.entries,
    version: String = WhatsNewConstants.currentContentVersion,
    bundle: Bundle = .main
  ) -> [ReleaseEntry] {
    source.filter { $0.version == version }.map { entry in
      let display = WhatsNewLocalizedDisplay(entry, bundle: bundle)
      let description: String
      if let compact = compactDescriptions[entry.id] {
        description = bundle.localizedString(
          forKey: "whatsNew.\(entry.id).compactDescription", value: compact, table: nil)
      } else {
        description = display.description
      }
      return ReleaseEntry(
        id: entry.id, icon: entry.icon, title: display.title, description: description,
        version: entry.version)
    }
  }

  enum UpdateStatus: Equatable {
    case unavailable
    case checkPrompt
    case available(String)
    case opening

    var text: String {
      switch self {
      case .unavailable: String(localized: "Update status unavailable")
      case .checkPrompt: String(localized: "Check for updates")
      case .available(let version):
        String(localized: "Version \(version) is available")
      case .opening: String(localized: "Opening update…")
      }
    }

    var canCheck: Bool {
      switch self {
      case .unavailable, .opening: false
      case .checkPrompt, .available: true
      }
    }
  }

  static func updateStatus(_ state: UpdateAvailabilityService.UpdateState?) -> UpdateStatus {
    guard let state else { return .unavailable }
    switch state {
    case .none: return .checkPrompt
    case .available(let update): return .available(update.displayVersion)
    case .resolving: return .opening
    }
  }

  static let releasesURL = URL(string: "https://github.com/saurabhav88/EnviousWispr/releases")!

  /// Separate display copy. Historical release literals remain the release-notes
  /// renderer's source of truth; future entries use their full localized copy.
  static let compactDescriptions: [String: String] = [
    "privacy-controls":
      "Choose usage metrics and crash reports in App Settings > Privacy. Feedback lets you choose diagnostics.",
    "word-check-memory":
      "Word check loads when needed and normally leaves memory after about 10 minutes without use.",
    "help-before-feedback":
      "Press Send to see help articles, or send your message as written. Supported Apple Intelligence can mark parts solved.",
    "keybind-conflict-warning":
      "Keybinds shows a warning when macOS refuses a shortcut. Choose another combination.",
    "clipboard-restored-in-chrome":
      "Your clipboard comes back after dictation into Chromium browsers and ChatGPT.",
    "paste-to-starting-chrome-window":
      "Dictation returns to the Chrome window where you started. If it closed, your words stay on the clipboard.",
    "longer-undo-for-learned-words":
      "Undo stays for 4 seconds when Self-Learning saves a word. A bar shows the time left.",
    "self-learning-skips-punctuation":
      "Self-Learning skips punctuation-only edits and is more cautious with unfinished edits.",
  ]
}

// MARK: - Localized display

/// What the What's New screen shows for one entry (#3142): each field looked up in the String
/// Catalog under `whatsNew.<id>.title`, `.description` and `.bullet.<n>`, the keys
/// `scripts/ci/render-release-notes.py --catalog-seed-json` gives it and the catalog sync
/// writes. The entry's own English is the fallback for every field, so an entry with no
/// translation reads exactly as written. `WhatsNewContent` keeps its direct English literals:
/// the GitHub release notes parse that source text, and identity stays on the entry.
struct WhatsNewLocalizedDisplay: Equatable {
  let title: String
  let description: String
  let bullets: [String]

  init(_ entry: WhatsNewContent.Entry, bundle: Bundle = .main) {
    let keys = Self.keys(for: entry)
    title = bundle.localizedString(forKey: keys.title, value: entry.title, table: nil)
    description = bundle.localizedString(
      forKey: keys.description, value: entry.description, table: nil)
    bullets = zip(keys.bullets, entry.bullets).map { key, english in
      bundle.localizedString(forKey: key, value: english, table: nil)
    }
  }

  static func keys(for entry: WhatsNewContent.Entry) -> (
    title: String, description: String, bullets: [String]
  ) {
    let base = "whatsNew.\(entry.id)"
    return (
      "\(base).title", "\(base).description",
      entry.bullets.indices.map { "\(base).bullet.\($0)" }
    )
  }
}
