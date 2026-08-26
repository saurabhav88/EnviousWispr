import EnviousWisprCore
import EnviousWisprServices

/// What the Live Preview status bar shows, as a value rather than a layout (#2436).
///
/// **Why a presentation type and not just a `body`.** The bar replaces three
/// containers that each used to decide something for themselves — the hero card's
/// status column, the toggle row, and the language panel. Those three disagreeing
/// with each other is the entire history of this page: rounds r8 and r9 of #2154
/// were the same defect twice, a second surface deciding readiness for itself and
/// contradicting the card four points above it. A pure mapping is the only shape
/// where "these two surfaces cannot disagree" is a property a test can hold,
/// because a SwiftUI `body` cannot be asserted without rendering it.
///
/// **This type decides NOTHING about readiness.** `LivePreviewStatusMapping` owns
/// that, alone, and this re-shapes the answer it already gave. If a future change
/// finds itself asking here whether the preview will work, the question belongs one
/// file over.
enum LivePreviewStatusBarPresentation {

  /// The language and where it came from, stacked under one another in the bar.
  ///
  /// **Provenance is not decoration.** On Auto the preview cannot follow the
  /// dictation language the way a user assumes: dictation detects what they
  /// actually speak, while this preview must commit to one locale before the first
  /// word and so uses the Mac's. Saying only "German" invites the reading that they
  /// chose it. `LivePreviewSettingsCopy.pickerAppleCaveat` states that asymmetry in
  /// full, at the moment somebody acts on the language; an earlier draft of the copy it
  /// replaced claimed the symmetrical version and was wrong.
  struct Language: Equatable {
    let name: String
    let provenance: String
  }

  /// The single remedy the bar may offer.
  ///
  /// **One case, deliberately.** Every other unhappy state is repaired somewhere
  /// that already owns the control: the engine cards own download, cancel, resume,
  /// retry and remove, and Faster Transcription is turned off on its own page. A
  /// second button here would be a second owner for an action that already has one.
  enum Action: Equatable {
    /// Opens the pack catalogue, already searched for the language that is missing.
    ///
    /// Carries a display NAME rather than an install tag because
    /// `ActiveLanguage.needsDownload` has no tag to give (`LivePreviewPacksModel`),
    /// and inventing a reverse lookup from a localized display name back to a pack
    /// identifier would be a new failure mode in exchange for saving one tap.
    case browseDownloads(initialSearch: String)
  }

  /// Everything the bar draws.
  ///
  /// `detail` is NOT optional. An earlier draft of #2436 hid it while the preview
  /// was working, reasoning that a green dot and a language chip already said so.
  /// `LivePreviewStatusMappingTests.noLabelPromisesVisibleWords` refutes that from
  /// the other direction: it carries a positive control requiring the ready detail
  /// to contain "ready to show", the deliberately WEAKER claim, because a correctly
  /// configured preview still shows nothing when the user speaks a language it is
  /// not set to. "Activated" alone is a stronger promise than this page can keep.
  struct Bar: Equatable {
    let label: String
    let detail: String
    let language: Language?
    let action: Action?
  }

  /// Compose the bar.
  ///
  /// **The engine is an explicit parameter, and leaving it out was a real defect.**
  /// `appleActive` is Apple's pack resolution; it cannot describe the universal
  /// engine at all, which resolves its language from the lock and nothing else. A
  /// signature taking only the resolved Apple value could not have produced a
  /// universal language, and would have reused Apple state to describe an engine
  /// that never reads it. Grounded review r2 on #2436.
  static func bar(
    summary: LivePreviewStatusMapping.Summary,
    engine: LivePreviewEngineChoice,
    appleActive: LivePreviewPacksModel.ActiveLanguage?,
    languageMode: LanguageMode
  ) -> Bar {
    Bar(
      label: summary.chip.label,
      detail: summary.detail,
      language: language(
        kind: summary.kind, engine: engine, appleActive: appleActive,
        languageMode: languageMode),
      action: action(for: summary.kind))
  }

  // MARK: - Language

  /// **Named only when naming it is true.** Three of the states describe a preview
  /// that cannot run at all — the engine is missing from the build, the Mac is too
  /// old, or we have not finished reading the inventory. A language beside any of
  /// those reads as a promise about words that will not appear, which is the exact
  /// claim `RULE: the-status-card-may-only-claim-what-its-inputs-prove` forbids.
  /// Hidden, never rendered empty: an empty chip reads as a resolved language whose
  /// name we lost.
  private static func language(
    kind: LivePreviewStatusMapping.Kind,
    engine: LivePreviewEngineChoice,
    appleActive: LivePreviewPacksModel.ActiveLanguage?,
    languageMode: LanguageMode
  ) -> Language? {
    switch kind {
    case .buildCannotRun, .needsMacOS26, .checking:
      return nil
    case .active, .off, .needsLanguage, .unsupportedLanguage, .needsDownload,
      .gettingReady, .downloadFailed, .paused:
      break
    }

    switch engine {
    case .apple:
      return appleLanguage(appleActive, languageMode: languageMode)
    case .universal:
      return universalLanguage(languageMode)
    }
  }

  /// Apple's language comes from the staleness-aware resolved value and nowhere
  /// else. Reading `packs.active` directly is the #2154 r3 defect, where three
  /// surfaces shared one guard and a value resolved for a language the user had
  /// already left kept describing two of them.
  private static func appleLanguage(
    _ active: LivePreviewPacksModel.ActiveLanguage?,
    languageMode: LanguageMode
  ) -> Language? {
    guard let active else { return nil }
    switch active {
    case .ready(_, let name), .needsDownload(let name):
      return Language(name: name, provenance: provenance(for: languageMode))
    case .unsupportedLanguage:
      // **The control that UNSTRANDS the user must not be hidden by the state that
      // stranded them.** Apple cannot preview this language, the language chip IS
      // the picker, and returning nil here removed the only way to change it from
      // this page — leaving a user whose preview is broken BY their language with
      // no control on the page that could fix it. Cloud review on PR #2440.
      //
      // `universalLanguage` two functions down already carries this exact reason,
      // from #2154 review r7, which hid the control on Universal and stranded
      // exactly those users. The reason was written down and applied to one branch
      // of two — so the shared derivation below is the fix, not a second copy of
      // the sentence (`workflow-process.md` RULE: fix-the-path-that-runs-first-not-the-one-you-were-reading,
      // "name the TWIN of every site you change").
      //
      // The name comes from the LOCK rather than from `active`, because
      // `ActiveLanguage.unsupportedLanguage` carries none — and the lock is what
      // made it unsupported, so it is also the honest thing to name.
      return languageFromLock(
        languageMode, autoProvenance: LivePreviewSettingsCopy.languageProvenanceFromMac)
    case .unsupportedSystem:
      // Unreachable in practice — that value maps to `.needsMacOS26`, which the
      // caller already returned nil for — and correct to hide regardless: no
      // control on this page changes the macOS version, so offering the picker
      // would imply a remedy that does not exist. The engine card says why.
      return nil
    }
  }

  /// The universal engine resolves its language from the lock alone, so it needs no
  /// pack state and is always representable. **It must not stay silent**: this
  /// engine honours a lock, and the row's whole purpose is that a user locked to the
  /// wrong language can see it and change it. An earlier #2154 draft hid the control
  /// on this engine and stranded exactly those users (review r7).
  private static func universalLanguage(_ mode: LanguageMode) -> Language {
    languageFromLock(
      mode, autoProvenance: LivePreviewSettingsCopy.languageProvenanceDetected)
  }

  /// The language derived from the LOCK alone, for every state where pack
  /// resolution cannot name one but the user must still be able to change it.
  ///
  /// **Only the Auto provenance differs between its two callers, and that
  /// difference is the whole Auto asymmetry**: Apple's preview picks one locale
  /// before the first word and takes it from the Mac, so `from your Mac`; the
  /// universal engine pins nothing, so `no language pinned`. Passing it in keeps
  /// one derivation with one honest parameter rather than two functions that
  /// agree today.
  private static func languageFromLock(
    _ mode: LanguageMode, autoProvenance: String
  ) -> Language {
    switch mode {
    case .auto:
      return Language(
        name: LivePreviewSettingsCopy.languageAnyLanguage, provenance: autoProvenance)
    case .locked(let code):
      return Language(
        name: LanguageCatalog.entry(for: code).englishName,
        provenance: LivePreviewSettingsCopy.languageProvenanceUserPicked)
    }
  }

  private static func provenance(for mode: LanguageMode) -> String {
    switch mode {
    case .auto: return LivePreviewSettingsCopy.languageProvenanceFromMac
    case .locked: return LivePreviewSettingsCopy.languageProvenanceUserPicked
    }
  }

  // MARK: - Action

  /// **Switched on `kind`, never on copy.** The only other discriminator on a
  /// `Summary` is `chip.label`, and branching on that would make a user-facing
  /// sentence into a behavioural API: a copy edit would silently change what this
  /// button does, with no test standing between the two. `Kind` exists for this.
  private static func action(for kind: LivePreviewStatusMapping.Kind) -> Action? {
    switch kind {
    case .needsLanguage(let name):
      return .browseDownloads(initialSearch: name)
    case .active, .off, .needsMacOS26, .checking, .unsupportedLanguage,
      .needsDownload, .gettingReady, .downloadFailed, .buildCannotRun, .paused:
      return nil
    }
  }
}
