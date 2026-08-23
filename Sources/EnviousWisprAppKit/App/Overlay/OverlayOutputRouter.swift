import EnviousWisprPipeline
import Foundation

/// Where an overlay's OUTPUT goes — its effects, and the one remaining button
/// action that belongs to the app rather than to a presentation (#2292, C4c).
///
/// **Targets are settable because the composition root cannot construct them in
/// dependency order**, and C2 removed the reason for two of them. The chip
/// presenter and the recovery coordinator are still built after the director, so
/// they remain; Live Preview and the permissions service no longer are, and the
/// director now takes both at construction. The shipped code solved this with
/// `set*Handler` calls on the panel afterwards; what is left here is the same
/// shape with one owner, and C4 deletes it.
///
/// Every target reference is weak because its feature owner anchors its
/// lifetime. A missing target after bootstrap installation is a wiring defect.
@MainActor
final class OverlayOutputRouter {

  weak var recovery: RecoveryCoordinator?
  weak var languageChips: LanguageSuggestionPresenter?

  func deliver(_ effect: PillEffect) {
    switch effect {
    case .recordingStateChanged:
      // **Consumed by `OverlayDirector.route` since C2**, through the
      // `LivePreviewBridge` the director receives at construction. Nothing
      // reaches here today; the branch survives only because `PillEffect` is
      // exhaustive, and C4 deletes this whole type.
      //
      // It asserts rather than `break`ing because the failure it would otherwise
      // hide is silent: a routing change that let this case through again would
      // leave Live Preview never told a recording began, with no crash and no
      // compile error. A Debug build now says so; a shipped build is unaffected.
      assertionFailure("recordingStateChanged must be consumed by OverlayDirector.route")

    case .languageChipExpired(let generation):
      // The chip expiring on its own is NOT a user action, which is why it is an
      // effect carrying its generation rather than a `PillAction`: the
      // presenter needs to know a specific chip lapsed, not that someone pressed
      // something.
      languageChips?.autoDismiss(generation: generation)

    case .escapeRecoveryExpired:
      // The pill went without an Undo press. The director has already dropped
      // its custody of the payload, which is the whole obligation here; the row
      // stays in History under its own expiry.
      break
    }
  }

  /// The one remaining button whose handler belongs to the APP rather than to
  /// whoever presented the pill.
  ///
  /// **Grant left in C2 and only Discard remains.** Both were silently unbound
  /// by the cutover and review caught it: they were setGrantHandler /
  /// setDiscardRecoveryHandler on the panel, their setters were deleted with the
  /// class, and the presenting sites passed `actions: nil`, so the buttons still
  /// rendered and reached nobody. Grant now arrives through the director's
  /// injected `grantAccessibility`, which cannot be omitted.
  ///
  /// Discard is still here because its OWNER is: `RecoveryCoordinator` is built
  /// after the director, and C4 is the chunk that inverts that. The DISMISSAL
  /// moved to the director in C2 regardless, because this type no longer holds a
  /// route back to the overlay.
  func deliver(_ action: PillAction) {
    switch action {
    case .discardRecovery:
      recovery?.discardActiveRecovery()
    case .grantAccessibility, .pasteEscapeRecovery, .lockLanguage, .dismissChip,
      .acknowledgeBluetoothAwareness, .closeBluetoothAwareness, .openBluetoothSettings:
      // These belong to the presentation that raised them and arrive through its
      // own `actions:` binding. Reaching here means one was presented without
      // one, which is a wiring defect rather than a race.
      assertionFailure("a presentation-local action reached the app router")
    }
  }
}
