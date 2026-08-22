import EnviousWisprCore
import EnviousWisprPipeline
import EnviousWisprServices
import Foundation

/// The language chip's buttons, out of the composition root (#2292, C4c).
///
/// **Extracted for the same measured reason `EscapeRecoveryWiring` and
/// `LivePreviewInstaller` were**: `WisprBootstrapper` carries a line ceiling
/// whose whole purpose is to stop feature wiring accumulating in it, and this
/// block was twenty-five lines of it.
///
/// What changed beyond the move: these were three fields on the panel, alive for
/// the app's lifetime whether or not a chip was showing. They are now the
/// `actions:` binding for the chip's own presentation, which the director drops
/// when the occupant changes.
enum OverlayChipWiring {

  /// The chip's action handler.
  ///
  /// `.dismissChip` is the explicit dismissal — the user pressing the close
  /// control. The chip's AUTO-dismissal is not a user action and does not arrive
  /// here: the reducer expires the presentation and the director delivers
  /// `OverlayEffect.languageChipAutoDismissed(generation:)` to the effect sink,
  /// which is why that generation is carried on the effect rather than on an
  /// action.
  @MainActor
  static func actions(
    presenter: LanguageSuggestionPresenter, settings: SettingsManager
  ) -> (OverlayAction) -> Void {
    { [weak settings] action in
      switch action {
      case .lockLanguage:
        guard let lang = presenter.accept(), let settings else { return }
        // Capture prior mode for telemetry before mutating settings.
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
      // `presenter.accept()` already hid the overlay; no extra hide needed.
      case .dismissChip:
        presenter.dismissExplicit()
      default:
        break
      }
    }
  }
}
