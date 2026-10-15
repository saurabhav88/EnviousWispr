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

  /// What a key and its held modifiers are stored as. A standalone modifier stores no
  /// modifiers (#1987: storing its own flag would require holding the key while pressing it).
  ///
  /// #2613: a chord's modifiers are narrowed to `ShortcutMatcher.carbonEffectiveModifiers`,
  /// because the capture had no reachable chord case until #2613.
  /// `.deviceIndependentFlagsMask` also carries Caps Lock, Numeric Pad, Help and Function, and
  /// NEITHER consumer keeps them: `KeySymbols.symbolsForModifiers` renders only these four, and
  /// `HotkeyService.carbonModifiers` maps only these four on the way to `RegisterEventHotKey`.
  /// Storing a bit both of them drop gives a binding that displays and fires as something other
  /// than what is saved: a Caps-Lock-contaminated default stops comparing equal to its own
  /// default, and Globe+W would store as W with an invisible `.function`.
  ///
  /// Narrowing here, not in the capture view, is deliberate: this is the one authority both
  /// recording surfaces (through `HotkeyCapture`) and the dev control door ask what a key
  /// MEANS, so a value the view produced and this function disagreed with would be the #1987
  /// drift all over again. The set is not redefined here either: `ShortcutMatcher` owns it and
  /// documents why those four are the whole answer.
  nonisolated static func normalized(
    keyCode: UInt16, modifiers: NSEvent.ModifierFlags, standaloneModifier: Bool
  ) -> (keyCode: UInt16, modifiers: NSEvent.ModifierFlags) {
    if standaloneModifier { return (keyCode, []) }
    return (keyCode, modifiers.intersection(ShortcutMatcher.carbonEffectiveModifiers))
  }

  /// A key code and modifiers given as numbers, with no key event around them (the dev control
  /// door): a modifier-only key code is a standalone modifier, anything else is a chord. macOS
  /// reports a modifier key's own press as a `.flagsChanged` event, which `HotkeyCapture`
  /// treats as standalone, so this reads the numbers the way the screen stores that key.
  nonisolated static func binding(keyCode: UInt16, modifiers: NSEvent.ModifierFlags)
    -> ShortcutBinding
  {
    let stored = normalized(
      keyCode: keyCode, modifiers: modifiers,
      standaloneModifier: ModifierKeyCodes.isModifierOnly(keyCode))
    return .keyboard(keyCode: stored.keyCode, modifiers: stored.modifiers)
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
