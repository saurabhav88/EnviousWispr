import EnviousWisprCore
import EnviousWisprServices
import SwiftUI

/// Two compact sections; shortcut persistence and capture remain with their existing owners.
struct KeybindsSettingsView: View {
  @Environment(SettingsManager.self) private var settings

  var body: some View {
    @Bindable var settings = settings
    SettingsContentView {
      SettingsSectionHeading(map: .id(.sectionKeybindsRecording), casing: .localizedUppercase)
      BrandedSection {
        BrandedRow {
          SettingsRow(
            map: .id(.recordingMode),
            icon: "hand.tap",
            help: settings.isPushToTalk
              ? KeybindsSettingsCopy.pushToTalkHelp : KeybindsSettingsCopy.toggleHelp
          ) {
            BrandedSegmentedPicker(
              options: SettingsChoicePresentation.recordingMode.map(\.pickerOption),
              selection: $settings.recordingMode
            )
            // As wide as the keybind fields below, two equal halves (founder, 2026-10-03).
            .frame(width: HotkeyRecorderView.Style.prominent.fieldWidth)
            // A group, so each option keeps its own name for VoiceOver; a label on the
            // picker itself replaced every option's name with this one.
            .accessibilityElement(children: .contain)
            .accessibilityLabel(Text(KeybindsSettingsCopy.modeTitle))
          }
        }
        BrandedRow {
          KeybindSettingsRow(
            map: .id(.recordKeybind), icon: "mic",
            help: KeybindsSettingsCopy.recordHelp,
            keyCode: $settings.toggleKeyCode,
            modifiers: $settings.toggleModifiers, role: .record
          )
        }
        BrandedRow {
          KeybindSettingsRow(
            map: .id(.cancelKeybind), icon: "xmark",
            help: KeybindsSettingsCopy.cancelHelp,
            keyCode: $settings.cancelKeyCode,
            modifiers: $settings.cancelModifiers, role: .cancel
          )
        }
        BrandedRow(showDivider: false) {
          SettingsRow(
            map: .id(.escapeRecovery),
            icon: "arrow.uturn.backward",
            help: KeybindsSettingsCopy.recoveryHelp
          ) {
            Toggle("", isOn: $settings.escapeRecoveryEnabled)
              .labelsHidden()
              .toggleStyle(BrandedToggleStyle())
              .fixedSize()
              .accessibilityLabel(Text(KeybindsSettingsCopy.recoveryTitle))
          }
        }
      }
      SettingsSectionHeading(map: .id(.sectionKeybindsShortcuts), casing: .localizedUppercase)
      BrandedSection {
        BrandedRow {
          KeybindSettingsRow(
            map: .id(.quickAddKeybind), icon: "character.book.closed",
            help: KeybindsSettingsCopy.addHelp,
            keyCode: $settings.quickAddKeyCode,
            modifiers: $settings.quickAddModifiers, role: .quickAdd
          )
        }
        BrandedRow {
          KeybindSettingsRow(
            map: .id(.pasteLastKeybind), icon: "clipboard",
            help: KeybindsSettingsCopy.pasteHelp,
            keyCode: $settings.pasteLastKeyCode,
            modifiers: $settings.pasteLastModifiers, role: .pasteLast
          )
        }
        BrandedRow(showDivider: false) {
          KeybindSettingsRow(
            map: .id(.copyLastKeybind), icon: "doc.on.doc",
            help: KeybindsSettingsCopy.copyHelp,
            keyCode: $settings.copyLastKeyCode,
            modifiers: $settings.copyLastModifiers, role: .copyLast
          )
        }
      }
    }
    .environment(\.settingsPR1Density, true)
  }
}

/// Localized copy shared by the page and its row help.
enum KeybindsSettingsCopy {
  static let modeTitle: LocalizedStringResource = "Recording mode"
  static let modeShort: LocalizedStringResource =
    "Hold to talk, or press once to start and again to stop."
  static let pushToTalkHelp: LocalizedStringResource =
    "Hold the keybind to record. Release to stop. Double-press to lock it on. Triple-press to cancel."
  static let toggleHelp: LocalizedStringResource =
    "Press once to start recording. Press again to stop."
  static let recordTitle: LocalizedStringResource = "Start / stop recording"
  static let recordShort: LocalizedStringResource = "Click Change to choose the keys you use."
  static let recordHelp: LocalizedStringResource = "This keybind starts and stops recording."
  static let cancelTitle: LocalizedStringResource = "Cancel recording"
  static let cancelShort: LocalizedStringResource = "Cancels the current recording."
  // The setting is frozen at recording start, so the help never tracks the live toggle.
  static let cancelHelp: LocalizedStringResource =
    "Press to cancel the current recording. Escape Recovery below applies from the next recording you start."
  static let recoveryTitle: LocalizedStringResource = "Escape Recovery"
  static let recoveryShort: LocalizedStringResource =
    "Keeps cancelled dictations in History for 24 hours."
  // Preserve the full disclosure: configurable cancel key, processing, API use and retention.
  static let recoveryHelp: LocalizedStringResource = """
    When you use your cancel keybind, Escape by default, EnviousWispr keeps the \
    dictation instead of discarding it. It finishes transcribing and polishing, then \
    offers to paste it. Another recording cannot start until that finishes, the same \
    as after any dictation. AI polish runs as usual, which uses your own API key when \
    configured. The audio is deleted once the text is saved; the text stays in \
    History for 24 hours unless you Keep it. The Cancel button still discards \
    immediately.
    """
  static let addTitle: LocalizedStringResource = "Add selected word to Dictionary"
  static let addShort: LocalizedStringResource = "Select a misheard word, then press these keys."
  static let addHelp: LocalizedStringResource =
    "Select a misheard word anywhere, then press this to add it to Your Words. Terminal windows do not share their selection, so it will not work there."
  static let pasteTitle: LocalizedStringResource = "Paste last dictation"
  static let pasteShort: LocalizedStringResource = "Pastes your last dictation."
  static let pasteHelp: LocalizedStringResource = "Paste the last thing you dictated"
  static let copyTitle: LocalizedStringResource = "Copy last dictation"
  static let copyShort: LocalizedStringResource = "Copies your last dictation."
  static let copyHelp: LocalizedStringResource = "Copy the last thing you dictated"
}

/// Role owns Reset defaults; warnings remain visible below the short line.
private struct KeybindSettingsRow: View {
  /// The row's Settings Map identity; its title comes from the map node (#3482).
  let map: SettingsMapRef
  let icon: String
  let help: LocalizedStringResource
  @Binding var keyCode: UInt16
  @Binding var modifiers: NSEvent.ModifierFlags
  /// Which shortcut this row edits. **The row derives its Reset default from this rather than being
  /// handed one**, so no call site has a default to get wrong.
  ///
  /// Three review rounds found the same defect one member at a time — a hard-coded number, then the
  /// same number surviving in a full-line comment, then in a trailing one — because a guard over
  /// source text is a DESCRIPTION of a set and the next counterexample always exists.
  ///
  /// Precisely what this buys, since "unwriteable" would be an overclaim: a literal is still
  /// writeable HERE, in the two accessors below. What is gone is a literal at each of three CALL
  /// SITES, where it applies to one row, reads as ordinary, and drifts alone. One here would apply
  /// to every row at once, which is the difference between a quiet wrong default and an obvious one.
  let role: ShortcutRole

  @Environment(SettingsManager.self) private var settings
  @Environment(DictationRuntime.self) private var dictationRuntime
  @State private var showGlobeGuidance = false
  @AccessibilityFocusState private var guidanceReturnFocus: Bool
  @FocusState private var recordingKeybindFocused: Bool

  /// The capture field's VoiceOver name, word for word as on main (founder, 2026-10-03).
  private var captureLabel: String {
    switch role {
    case .record: return String(localized: "Recording keybind")
    case .cancel: return String(localized: "Cancel keybind")
    case .quickAdd: return String(localized: "Add-a-word keybind")
    case .pasteLast: return String(localized: "Paste last dictation keybind")
    case .copyLast: return String(localized: "Copy last dictation keybind")
    }
  }

  private var defaultKeyCode: UInt16 { role.defaultKeyCode }
  private var defaultModifiers: NSEvent.ModifierFlags { role.defaultModifiers }

  /// "Not active: the recording keybind (Right ⌘) uses these keys. Choose another."
  ///
  /// Cancel listens only while recording, so a row it displaces still works the rest of the time
  /// (registration gives the chord back when Cancel disarms); the sentence says exactly that.
  static func notActiveMessage(taker: ShortcutRole, bindings: ShortcutBindings) -> String {
    guard case .keyboard(let code, let modifiers) = bindings[taker] else { return "" }
    return KeybindConflictCopy.notActive(
      taker: taker,
      keys: KeySymbols.format(keyCode: code, modifiers: modifiers))
  }

  private func dismissGlobeGuidance() {
    showGlobeGuidance = false
    recordingKeybindFocused = true
    guidanceReturnFocus = true
  }

  var body: some View {
    SettingsRow(map: map, icon: icon, help: help) {
      HotkeyRecorderView(
        keyCode: $keyCode, modifiers: $modifiers,
        defaultKeyCode: defaultKeyCode, defaultModifiers: defaultModifiers,
        label: captureLabel,
        style: .prominent,
        onBindingAccepted: { code, _ in
          if role == .record, settings.claimGlobeKeyGuidancePresentation(for: code) {
            showGlobeGuidance = true
          }
        },
        validate: { [role, settings] proposed in
          ShortcutMatcher.refusal(assigning: proposed, to: role, in: settings.shortcutBindings)
        },
        keyboardFocus: $recordingKeybindFocused,
        accessibilityFocus: $guidanceReturnFocus
      )
      .frame(width: HotkeyRecorderView.Style.prominent.fieldWidth)
      .popover(isPresented: $showGlobeGuidance, arrowEdge: .bottom) {
        GlobeGuidancePopover(onDismiss: dismissGlobeGuidance)
          .onExitCommand(perform: dismissGlobeGuidance)
      }
    }
    .rowStatus {
      if let taker = ShortcutMatcher.displacingRole(of: role, in: settings.shortcutBindings) {
        Text(Self.notActiveMessage(taker: taker, bindings: settings.shortcutBindings))
          .font(.stRowHelper).foregroundStyle(.stAccent)
          .fixedSize(horizontal: false, vertical: true)
      } else if dictationRuntime.isCurrentBindingConflicted(role) {
        // Internal displacement cannot see Carbon's refusal of the saved chord.
        Text(
          ExternalConflictCopy.notWorking(
            role: role,
            keys: KeySymbols.format(keyCode: keyCode, modifiers: modifiers))
        )
        .font(.stRowHelper).foregroundStyle(.stAccent)
        .fixedSize(horizontal: false, vertical: true)
      }
    }
  }
}

// MARK: - Globe key guidance (#1987)

/// The one-time "free up the Globe key" explanation, shared by Settings and
/// onboarding so both surfaces render identical copy.
///
/// Accessibility is load-bearing here, not decoration: the persona this feature
/// exists for is an RSI user whose card demands no modals. Shipping an
/// ergonomics feature behind a pointer-only dialog would be self-defeating. So the
/// dismiss control is a real focusable `Button`, the container carries one spoken
/// label, and the decorative step numbers are hidden from VoiceOver so it reads
/// the instructions rather than the bullets.
///
/// Escape is handled EXPLICITLY by each host through `.onExitCommand`, not by
/// AppKit's default popover dismissal. The default closes the popover and leaves
/// focus wherever it had taken it, so a keyboard user is dropped nowhere; the
/// hosts route both Escape and the button through one dismissal that restores
/// focus to the keybind control.
struct GlobeGuidancePopover: View {
  let onDismiss: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(GlobeKeyCopy.title)
        .font(.stRowTitle)
        .foregroundStyle(.stTextPrimary)

      Text(GlobeKeyCopy.body)
        .settingsReadingCopy()

      VStack(alignment: .leading, spacing: 6) {
        ForEach(Array(GlobeKeyCopy.steps.enumerated()), id: \.offset) { index, step in
          HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(index + 1).")
              .foregroundStyle(.stTextTertiary)
              .accessibilityHidden(true)
            Text(step).settingsReadingCopy()
          }
        }
      }

      Text(GlobeKeyCopy.reassurance)
        .settingsReadingCopy()

      HStack {
        Spacer()
        Button(GlobeKeyCopy.dismissButton, action: onDismiss)
          .keyboardShortcut(.defaultAction)
      }
    }
    .padding(18)
    .frame(width: 340)
    .accessibilityElement(children: .contain)
    .accessibilityLabel(GlobeKeyCopy.accessibilityLabel)
  }
}

/// The warning under a keybind whose keys another keybind has taken (#3142).
///
/// One whole sentence per keybind rather than a role phrase spliced into a frame, because the
/// phrase's grammar changes with the sentence around it in other languages. `keys` is the key
/// combination, such as Right ⌘.
enum KeybindConflictCopy {
  static func notActive(taker: ShortcutRole, keys: String) -> String {
    switch taker {
    case .cancel:
      return String(
        localized:
          "Works only when you are not recording: the cancel keybind (\(keys)) uses these keys while you record.",
        comment: "Keybinds settings: a conflict warning. %@ is a key combination, such as Right ⌘.")
    case .record:
      return String(
        localized: "Not active: the recording keybind (\(keys)) uses these keys. Choose another.",
        comment: "Keybinds settings: a conflict warning. %@ is a key combination, such as Right ⌘.")
    case .quickAdd:
      return String(
        localized: "Not active: the add-a-word keybind (\(keys)) uses these keys. Choose another.",
        comment: "Keybinds settings: a conflict warning. %@ is a key combination, such as Right ⌘.")
    case .pasteLast:
      return String(
        localized: "Not active: Paste last dictation (\(keys)) uses these keys. Choose another.",
        comment:
          "Keybinds settings: a conflict warning. Paste last dictation is the name of a keybind. %@ is a key combination, such as Right ⌘."
      )
    case .copyLast:
      return String(
        localized: "Not active: Copy last dictation (\(keys)) uses these keys. Choose another.",
        comment:
          "Keybinds settings: a conflict warning. Copy last dictation is the name of a keybind. %@ is a key combination, such as Right ⌘."
      )
    }
  }
}

/// The warning under a keybind that Carbon refused to register with -9878 (#3273, issue #3266).
/// The cause is unknown: a live check on macOS 27.2 found a second process registering the same
/// chord accepted, so this does not claim another program or macOS holds it.
///
/// This is a DIFFERENT concern from `KeybindConflictCopy` above: that one compares our own 5
/// roles against each other and can always name the taker; this one is a live OS refusal, and we
/// can never name what holds the combo — macOS exposes no such query, and we do not record the
/// actual keys for any purpose beyond this row (`TelemetryService.swift`, "Metadata only — never
/// the key codes"). One whole sentence per role for the same reason `KeybindConflictCopy` gives:
/// grammar and the role's own name do not splice cleanly across languages.
enum ExternalConflictCopy {
  static func notWorking(role: ShortcutRole, keys: String) -> String {
    switch role {
    case .record:
      return String(
        localized:
          "The recording keybind (\(keys)) isn't working. macOS says this key combination is already taken. Choose another.",
        comment:
          "Keybinds settings: an external conflict warning. %@ is a key combination, such as Right ⌘."
      )
    case .cancel:
      return String(
        localized:
          "The cancel keybind (\(keys)) isn't working while you're recording. macOS says this key combination is already taken. Choose another.",
        comment:
          "Keybinds settings: an external conflict warning. %@ is a key combination, such as Right ⌘."
      )
    case .quickAdd:
      return String(
        localized:
          "The add-a-word keybind (\(keys)) isn't working. macOS says this key combination is already taken. Choose another.",
        comment:
          "Keybinds settings: an external conflict warning. %@ is a key combination, such as Right ⌘."
      )
    case .pasteLast:
      return String(
        localized:
          "Paste last dictation (\(keys)) isn't working. macOS says this key combination is already taken. Choose another.",
        comment:
          "Keybinds settings: an external conflict warning. Paste last dictation is the name of a keybind. %@ is a key combination, such as Right ⌘."
      )
    case .copyLast:
      return String(
        localized:
          "Copy last dictation (\(keys)) isn't working. macOS says this key combination is already taken. Choose another.",
        comment:
          "Keybinds settings: an external conflict warning. Copy last dictation is the name of a keybind. %@ is a key combination, such as Right ⌘."
      )
    }
  }
}
