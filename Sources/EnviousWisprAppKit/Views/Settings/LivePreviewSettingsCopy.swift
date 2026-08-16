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

  /// Says four things, in the order a user cares about them: what they will see,
  /// where that text goes, that it is not what gets pasted, and that it costs them
  /// nothing in accuracy. The last is the one that stops "is this making my
  /// transcription worse?", the natural next question once they know two engines
  /// are running.
  ///
  /// The privacy sentence is here because #1988 asks for it in writing ("It should
  /// be trivially yes (nothing leaves the Mac), but state it"). Trivially true is
  /// not the same as visible: a user deciding whether to switch on something that
  /// watches them speak should not have to infer the answer from our reputation,
  /// and this is the only surface they read before deciding. It is also the one
  /// place the claim can be made narrowly and honestly, since this preview really
  /// is on-device for every user, with no cloud variant to qualify.
  /// Keeps "preview only" verbatim. The reviewer's proposed replacement dropped
  /// that phrase, which a frozen test requires and which carries the disclaimer
  /// this copy exists for, so the privacy sentence is added ALONGSIDE it rather
  /// than in place of it.
  static let toggleDescription =
    "See your words appear in the recording pill as you talk, so you know "
    + "EnviousWispr is hearing you. This is a preview only. It stays on your Mac "
    + "and is discarded when the recording ends. The text that gets pasted is "
    + "still produced by your chosen engine after you finish, so turning this on "
    + "does not change a single character of your result."

  /// Shown under the disabled toggle on older systems. Names the requirement and
  /// stops there: a user on macOS 14 cannot act on this beyond upgrading, and a
  /// longer explanation would read as an apology.
  static let needsNewerMacOS =
    "On-screen preview needs macOS 26 or later. Dictation itself works on macOS 14 and up."

  // MARK: - Language packs (#2080)

  static let packsHeader = "Languages"

  /// Explains the thing a user is otherwise left to infer: their Mac has only some
  /// of these, the missing ones are a download, and we will not take that decision
  /// for them. No size promise beyond "about" — Apple reports none, and the figure
  /// below is ours, measured, not theirs.
  static let packsDescription =
    "Apple provides the speech for the on-screen preview. Your Mac already has some "
    + "languages; the rest are about 140 MB each and download only when you ask. "
    + "Nothing downloads on its own."

  static let packInstalled = "Ready"
  static let packInstall = "Download"
  static let packInstalling = "Downloading"
  static let packRetry = "Try again"

  /// Placeholder and empty state for the language search. Wording matches `LanguageLockSheet`
  /// verbatim: the app already has a language search and a second phrasing for the same job would
  /// read as a different feature.
  static let packsSearchPlaceholder = "Search by name or code"
  static let packsNoSearchMatch = "No language matches your search."

  /// Shown while the list is being read, which is two local inventory reads and moves
  /// no bytes over the network.
  ///
  /// **Deliberately NOT `packInstalling`.** Reusing "Downloading" here made every
  /// supported Mac open this page announcing a download that was not happening, which
  /// contradicts the promise three lines above it. A spinner is not a transfer, and a
  /// page that cries download while idle teaches the user to disbelieve the word when
  /// it is true.
  static let packsLoading = "Checking which languages are on this Mac"

  /// Shown when the list itself could not be read. Distinct from an empty list on
  /// purpose: "we could not ask your Mac" and "your Mac supports none" are
  /// different facts, and showing an empty list for the first would be a lie.
  static let packsUnavailable =
    "Could not read the language list from macOS. Reopen this page to try again."

  /// Shown when one download fails. Says what to do rather than what went wrong,
  /// because the causes (offline, disk, Apple's servers) all have the same remedy.
  static let packInstallFailed =
    "That download did not finish. Check your connection and try again."

  /// In the recording pill when the chosen language has no pack yet.
  ///
  /// Follows the precedent already shipping in `DictationNarrator.modelNotDownloaded`
  /// ("... isn't downloaded yet. Open Settings to download it."), so the app says
  /// this the same way twice rather than inventing a second phrasing. Names the
  /// language, because "a language" sends the user hunting through 54 rows.
  ///
  /// Length is a MEASUREMENT, not a guess: the pill caps this state at two lines
  /// (`RecordingOverlayPanel`), and every one of the 54 languages has to fit. See
  /// the plan's §14.
  static func previewNeedsLanguagePack(_ languageName: String) -> String {
    "\(languageName) isn't downloaded yet. Open Settings to download it."
  }
}
