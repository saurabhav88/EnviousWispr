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

  static let toggleLabel = "Show words while I speak"

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

  static let statusActiveLabel = "Activated"
  static let statusActiveDetail = "Ready to show your words while you speak."

  static let statusOffLabel = "Off"
  /// **Deliberately promises nothing about what happens next.** The off state is
  /// checked BEFORE any engine detail, so switching on can land straight on
  /// "needs a download" or a missing language pack. An earlier draft said
  /// "switch it on to see your words while you speak", which is a promise this
  /// card cannot keep for every user who reads it.
  static let statusOffDetail = "Switch it on and this bar will show whether anything else is needed."

  // `statusUnavailableLabel` / `statusUnavailableDetail` were DELETED by #2154's
  // final sweep, not merely unused. "Not available on this Mac" was returned
  // from a guard reached by an OR of two independent causes — an old macOS and a
  // defective app package — so it could not name either, and it accused the
  // user's hardware for a build we shipped wrong. Each engine now answers with
  // its own reason. Do not reintroduce a generic both-unavailable sentence: the
  // condition that would produce it has no single honest wording.

  static let statusNeedsMacOS26Label = "Apple's engine needs macOS 26"
  /// Two details, for the same reason `statusUnsupportedLanguageDetail` has two:
  /// pointing at the Universal card is only useful when that card can actually
  /// help. A build shipped without its files makes the advice a dead end.
  static let statusNeedsMacOS26Detail =
    "Pick the Universal engine below, which works on macOS 14 and later."
  static let statusNeedsMacOS26DetailNoAlternative =
    "Dictation itself works normally. Only the on-screen preview is unavailable."

  static let statusCheckingLabel = "Checking"
  static let statusCheckingDetail = "Reading which languages are on this Mac."
  /// Shown while a language download is running, when the resolved language is
  /// stale by construction. True whichever language is downloading, which is
  /// what lets the card say it without knowing.
  static let statusInstallInFlightDetail =
    "A language download is in progress. This updates when it finishes."
  /// Shown when the dictation language changed while a download was running, so
  /// the resolved language describes the previous choice. Says what is true
  /// without pretending to know the new answer yet.
  static let statusLanguageChangedDetail =
    "Working out what your new language needs. This updates when the download finishes."

  static func statusNeedsLanguageLabel(_ languageName: String) -> String {
    "\(languageName) isn't downloaded yet"
  }
  static let statusNeedsLanguageDetail = "Use Browse downloads below to get it and start the preview."

  static let statusUnsupportedLanguageLabel = "Apple can't preview this language"
  /// **Two details, because the advice is only true when the other engine
  /// exists.** This state is reached with Apple selected and supported, which
  /// says nothing about whether the universal engine is composable in this
  /// build. Recommending it unconditionally would point a user at a card that
  /// cannot help them. Found by enumerating the class after two review rounds,
  /// not by either round.
  static let statusUnsupportedLanguageDetail =
    "Dictation still works normally. Try the Universal engine instead."
  static let statusUnsupportedLanguageDetailNoAlternative =
    "Dictation still works normally. Only the on-screen preview is unavailable for it."

  static let statusNeedsDownloadLabel = "Needs a download"
  static let statusNeedsDownloadDetail = "Get the Universal engine from the card below."

  static let statusGettingReadyLabel = "Getting ready"
  /// **State-neutral on purpose.** This label covers downloading, preparing AND
  /// verifying, and the last two can be pure local work on files already on
  /// disk. Saying "downloading" there announces a transfer that is not
  /// happening, which is the same defect `packsLoading` was split out to fix.
  static let statusGettingReadyDetail = "The Universal engine is being prepared."

  /// The label only. **The DETAIL comes from `ModelDeliveryCopy.message`**,
  /// because the right remedy depends on the reason: a full disk needs space
  /// freed, not a connection checked. One owner for that mapping, not two.
  static let statusDownloadFailedLabel = "Download did not finish"

  static let statusBuildCannotRunLabel = "Can't run that engine"
  static let statusBuildCannotRunDetail =
    "This version of EnviousWispr is missing that engine's files. Pick Apple instead."
  /// **The same defect with no fallback to offer, and it must not blame the
  /// Mac.** Reached on macOS 14 or 15 with the universal engine selected and its
  /// files missing: that Mac is perfectly capable of running this engine, and
  /// the only thing wrong is the package we shipped. Saying "not available on
  /// this Mac" there accuses the user's hardware for our mistake, and sends them
  /// looking for an upgrade that would not help.
  static let statusBuildCannotRunDetailNoAlternative =
    "This version of EnviousWispr is missing that engine's files. Updating the app should restore it."

  /// **One of exactly TWO strings permitted to name the other feature** (with
  /// `statusPausedDetail` below), the closed exception in
  /// `liveOnlyAppearsInApprovedProductNames`'s allowlist.
  ///
  /// It names Faster Transcription as the REASON for the pause rather than
  /// calling this preview by that name, which is the distinction the guard
  /// draws. When #2155 renames that setting to "Faster Transcription", this
  /// string and the test's exception change together, in that PR.
  ///
  /// Why the pause exists: the universal preview refuses to run while the heart
  /// decodes continuously, because concurrent decode was measured costing
  /// transcription 1.50x. Yielding is the design, not a defect.
  static let pausedForFasterTranscription = "Paused while Faster Transcription is on"
  static let statusPausedDetail =
    "Your dictation keeps its full speed. Turn Faster Transcription off to see the preview."

  /// **The claim that may not be dropped, moved rather than deleted (#2436).**
  ///
  /// This is `heroBody`'s third sentence, and its own doc comment is explicit that
  /// the pasted-text half "is the load-bearing one and may not be dropped by any
  /// future rewording: a user who concludes the preview IS the pasted text will file
  /// a bug that is not one, because the preview is measurably less accurate than the
  /// engine that produces the paste." The privacy half is here because #1988 asked
  /// for it in writing.
  ///
  /// **It renders under the status bar, not under the Languages block.** The
  /// Languages block is gated on `showsApplePacks`, so putting it there would delete
  /// the sentence on the universal engine and on every Mac too old for Apple's —
  /// while this is the only surface a user reads before deciding whether to switch
  /// on something that watches them speak.
  static let previewPrivacyFooter =
    "It stays on your Mac, is discarded when the recording ends, and never changes a "
    + "character of what gets pasted."

  // MARK: - Status-bar language chip (#2436)

  /// The universal engine's "language", which is the absence of one.
  ///
  /// It resolves per utterance rather than committing to a locale in advance, so
  /// there is no single language to name and "Any" is the honest noun.
  static let languageAnyLanguage = "Any language"

  /// **Where the language came from — CONFIGURATION only, never activity.**
  ///
  /// `languageProvenanceDetected` was "detected as you speak" and that was a readiness
  /// claim wearing a provenance label: the chip renders in every state, so it asserted
  /// live detection while the preview was off, paused, downloading or failed. "automatic"
  /// describes the SETTING, which is true whether or not anything is running. Found by
  /// chunk review on #2436, and `chipNeverPromisesOutput` missed it because its forbidden
  /// list did not contain "detect" — the guard and the defect had the same blind spot.
  ///
  /// **The Auto asymmetry is stated in `pickerDictationCaveat`, not here.**
  ///
  /// Dictation on Auto detects what you actually speak. Apple's preview cannot: it
  /// is built for one locale chosen before the first word, so it uses the Mac's.
  /// A bilingual user on Auto therefore gets correct dictation and a preview in the
  /// wrong language, and naming the Mac as the source is what makes that legible
  /// instead of a bug report. the deleted `activeSource` carried the same distinction in
  /// sentence form; these are its two-word shoulders for the status bar.
  static let languageProvenanceFromMac = "from your Mac"
  static let languageProvenanceUserPicked = "you picked this"
  /// "automatic", not "auto-detect": the guard forbids activity words and "detect" is
  /// one, even inside a setting's name. Arguing the matcher into an exception would
  /// have traded a real guard for one word — and the word is not load-bearing, since
  /// the picker this chip opens calls the same setting Automatic.
  static let languageProvenanceDetected = "automatic"

  /// **The universal engine follows a LOCK, and only auto-detects on Auto.**
  /// `WhisperPreviewEngineResolver` maps `.locked(code)` straight through to the
  /// recognizer and only `.auto` becomes nil. An earlier draft of this page hid
  /// the language control entirely on that engine, and the help article claimed
  /// it always detects for itself — both wrong in the same direction, and the
  /// user they stranded is the one locked to the wrong language with no way to
  /// see or change it from here. Cloud/local review r7.
  static func universalLocked(_ name: String) -> String {
    "Your words will appear in \(name)."
  }
  static let universalAuto = "The preview detects your language as you speak."

  /// **Paused variants. The row must DESCRIBE the configuration, never promise
  /// output, whenever the engine is refused.**
  ///
  /// `WhisperPreviewEngineResolver` returns `.blocked(.heartIsStreaming)` before
  /// it asks anything else, so with Faster Transcription streaming the universal
  /// preview will not run at all. The hero card reports that correctly. The row
  /// below it did not: it went on saying "Your words will appear in German" and
  /// "The preview detects your language as you speak" while nothing would appear
  /// and nothing was being detected, so one page stated a fact and denied it a
  /// few points lower. Cloud review r8.
  ///
  /// The split is present tense versus configuration. "Will appear" and
  /// "detects" are claims about what is happening NOW and only the resolver can
  /// license them; "is set to" is a claim about what the user chose, which stays
  /// true while paused and is exactly what the row exists to show — a user
  /// locked to the wrong language needs to SEE that lock most when the preview
  /// is not running to reveal it.
  ///
  /// Scoped to the universal engine deliberately. Apple's route cannot be
  /// blocked this way (`LivePreviewPacksModel` documents that refusal as
  /// unreachable for it), so `activeReady` keeps its promise and must not be
  /// "fixed" to match. Ref: live-preview.md RULE:
  /// the-status-card-may-only-claim-what-its-inputs-prove.
  static func universalLockedPaused(_ name: String) -> String {
    "The preview is set to \(name)."
  }
  static let universalAutoPaused =
    "The preview is set to detect your language as you speak."

  /// Says the consequence out loud. Picking a language here is not a
  /// preview-only setting: it sets the DICTATION language, on a different page.
  /// A button that silently edits another page's setting is how a user loses
  /// auto-detect without noticing.
  /// **Re-homed by #2436 from a help line under a Change button to the picker's own
  /// subtitle.** It states a CONSEQUENCE of the action, so it belongs where the action
  /// is taken rather than under a button nobody has pressed yet. `activeSummary`'s
  /// reason for it is carried verbatim in `LivePreviewSettingsView`: one language in
  /// one place, because two settings that can disagree hand the user a mismatch they
  /// cannot diagnose.
  static let pickerDictationCaveat =
    "This sets the language for dictation too, not just the preview. On Auto, dictation "
    + "detects whatever you speak, while the preview has to pick one language in advance "
    + "and uses your Mac's."

  // MARK: - Language table (#2154)

  static let tableColumnLanguage = "Language"
  static let tableColumnStatus = "Status"

  /// **Availability, NOT provenance, and the first draft got that wrong.**
  ///
  /// The column is computed from `isInstalled`, so downloading a language
  /// through this very page flipped it from "Apple" to "System" — claiming the
  /// pack had shipped with macOS when the user had just fetched it from Apple
  /// thirty seconds earlier. The model carries availability and knows nothing
  /// about origin, so the honest fix is to label what is actually computed.
  /// Every one of these is an Apple pack either way.
  static let tableColumnSource = "Availability"
  static let sourceSystem = "On this Mac"
  static let sourceApple = "Available from Apple"
}
