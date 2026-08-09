import Foundation
import Testing

@testable import EnviousWisprAppKit

/// #1987 — freezes the founder-approved Globe-key guidance copy.
///
/// The founder reviewed and approved this text verbatim on 2026-08-08, including
/// the deliberate decision NOT to mention Toggle mode. These tests exist so a
/// later edit is a conscious act rather than drift, matching the precedent set by
/// `LiveTranscriptionCopyTests` (#1337).
@Suite struct GlobeKeyCopyTests {

  @Test("Title and dismiss button are frozen")
  func frozenChrome() {
    #expect(GlobeKeyCopy.title == "Free up the Globe key")
    #expect(GlobeKeyCopy.dismissButton == "Got it")
  }

  /// Load-bearing property 1: we deliberately read no macOS preference, so we
  /// cannot know a conflict exists. "may already use" is the only honest phrasing;
  /// "is using" would be wrong for every user who already freed the key.
  @Test("The body does not assert that a conflict exists")
  func bodyDoesNotAssertAConflict() {
    // Exact equality, not a substring: a substring check passes when text is
    // ADDED, which is precisely how approved copy drifts.
    #expect(
      GlobeKeyCopy.body
        == "macOS may already use the Globe key to switch keyboard languages or open the "
        + "emoji picker. If that happens while you dictate, you can turn it off:")
    #expect(!GlobeKeyCopy.body.contains("is using"))
    #expect(!GlobeKeyCopy.body.lowercased().contains("conflict"))
  }

  /// Load-bearing property 2: the closing line answers the question the popover
  /// itself provokes, which is "did my shortcut fail to save?".
  @Test("The copy reassures that the shortcut is set either way")
  func reassuranceIsPresent() {
    #expect(
      GlobeKeyCopy.reassurance
        == "Your Globe key is set as your dictation shortcut either way. This only stops "
        + "macOS doing its own thing at the same time.")
  }

  /// Load-bearing property 3: the steps quote macOS verbatim, so the user does no
  /// translation between our words and the labels on their screen.
  @Test("The steps quote the exact macOS labels")
  func stepsQuoteMacOSVerbatim() {
    // The complete ordered array, so a reordering or an inserted step fails too.
    #expect(
      GlobeKeyCopy.steps == [
        "Open System Settings, then Keyboard",
        "Click the \"Press 🌐 key to\" menu",
        "Choose \"Do Nothing\"",
      ])
  }

  /// Founder decision, 2026-08-08: the popover stays single-purpose. The
  /// Toggle-mode pointer belongs in the help article, where length is free. This
  /// test exists so a well-meaning later round cannot quietly add it back.
  @Test("No Toggle-mode line was added to the popover")
  func noToggleModeLine() {
    let all =
      ([GlobeKeyCopy.title, GlobeKeyCopy.body, GlobeKeyCopy.reassurance]
      + GlobeKeyCopy.steps).joined(separator: " ")
    #expect(!all.lowercased().contains("toggle"))
  }

  /// Brand rule: no em-dashes or en-dashes in user-facing copy.
  @Test("No em-dashes or en-dashes anywhere in the copy")
  func noDashes() {
    let all =
      ([
        GlobeKeyCopy.title, GlobeKeyCopy.body, GlobeKeyCopy.reassurance,
        GlobeKeyCopy.dismissButton, GlobeKeyCopy.accessibilityLabel,
      ]
      + GlobeKeyCopy.steps).joined(separator: " ")
    #expect(!all.contains("\u{2014}"))
    #expect(!all.contains("\u{2013}"))
  }

  /// VoiceOver must not have to interpret an emoji to know what this popover is.
  @Test("The spoken container label is words, not the emoji")
  func spokenLabelIsWords() {
    #expect(GlobeKeyCopy.accessibilityLabel == "Free up the Globe key. Setup tip.")
    #expect(!GlobeKeyCopy.accessibilityLabel.contains("🌐"))
  }
}
