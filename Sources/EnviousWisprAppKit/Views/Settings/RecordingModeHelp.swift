import EnviousWisprCore
import EnviousWisprServices
import SwiftUI

/// #3703: what the Recording mode "?" shows. The ways to record, one line each, and a link to the
/// Push to Talk help page, which carries a short silent clip and the same steps written out.
///
/// The hold-plus-Space line (#3517) is listed only when the record key is one of the bare modifier
/// keys (`ShortcutBinding.isBareModifier`), because a chord record key cannot use it (#3697). "Hands-free"
/// is the word the recording pill's badge uses (`LivePreviewCopy.handsFreeMode`).
///
/// "Triple-press to cancel" belongs to the double-press line only: a hold-plus-Space lock bypasses the
/// triple-press cancel (`RecordGesture`), so the closing line makes no cancel claim.
///
/// No em-dashes or en-dashes (brand rule).
enum RecordingModeHelpCopy {
  static let hold = LocalizedStringResource(
    "Hold the keybind to record. Release to stop.",
    comment: "Keybinds, Recording mode help in Push to Talk: hold the dictation key to record.")
  static let doublePress = LocalizedStringResource(
    "Double-press the keybind to go hands-free. Triple-press to cancel instead.",
    comment:
      "Keybinds, Recording mode help in Push to Talk: two quick presses lock hands-free recording on, three quick presses cancel."
  )
  static let holdAndSpace = LocalizedStringResource(
    "Hold only the keybind and press Space to go hands-free.",
    comment:
      "Keybinds, Recording mode help in Push to Talk: while holding a single modifier dictation key, pressing Space locks hands-free recording on. Space is the Space bar."
  )
  static let closing = LocalizedStringResource(
    "To stop a hands-free recording, press the keybind once.",
    comment: "Keybinds, Recording mode help in Push to Talk: how to end a hands-free recording.")
  /// The Toggle sentence, moved here from `KeybindsSettingsCopy` with its English unchanged so its
  /// catalog key and German are unchanged.
  static let toggle: LocalizedStringResource =
    "Press once to start recording. Press again to stop."
  static let watchLabel = LocalizedStringResource(
    "Watch how it works",
    comment:
      "Keybinds, Recording mode help in Push to Talk: link to the Help Center page that shows a short video of the recording gestures."
  )
  static let watchAccessibilityLabel = LocalizedStringResource(
    "Watch how Push to Talk works",
    comment: "Keybinds, Recording mode help: spoken name of the Help Center video link.")
  /// The Help Center page that carries the clip. `RecordingModeHelpArticleParityTests` pins the slug
  /// and that the page declares the clip.
  static let learnMoreURL = URL(string: HelpCenter.rootURL + "push-to-talk-mode/")
}

/// Which lines the Recording mode help shows. The only place that decides.
enum RecordingModeHelpContent {
  enum Line: String, Identifiable, Equatable {
    case hold, doublePress, holdAndSpace, closing, toggle
    var id: String { rawValue }

    /// Bullets are the ways to record; the closing line and the Toggle sentence are plain text.
    var isBullet: Bool {
      switch self {
      case .hold, .doublePress, .holdAndSpace: return true
      case .closing, .toggle: return false
      }
    }

    var copy: LocalizedStringResource {
      switch self {
      case .hold: return RecordingModeHelpCopy.hold
      case .doublePress: return RecordingModeHelpCopy.doublePress
      case .holdAndSpace: return RecordingModeHelpCopy.holdAndSpace
      case .closing: return RecordingModeHelpCopy.closing
      case .toggle: return RecordingModeHelpCopy.toggle
      }
    }
  }

  static func lines(isPushToTalk: Bool, record: ShortcutBinding) -> [Line] {
    guard isPushToTalk else { return [.toggle] }
    var lines: [Line] = [.hold, .doublePress]
    if record.isBareModifier { lines.append(.holdAndSpace) }
    lines.append(.closing)
    return lines
  }
}

/// The "?" popup content for the Recording mode row. `SettingsInfoButton` supplies the padding.
struct RecordingModeHelpPanel: View {
  let isPushToTalk: Bool
  let record: ShortcutBinding

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      ForEach(RecordingModeHelpContent.lines(isPushToTalk: isPushToTalk, record: record)) { line in
        if line.isBullet {
          HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(verbatim: "\u{2022}")
              .accessibilityHidden(true)
            Text(line.copy)
              .settingsReadingCopy()
          }
        } else {
          Text(line.copy)
            .settingsReadingCopy()
        }
      }
      if isPushToTalk {
        SettingsHelpArticleLink(
          url: RecordingModeHelpCopy.learnMoreURL,
          label: RecordingModeHelpCopy.watchLabel,
          accessibilityLabel: RecordingModeHelpCopy.watchAccessibilityLabel)
      }
    }
    .frame(maxWidth: 300, alignment: .leading)
  }
}
