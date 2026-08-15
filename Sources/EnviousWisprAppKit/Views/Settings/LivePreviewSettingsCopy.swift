import Foundation

/// #1988: canonical copy for the "Live preview" setting.
///
/// Mirrors `LiveTranscriptionCopy` and `SpokenPunctuationCopy` in shape: one home
/// for every user-facing string, frozen by a test so a change is a conscious act.
///
/// **The description's job is to prevent the misunderstanding that prompted this
/// issue.** A real user turned on the setting called "Live transcription",
/// expected words to appear as he spoke, saw nothing, and asked whether the
/// feature was broken. So this copy says plainly what the preview is (something to
/// look at) and what it is not (the text you get). Anyone who reads it should not
/// be able to arrive at the wrong expectation.
///
/// Brand rule: no em-dashes or en-dashes in user-facing copy.
enum LivePreviewSettingsCopy {
  /// **Deliberately contains no "live".** The adjacent Transcription Mode section
  /// already owns that word, and two settings both calling themselves live is the
  /// confusion this issue was filed about. Renaming the OLDER one was measured and
  /// rejected as a public-URL change (see `LiveTranscriptionCopy.toggleLabel`), so
  /// the new setting is the one that gives up the word. "On-screen" also says the
  /// true thing about it: this changes what you SEE, nothing else.
  static let sectionHeader = "On-screen Preview"
  static let toggleLabel = "Show words while I speak"

  /// Says three things, in the order a user cares about them: what they will see,
  /// that it is not what gets pasted, and that it costs them nothing in accuracy.
  /// The third is the one that stops "is this making my transcription worse?",
  /// which is the natural next question once they know two engines are running.
  static let toggleDescription =
    "See your words appear in the recording pill as you talk, so you know "
    + "EnviousWispr is hearing you. This is a preview only. The text that gets "
    + "pasted is still produced by your chosen engine after you finish, so turning "
    + "this on does not change a single character of your result."

  /// Shown under the disabled toggle on older systems. Names the requirement and
  /// stops there: a user on macOS 14 cannot act on this beyond upgrading, and a
  /// longer explanation would read as an apology.
  static let needsNewerMacOS =
    "On-screen preview needs macOS 26 or later. Dictation itself works on macOS 14 and up."
}
