import EnviousWisprASR
import EnviousWisprCore
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

    let installed = Set(
      installedPackTags.compactMap { tag -> String? in
        let language = tag.split(separator: "-").first.map(String.init)
        return language?.lowercased()
      })

    // nil means "no restriction from the backend", so the install set becomes the
    // whole restriction rather than being discarded.
    guard let backendCodes else { return installed }
    return backendCodes.intersection(installed)
  }

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
    from previous: LanguageMode, to next: LanguageMode
  ) -> (fromLang: String, toLang: String, reason: String) {
    let fromLang: String
    var leavingAuto = false
    switch previous {
    case .auto:
      fromLang = "auto"
      leavingAuto = true
    case .locked(let prior):
      fromLang = prior
    }

    let toLang: String
    switch next {
    case .auto: toLang = "auto"
    case .locked(let code): toLang = code
    }

    // A return to Auto is never a first lock, whatever the previous mode was.
    var isFirstLock = leavingAuto
    if case .auto = next { isFirstLock = false }

    return (fromLang, toLang, isFirstLock ? "first_time" : "preference")
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
      // All 99. The engine claims no restriction, so the app must not invent one.
      return nil
    case .parakeet:
      // Owned by the backend, derived from the vendor enum minus the cases its
      // model card does not claim. Never a hand-copied list here.
      return ParakeetBackend.lockableLanguageCodes
    }
  }
}
