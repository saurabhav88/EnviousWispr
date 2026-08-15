import Foundation
import Testing

@testable import EnviousWisprAppKit

/// #1988 — freezes the live-preview setting's user-facing copy, mirroring
/// `LiveTranscriptionCopyTests`.
///
/// This issue exists partly BECAUSE a setting's name promised something the code
/// did not do, so the copy that replaces it earns the same protection: a change
/// here should be a conscious act, not drift.
@MainActor
struct LivePreviewSettingsCopyTests {

  private var allStrings: [String] {
    [
      LivePreviewSettingsCopy.sectionHeader,
      LivePreviewSettingsCopy.toggleLabel,
      LivePreviewSettingsCopy.toggleDescription,
      LivePreviewSettingsCopy.needsNewerMacOS,
      LivePreviewCopy.needsNewerMacOS,
      LivePreviewCopy.languageUnsupported,
      LivePreviewCopy.notReady,
      LivePreviewCopy.preparing,
      LivePreviewCopy.listening,
    ]
  }

  /// Brand rule: no em-dashes or en-dashes in user-facing copy.
  @Test("No user-facing string carries an em-dash or en-dash")
  func noDashes() {
    for s in allStrings {
      #expect(s.contains("\u{2014}") == false, "em-dash in user-facing copy: \(s)")
      #expect(s.contains("\u{2013}") == false, "en-dash in user-facing copy: \(s)")
    }
  }

  @Test("No user-facing string is empty")
  func noEmptyStrings() {
    for s in allStrings {
      #expect(s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
    }
  }

  /// The whole point of this feature's copy. A user who reads the description must
  /// not be able to conclude that the preview is what gets pasted, because the
  /// preview is measurably less accurate than the engine that does get pasted, and
  /// a user who believes otherwise will report a bug that is not one.
  @Test("The description says the preview is not the pasted text")
  func descriptionDisclaimsThePastedText() {
    let d = LivePreviewSettingsCopy.toggleDescription.lowercased()
    #expect(d.contains("preview only"))
    #expect(d.contains("pasted"))
  }

  /// Two adjacent settings both calling themselves "live" is the confusion this
  /// issue was filed about. Renaming the OLDER one was measured and rejected for
  /// this PR: the phrase appears 30 times across the app, three live website pages,
  /// and a help article whose title and URL slug ARE the name, which makes it a
  /// public-URL decision rather than a copy tweak (#1988 Part 1). So the NEW
  /// setting gives up the word instead, and this test is what keeps it given up.
  /// Every string the preview shows, not just its two labels. A pill that says
  /// "Live preview needs macOS 26" under a setting called "On-screen Preview" is
  /// the same confusion re-entering by the back door, and the pill strings are the
  /// ones nobody re-reads.
  @Test("No preview string calls itself live")
  func previewNeverCallsItselfLive() {
    for s in allStrings {
      #expect(
        s.lowercased().contains("live") == false,
        "the preview's copy must not reuse the word the streaming toggle owns: \(s)")
    }
  }

  /// Both engine descriptions must carry the sentence that separates "when the work
  /// happens" from "what you can see". A clarification landing on only one of two
  /// engines is the partial port this codebase keeps relearning.
  @Test("Both engine descriptions say nothing looks different while recording")
  func bothEnginesDisambiguate() {
    for description in [
      LiveTranscriptionCopy.parakeetToggleDescription,
      LiveTranscriptionCopy.whisperKitToggleDescription,
    ] {
      #expect(
        description.lowercased().contains("nothing looks different"),
        "each engine's copy must separate this setting from Live Preview: \(description)")
    }
  }
}
