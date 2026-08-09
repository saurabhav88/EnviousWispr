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
        == "macOS may already use the Globe key to switch keyboard languages, open the "
        + "emoji picker, or start its own dictation. If that happens while you dictate, "
        + "you can turn it off:")
    #expect(!GlobeKeyCopy.body.contains("is using"))
    #expect(!GlobeKeyCopy.body.lowercased().contains("conflict"))
  }

  /// Founder amendment, 2026-08-09. The "Press 🌐 key to" menu offers three actions
  /// besides Do Nothing, and the body must name all three. The original named two
  /// and dropped Start Dictation, which is the one that takes the microphone and so
  /// the one most likely to read as our bug.
  ///
  /// Asserted as membership rather than by re-stating the sentence, because the
  /// failure this guards against is an OMISSION: a future rewrite that drops a
  /// member would still satisfy an exact-equality check written against itself.
  @Test("The body names every action the macOS menu can take")
  func bodyNamesEveryMacOSAction() {
    let body = GlobeKeyCopy.body.lowercased()
    #expect(body.contains("keyboard languages"))
    #expect(body.contains("emoji picker"))
    #expect(body.contains("dictation"))
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
