import AppKit

/// #1987 — which shortcut key a hotkey event belongs to, as a content-free class.
///
/// The existing `key_shape` property answers "modifier-only or chord", which puts
/// the Globe key in the same bucket as Right Option and six other keys. That bucket
/// cannot answer the only question worth asking after shipping a top-requested
/// shortcut: did anyone actually choose it.
///
/// **Never emit a raw key code.** A key code is closer to keystroke content than
/// anything belongs in telemetry, and these four classes answer every question we
/// actually have. Privacy boundary per CLAUDE.md: this is shape, not content, and
/// no dictated text, transcript, or surrounding document text is involved.
///
/// One authority for the vocabulary, so the four values are not re-derived at each
/// emit site. Adding a ninth standalone key later without adding a case here lands
/// it in `otherModifier`, which is the correct default and a conscious call rather
/// than a silent one.
package enum HotkeyKeyIdentity: String, Sendable {
  case globe
  case rightOption = "right_option"
  case otherModifier = "other_modifier"
  case chord

  /// Order matters: the two keys we report on by name are checked first, then the
  /// remaining standalone modifiers, then everything else.
  package static func classify(keyCode: UInt16) -> Self {
    if keyCode == ModifierKeyCodes.globe { return .globe }
    if keyCode == ModifierKeyCodes.rightOption { return .rightOption }
    if ModifierKeyCodes.isModifierOnly(keyCode) { return .otherModifier }
    return .chord
  }
}
