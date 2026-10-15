import AppKit
import EnviousWisprServices

/// What a Keybinds row stores and refuses, for the screen and the dev control door alike (moved
/// out of `KeybindsSettingsView` by #3765 PR-C). The conflict policy stays in `ShortcutMatcher`;
/// what a key event MEANS stays in `HotkeyCapture`.
///
/// Nothing here claims the one-shot Globe guidance (`claimGlobeKeyGuidancePresentation`): only
/// a screen that then shows the popover may take it, so a write from anywhere else leaves it for
/// the user's own first Globe pick.
@MainActor
enum ShortcutSettings {
  /// Recording's pair is stored under its shipped `toggle` names.
  static func keyCodeField(for role: ShortcutRole) -> ReferenceWritableKeyPath<
    SettingsManager, UInt16
  > {
    switch role {
    case .record: \.toggleKeyCode
    case .cancel: \.cancelKeyCode
    case .quickAdd: \.quickAddKeyCode
    case .pasteLast: \.pasteLastKeyCode
    case .copyLast: \.copyLastKeyCode
    }
  }

  static func modifiersField(for role: ShortcutRole) -> ReferenceWritableKeyPath<
    SettingsManager, NSEvent.ModifierFlags
  > {
    switch role {
    case .record: \.toggleModifiers
    case .cancel: \.cancelModifiers
    case .quickAdd: \.quickAddModifiers
    case .pasteLast: \.pasteLastModifiers
    case .copyLast: \.copyLastModifiers
    }
  }

  /// Whether `candidate` may be saved as `role`'s whole binding, against the other four as saved.
  static func refusal(
    assigning candidate: ShortcutBinding, to role: ShortcutRole, in settings: SettingsManager
  ) -> ShortcutRefusal? {
    ShortcutMatcher.refusal(assigning: candidate, to: role, in: settings.shortcutBindings)
  }

  /// Checks, then saves both halves through `commit`, as a Keybinds capture does.
  @discardableResult
  static func assign(
    _ candidate: ShortcutBinding, to role: ShortcutRole, in settings: SettingsManager
  ) -> ShortcutRefusal? {
    commit(
      candidate,
      validate: { refusal(assigning: $0, to: role, in: settings) },
      writeKeyCode: { settings[keyPath: keyCodeField(for: role)] = $0 },
      writeModifiers: { settings[keyPath: modifiersField(for: role)] = $0 })
  }

  /// The one checked save every shortcut takes: the recorder's capture and Reset, and `assign`.
  /// Returns the refusal, if any, and in that case writes NEITHER half.
  ///
  /// #3106: the check has to come first. A capture's owner is notified after the write, and a
  /// saved binding reaches registration through the settings sync before any later check could
  /// object. The key code is written before the modifiers, as the recorder always has.
  @discardableResult
  static func commit(
    _ candidate: ShortcutBinding,
    validate: (ShortcutBinding) -> ShortcutRefusal?,
    writeKeyCode: (UInt16) -> Void,
    writeModifiers: (NSEvent.ModifierFlags) -> Void
  ) -> ShortcutRefusal? {
    if let refused = validate(candidate) { return refused }
    switch candidate {
    case .keyboard(let keyCode, let modifiers):
      writeKeyCode(keyCode)
      writeModifiers(modifiers)
    }
    return nil
  }
}
