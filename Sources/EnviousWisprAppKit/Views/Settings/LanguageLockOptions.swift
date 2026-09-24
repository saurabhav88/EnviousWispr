import EnviousWisprASR
import EnviousWisprCore
import EnviousWisprServices
import Foundation

/// The single owner of "which language codes may this backend be locked to".
///
/// #2154. Lifted out of `SpeechEngineSettingsView`, where it was a `private`
/// computed property with three readers on that one page. Live Preview's Change
/// button opens the same `LanguageLockSheet` and needs the same set, and a
/// second page cannot reach a private property.
///
/// **Lifted rather than reproduced, and the distinction is the whole point.**
/// Offering a code outside this set is a SILENT failure: `ParakeetBackend`
/// records it at the source (`lockableLanguageCodes`) — an unclaimed code maps
/// to no vendor language, the decoder falls back to auto-detect, and the user
/// sees a lock they set and are not getting (#1678). A copied switch that later
/// drifts reintroduces exactly that, invisibly. This feature has already paid
/// for one partial port: `ApplePackCatalog` carried a second copy of the locale
/// claim logic without its evict-at-cap step, and the sixth Download silently
/// refused (`live-preview.md`
/// FACT: packs-are-user-installed-and-the-catalogue-is-the-sole-installer).
///
/// A free function on an enum rather than a property on a view, so it is pure,
/// has no `@MainActor` isolation, and can be tested without a running app.
enum LanguageLockOptions {

  /// Which languages the LIVE PREVIEW page's picker may offer.
  ///
  /// **Founder, 2026-08-18: the picker lists what you can switch to RIGHT NOW; the
  /// Languages table below it is the catalogue and the place you acquire one.**
  /// "We already have the download selector at the bottom, which is an endless
  /// scroll. It'd be silly for us to offer another option to download... if they
  /// download it from the bottom selection table, it should then pop up into the
  /// selector." So on Apple this is the INSTALLED set, and a table download makes
  /// a language appear here — which is why the caller derives
  /// `installedPackTags` from the packs model rather than snapshotting it.
  ///
  /// **It is an INTERSECTION, never a replacement, and that is load-bearing.**
  /// This picker sets the DICTATION language, so a code outside the ASR backend's
  /// lockable set is the #1678 silent failure: the lock looks set, the code maps
  /// to no vendor language, and the decoder quietly auto-detects. Narrowing to
  /// installed packs must therefore happen INSIDE that set, not instead of it.
  ///
  /// Universal is unrestricted by installs because it has none — one model covers
  /// every language it claims, so the only limit there is the backend's.
  ///
  /// Pack tags are BCP-47 (`de-DE`); catalogue codes are ISO (`de`). The language
  /// subtag is the join, lowercased, because Apple keys packs by locale and we
  /// lock by language.
  static func previewLockableCodes(
    backend: ASRBackendType,
    previewEngine: LivePreviewEngineChoice,
    installedPackTags: [String]
  ) -> Set<String>? {
    let backendCodes = lockableCodes(for: backend)
    guard previewEngine == .apple else { return backendCodes }

    let installed = Set(installedPackTags.compactMap(catalogueCode(forPackTag:)))

    // nil means "no restriction from the backend", so the install set becomes the
    // whole restriction rather than being discarded.
    guard let backendCodes else { return installed }
    return backendCodes.intersection(installed)
  }

  /// Apple's pack tag translated into this app's catalogue vocabulary, or nil if
  /// the language is not one we can lock to.
  ///
  /// **A bare `split(separator: "-").first` silently loses languages, and the loss
  /// is invisible.** Cloud review caught `nb-NO`: the subtag is `nb`, the catalogue
  /// exposes Norwegian as `no`, so a user who downloaded Norwegian from the table
  /// would not find it in the picker — breaking the exact promise this feature was
  /// built on ("if they download it from the bottom selection table, it should then
  /// pop up into the selector"). It fails as an ABSENCE, which is why no amount of
  /// looking at the picker would explain it.
  ///
  /// The aliases are the cases where Apple's vocabulary and ours genuinely differ:
  /// macro-language versus a specific written form, and the deprecated ISO codes
  /// Foundation still emits for historical identifiers.
  static func catalogueCode(forPackTag tag: String) -> String? {
    let subtag = Locale(identifier: tag).language.languageCode?.identifier
      ?? tag.split(separator: "-").first.map(String.init)
      ?? tag
    let lowered = subtag.lowercased()
    return packTagAliases[lowered] ?? lowered
  }

  /// Pack subtag -> catalogue code, ONLY where the two vocabularies disagree.
  ///
  /// Deliberately small and explicit rather than clever: a wrong entry here sends a
  /// user to a language they did not pick, which is worse than the row being
  /// missing. Every entry is asserted against `LanguageCatalog` by test, so an
  /// alias pointing at a code we do not carry fails the build rather than shipping.
  static let packTagAliases: [String: String] = [
    // Apple ships Norwegian as Bokmål; the catalogue carries the macro-language.
    "nb": "no",
    // Deprecated ISO-639 codes Foundation still returns for legacy identifiers.
    "iw": "he",
    "in": "id",
    "ji": "yi",
    // Filipino is Tagalog in the catalogue.
    "fil": "tl",
  ]

  /// What the sheet reports for a mode change, as one decision both of its
  /// actions read.
  ///
  /// r11 added an Auto row, and with it a second copy of this classification
  /// inside the view. Two copies of a telemetry decision is how a field starts
  /// meaning different things depending on which control produced it — the
  /// partial-port defect this file's own header was written about. So the
  /// decision lives here, where it is pure and testable, and the view only
  /// applies it.
  ///
  /// `toLang` carries `"auto"` for a return to auto-detect, matching the value
  /// `fromLang` already used when leaving it, so one vocabulary covers both
  /// directions.
  ///
  /// `reason` distinguishes a FIRST lock from a change of mind, and deliberately
  /// never emits `"after_bad_detect"` — that value is reserved for the passive
  /// chip CTA, and a Settings-driven change must not borrow it. Leaving Auto is
  /// classified `first_time`; every other transition is `preference`, including
  /// the return TO Auto, which is a user changing their mind rather than a first
  /// encounter.
  static func lockTelemetry(
    from previous: LanguageMode, fromSpelling: EnglishSpelling,
    to next: LanguageMode, toSpelling: EnglishSpelling
  ) -> (fromLang: String, toLang: String, reason: String) {
    let leavingAuto: Bool
    if case .auto = previous { leavingAuto = true } else { leavingAuto = false }

    // A return to Auto is never a first lock, whatever the previous mode was.
    var isFirstLock = leavingAuto
    if case .auto = next { isFirstLock = false }

    return (
      telemetryCode(previous, stored: fromSpelling), telemetryCode(next, stored: toSpelling),
      isFirstLock ? "first_time" : "preference"
    )
  }

  /// The language value a lock event reports: "auto", the locked code, or "en-GB" when British
  /// spelling is IN FORCE (#3124). English (US) and English (UK) both lock the engine to "en", so
  /// without this a switch between them would report "en" to "en" and be invisible in the data.
  static func telemetryCode(_ mode: LanguageMode, stored: EnglishSpelling) -> String {
    switch mode {
    case .auto: return "auto"
    case .locked(let code):
      return EnglishSpelling.effective(languageMode: mode, stored: stored) == .british
        ? "en-GB" : code
    }
  }

  // MARK: - English (UK) picker rows (#3124)

  /// The picker's rows for an engine and a search. Filtered on `lockCode`, the code the engine
  /// receives, BEFORE the search, so a search can never surface a row the active engine cannot
  /// honour, and English (UK) is offered exactly where English is. `lockableCodes == nil` means
  /// no restriction. Search matches the English name, native name or row code, case-insensitive.
  ///
  /// `offersEnglishUK` is false only where the list must name what can run RIGHT NOW and the
  /// British variant cannot: the Live Preview page on Apple's engine without the en-GB pack
  /// (`previewOffersEnglishUK`).
  static func pickerRows(
    lockableCodes: Set<String>?, query: String, offersEnglishUK: Bool
  ) -> [LanguageCatalog.Entry] {
    let offered = LanguageCatalog.pickerEntries.filter {
      (lockableCodes?.contains($0.lockCode) ?? true)
        && (offersEnglishUK || $0 != LanguageCatalog.englishUK)
    }
    let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !needle.isEmpty else { return offered }
    return offered.filter { entry in
      entry.englishName.lowercased().contains(needle)
        || entry.nativeName.lowercased().contains(needle)
        || entry.code.lowercased().contains(needle)
    }
  }

  /// Whether the LIVE PREVIEW page's picker may offer English (UK). Apple's preview needs the exact
  /// en-GB pack for a British lock (`ApplePreviewRecognizer.satisfyingTag`: a region-bearing code
  /// requires that installed tag), so with only another English installed the row would lock a
  /// preview that then refuses to run. The universal engine has no packs, so it always may.
  static func previewOffersEnglishUK(
    previewEngine: LivePreviewEngineChoice, installedPackTags: [String]
  ) -> Bool {
    guard previewEngine == .apple else { return true }
    return installedPackTags.contains {
      $0.replacingOccurrences(of: "_", with: "-").lowercased() == "en-gb"
    }
  }

  /// The row a RECENT language code is shown as: the English the user has chosen for "en" (#3124),
  /// except where `offersEnglishUK` is false, where a recent "en" is plain English, so the Recent
  /// section can never offer the British row the main list hides.
  static func recentRow(
    code: String, stored: EnglishSpelling, offersEnglishUK: Bool
  ) -> LanguageCatalog.Entry {
    offersEnglishUK
      ? LanguageCatalog.entry(forLockedCode: code, spelling: stored)
      : LanguageCatalog.entry(for: code)
  }

  /// What choosing `entry` sets, or Auto for nil: the lock and the stored spelling. A row with a
  /// spelling (the two English rows) sets it; any other row leaves the stored preference alone, so
  /// choosing English (UK) again later restores it.
  static func selection(
    for entry: LanguageCatalog.Entry?, stored: EnglishSpelling
  ) -> (mode: LanguageMode, spelling: EnglishSpelling) {
    guard let entry else { return (.auto, stored) }
    return (.locked(entry.lockCode), entry.spelling ?? stored)
  }

  /// Whether `entry` is the row the current settings select. The two English rows share one lock
  /// code, so they are told apart by the spelling IN FORCE.
  static func isSelected(
    _ entry: LanguageCatalog.Entry, mode: LanguageMode, stored: EnglishSpelling
  ) -> Bool {
    guard case .locked(let code) = mode, code == entry.lockCode else { return false }
    guard let rowSpelling = entry.spelling else { return true }
    return EnglishSpelling.effective(languageMode: mode, stored: stored) == rowSpelling
  }

  /// Applies a picker choice (nil = Auto) and returns the lock event to report. The telemetry is
  /// read BEFORE the mutation, and the spelling is written BEFORE the lock, so the frozen value a
  /// recording could read never pairs a new lock with an old spelling.
  @MainActor
  static func apply(
    _ entry: LanguageCatalog.Entry?, to settings: SettingsManager
  ) -> (fromLang: String, toLang: String, reason: String) {
    let next = selection(for: entry, stored: settings.englishSpelling)
    let event = lockTelemetry(
      from: settings.languageMode, fromSpelling: settings.englishSpelling,
      to: next.mode, toSpelling: next.spelling)
    if settings.englishSpelling != next.spelling { settings.englishSpelling = next.spelling }
    settings.languageMode = next.mode
    return event
  }

  /// Codes the picker may offer for `backend`, or `nil` for "no restriction".
  ///
  /// `nil` is not "none": `LanguageLockSheet` reads it as the multilingual
  /// engine's full catalogue. Returning an empty set instead would render an
  /// empty picker, which is why the optional is preserved verbatim from the
  /// property this replaces rather than "cleaned up" into a non-optional.
  static func lockableCodes(for backend: ASRBackendType) -> Set<String>? {
    switch backend {
    case .whisperKit:
      // The engine's full catalogue. It claims no restriction, so the app must not invent one.
      return nil
    case .parakeet:
      // Owned by the backend, derived from the vendor enum minus the cases its
      // model card does not claim. Never a hand-copied list here.
      return ParakeetBackend.lockableLanguageCodes
    }
  }
}
