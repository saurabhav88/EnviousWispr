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
