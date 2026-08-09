import Foundation

/// #1987 — every user-facing string for the Globe-key guidance popover.
///
/// Same shape as `LiveTranscriptionCopy` (#1337) and `SpokenPunctuationCopy`
/// (#1794): one namespace owning the copy, frozen by tests so a change is a
/// conscious act rather than drift. Stateless. No persistence, no preference
/// reads, no behaviour.
///
/// **THE COPY IS FOUNDER-APPROVED VERBATIM (2026-08-08). DO NOT REWORD IT.**
/// Three properties of it are load-bearing and a later edit must preserve them:
///
/// 1. It does NOT assert a conflict exists. `#1987` deliberately reads no macOS
///    preference, so "may already use" is the only honest phrasing. Changing it to
///    "is using" would be wrong for every user who already freed the key.
/// 2. It reassures before it instructs. The closing line answers the question the
///    popover itself provokes, which is "did my shortcut fail to save?".
/// 3. It quotes macOS verbatim. "Press 🌐 key to" and "Do Nothing" are the exact
///    on-screen labels, so the user does no translation.
///
/// The founder also explicitly DECLINED adding a Toggle-mode line here: the
/// popover's single job is telling people they can disable the emoji or language
/// shortcut. That pointer belongs in the help article, where length is free.
///
/// Brand rule: no em-dashes or en-dashes.
enum GlobeKeyCopy {
  static let title = "Free up the Globe key"

  static let body =
    "macOS may already use the Globe key to switch keyboard languages or open the "
    + "emoji picker. If that happens while you dictate, you can turn it off:"

  static let steps = [
    "Open System Settings, then Keyboard",
    "Click the \"Press 🌐 key to\" menu",
    "Choose \"Do Nothing\"",
  ]

  static let reassurance =
    "Your Globe key is set as your dictation shortcut either way. This only stops "
    + "macOS doing its own thing at the same time."

  static let dismissButton = "Got it"

  /// Spoken container label. VoiceOver reads this before the body, so it must say
  /// what the popover IS rather than repeat the title verbatim.
  static let accessibilityLabel = "Free up the Globe key. Setup tip."
}
