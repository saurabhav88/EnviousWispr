import EnviousWisprCore
import EnviousWisprPipeline
import EnviousWisprServices
import Foundation

/// The language chip's buttons, out of the composition root (#2292, C4c).
///
/// **Extracted for the same reason `EscapeRecoveryWiring` and
/// `LivePreviewInstaller` were**: twenty-five lines of feature wiring do not
/// belong in the composition root, whose job is to hold the graph rather than
/// implement the parts.
///
/// What changed beyond the move: these were three fields on the panel, alive for
/// the app's lifetime whether or not a chip was showing. They are now the
/// `actions:` binding for the chip's own presentation, which the director drops
/// when the occupant changes.
enum OverlayChipWiring {

  /// What happens to a language the user chose to lock.
  ///
  /// **Narrowed from a `PillAction` handler to this one callback** (#2292 C3).
  /// The chip's buttons now ride on its own `PillRequest`, so Lock and Dismiss
  /// reach the presenter directly and no longer pass through here; what is left
  /// is the half this file has always owned, which is the SETTINGS write and its
  /// telemetry.
  ///
  /// **The order below is the contract, not a style choice.** The presenter has
  /// already cleared its state and dismissed its pill before calling this, and
  /// the prior language mode is read BEFORE the mutation — reading it after
  /// would report the new value as the old one, so every chip-driven lock would
  /// claim the user moved from the language they moved to.
  @MainActor
  static func acceptedLanguage(
    settings: SettingsManager
  ) -> @MainActor (String) -> Void {
    { [weak settings] lang in
      guard let settings else { return }
      let priorMode = settings.languageMode
      let fromLang: String
      switch priorMode {
      case .auto: fromLang = "auto"
      case .locked(let prev): fromLang = prev
      }
      settings.languageMode = .locked(lang)
      // PR4 Codex code-diff r6 [P2]: chip-driven locks emit the same
      // language.manual_lock_used event as Settings-driven locks.
      TelemetryService.shared.trackManualLockUsed(
        fromLang: fromLang, toLang: lang, reason: "after_bad_detect")
    }
  }
}
