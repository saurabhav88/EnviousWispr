import EnviousWisprCore
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
  /// **The feature's name, settled 2026-08-18.**
  ///
  /// This said "On-screen Preview" while the sidebar and page title said
  /// "Live Preview" (`SettingsSection.swift`), so the page called itself two
  /// things. The older draft gave up the word "live" to avoid colliding with the
  /// "Live transcription" setting, which is the confusion #1988 was filed about
  /// — but the nav had already taken the word back, in the two most visible
  /// places on the page, where the copy guard could not see it.
  ///
  /// Founder decision: Live Preview everywhere. The collision is answered by
  /// renaming the OTHER setting to "Faster Transcription" (#2155, ships
  /// immediately after this), not by this one staying nameless.
  static let sectionHeader = "Live Preview"

  /// The hero card's headline.
  ///
  /// **Deliberately does not assert that the feature is on.** The mockup read
  /// "Real-time feedback, always on"; it ships OFF with its switch directly
  /// below, so that headline is false the first time anybody opens this page.
  static let heroTitle = "Watch your words appear as you talk"

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
  /// Trimmed once the Preview Language section existed: between them the page opened with six
  /// lines of prose before anything actionable. Keeps the three claims that matter — what it does,
  /// that it stays local, and that it cannot alter the result — and drops the restatement of
  /// "preview", which the heading above it already says.
  ///
  /// The third claim is the load-bearing one and may not be dropped by any future rewording: a
  /// user who concludes the preview IS the pasted text will file a bug that is not one, because
  /// the preview is measurably less accurate than the engine that produces the paste. An earlier
  /// draft carried it as the phrase "preview only"; this one carries it as "never changes a
  /// character of what gets pasted". `LivePreviewSettingsCopyTests` accepts either wording and
  /// fails if a rewrite drops the claim entirely.
  static let heroBody =
    "See your words in the recording pill as you talk, so you know EnviousWispr is hearing you. "
    + "It stays on your Mac, is discarded when the recording ends, and never changes a character "
    + "of what gets pasted."

  /// The one line under the switch. The three claims above moved to `heroBody`
  /// when the hero card took the top of the page (#2154); this is the mockup's
  /// own wording for the row that remains.
  static let toggleDescription = "See your words in the recording pill as you talk."

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

  // MARK: - Which language is live (#2080)

  /// Names what the section CONTAINS, like "Live Preview" and "Languages" either side of it.
  /// "Right Now" named a moment instead, which told the reader nothing about what they would find.
  static let activeHeader = "Preview Language"

  /// States the language, not the mechanism. "Resolved locale" is our word, not the user's.
  static func activeReady(_ name: String) -> String {
    "Your words will appear in \(name)."
  }

  /// Where that came from, so the user knows which setting to change if it is wrong.
  ///
  /// **Auto is not symmetrical, and saying it was would have been a false claim.** Dictation on
  /// Auto detects the language you actually speak (`RecordingSessionKernel` sends no language at
  /// all). The preview cannot: Apple's transcriber is built for one locale chosen before the first
  /// word, so it uses the Mac's language. A bilingual user on Auto therefore gets correct
  /// dictation and a preview in the wrong language, which is exactly the "the preview is not the
  /// pasted text" confusion this feature's copy exists to prevent. Naming the Mac as a guess is
  /// what makes that legible instead of a bug report.
  static func activeSource(_ mode: LanguageMode) -> String {
    switch mode {
    case .auto:
      return "Your dictation language is set to Auto, so the preview goes by your Mac's language."
    case .locked:
      return "Following the language you picked for dictation."
    }
  }

  static func activeNeedsDownload(_ name: String) -> String {
    "\(name) isn't downloaded yet, so you won't see words while you speak."
  }

  static let activeNeedsDownloadHelp = "Download it below and the preview starts working."

  static let activeUnsupportedLanguage =
    "Apple can't preview the language you picked for dictation."
  static let activeUnsupportedLanguageHelp =
    "Dictation still works normally. Only the on-screen preview is unavailable."

  /// Explains WHERE the preview language comes from, because the page shows which one is live but
  /// cannot change it — and a status you cannot act on is a dead end unless it says where to go.
  ///
  /// States the rule rather than the mechanism, and states the ONE case where the rule bends. An
  /// earlier draft said the preview always uses your dictation language, full stop; that reads
  /// cleanly and is untrue on Auto, where dictation detects what you speak and the preview has to
  /// commit to a locale in advance. See `activeSource` for the measurement behind that.
  static let activeExplainer =
    "The preview follows the language you pick for dictation, under Transcription. On Auto there "
    + "is nothing to follow yet, so it goes by your Mac's language: dictation still understands "
    + "whatever you speak, but the words on screen may appear in the wrong language until you "
    + "pick one."

  /// The row that is genuinely in use, as opposed to merely present. With nine languages
  /// installed, "Ready" on all of them said nothing about which one you are previewing in.
  static let packInUse = "In use"

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

  // MARK: - Status card (#2154)

  /// The card's right column, one label + one detail per state.
  /// `LivePreviewStatusMapping` owns which one is shown; this owns the words.
  ///
  /// **Every label here claims READINESS and none claims that words are on
  /// screen.** A correctly configured preview still shows nothing when the user
  /// speaks a language it is not set to (`live-preview.md`
  /// RULE: a-language-mismatch-shows-NOTHING-not-garbage), so "showing your
  /// words" would be a promise this page cannot keep.

  static let statusActiveLabel = "Live Preview is active"
  static let statusActiveDetail = "Ready to show your words while you speak."

  static let statusOffLabel = "Live Preview is off"
  static let statusOffDetail = "Switch it on to see your words while you speak."

  static let statusUnavailableLabel = "Not available on this Mac"
  static let statusUnavailableDetail =
    "Dictation itself works normally. Only the on-screen preview is unavailable."

  static let statusNeedsMacOS26Label = "Apple's engine needs macOS 26"
  static let statusNeedsMacOS26Detail =
    "Pick the Universal engine below, which works on macOS 14 and later."

  static let statusCheckingLabel = "Checking"
  static let statusCheckingDetail = "Reading which languages are on this Mac."

  static func statusNeedsLanguageLabel(_ languageName: String) -> String {
    "\(languageName) isn't downloaded yet"
  }
  static let statusNeedsLanguageDetail = "Download it in the list below and the preview starts working."

  static let statusUnsupportedLanguageLabel = "Apple can't preview this language"
  static let statusUnsupportedLanguageDetail =
    "Dictation still works normally. Try the Universal engine instead."

  static let statusNeedsDownloadLabel = "Needs a download"
  static let statusNeedsDownloadDetail = "Get the Universal engine from the card below."

  static let statusGettingReadyLabel = "Getting ready"
  static let statusGettingReadyDetail = "The Universal engine is downloading."

  static let statusDownloadFailedLabel = "Download did not finish"
  static let statusDownloadFailedDetail = "Check your connection and try again below."

  static let statusBuildCannotRunLabel = "Can't run that engine"
  static let statusBuildCannotRunDetail =
    "This version of EnviousWispr is missing that engine's files. Pick Apple instead."

  /// **One of exactly TWO strings permitted to name the other feature** (with
  /// `statusPausedDetail` below), the closed exception in
  /// `liveOnlyAppearsInApprovedProductNames`'s allowlist.
  ///
  /// It names Live transcription as the REASON for the pause rather than
  /// calling this preview by that name, which is the distinction the guard
  /// draws. When #2155 renames that setting to "Faster Transcription", this
  /// string and the test's exception change together, in that PR.
  ///
  /// Why the pause exists: the universal preview refuses to run while the heart
  /// decodes continuously, because concurrent decode was measured costing
  /// transcription 1.50x. Yielding is the design, not a defect.
  static let pausedForLiveTranscription = "Paused while Live transcription is on"
  static let statusPausedDetail =
    "Your dictation keeps its full speed. Turn Live transcription off to see the preview."

  // MARK: - Language section (#2154)

  static let changeLanguageButton = "Change"

  /// Says the consequence out loud. Picking a language here is not a
  /// preview-only setting: it sets the DICTATION language, on a different page.
  /// A button that silently edits another page's setting is how a user loses
  /// auto-detect without noticing.
  static let changeLanguageHelp =
    "This sets the language for dictation too, not just the preview."

  // MARK: - Language table (#2154)

  static let tableColumnLanguage = "Language"
  static let tableColumnSource = "Source"
  static let tableColumnStatus = "Status"

  /// Where a language came from. "System" means it arrived with macOS; "Apple"
  /// means it is one of Apple's downloads. Both are Apple's packs — the column
  /// answers "do I already have this", which is what the user is scanning for.
  static let sourceSystem = "System"
  static let sourceApple = "Apple"
}
