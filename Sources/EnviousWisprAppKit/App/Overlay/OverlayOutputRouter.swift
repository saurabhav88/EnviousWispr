import EnviousWisprPipeline
import EnviousWisprServices
import Foundation

/// Where an overlay's OUTPUT goes — its effects, and the two button actions that
/// belong to the app rather than to a presentation (#2292, C4c).
///
/// **Targets are settable because the composition root cannot construct them in
/// dependency order.** The director is built early, since everything that shows
/// a pill needs it, while the Live Preview coordinator, the chip presenter and
/// the recovery coordinator are built much later. The shipped code had the same
/// ordering and solved it with `set*Handler` calls on the panel afterwards; this
/// is the same shape with one owner instead of five fields scattered across a
/// 1,300-line function.
///
/// Every target reference is weak because its feature owner anchors its
/// lifetime. A missing target after bootstrap installation is a wiring defect.
@MainActor
final class OverlayOutputRouter {

  weak var overlay: OverlayDirector?
  weak var permissions: PermissionsService?
  weak var recovery: RecoveryCoordinator?
  weak var languageChips: LanguageSuggestionPresenter?

  func deliver(_ effect: PillEffect) {
    switch effect {
    case .recordingStateChanged:
      // **Handled by the director's own `LivePreviewBridge` since C2**, which it
      // receives at construction. Nothing reaches here: the branch survives only
      // because `PillEffect` is exhaustive, and C4 deletes this whole type.
      break

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

  /// The two buttons whose handlers belong to the APP, not to whoever presented
  /// the pill.
  ///
  /// **Both were silently unbound by the cutover and review caught it.** Grant
  /// and Discard were setGrantHandler / setDiscardRecoveryHandler on the
  /// panel; their setters were deleted with the class and the presenting sites
  /// pass `actions: nil`, so the buttons still rendered and reached nobody. They
  /// are here rather than at a call site because neither has one: an
  /// accessibility toast is raised by the pipeline funnel and a recovery notice
  /// by the recording starter, and neither of those knows about permissions or
  /// the recovery coordinator.
  func deliver(_ action: PillAction) {
    switch action {
    case .grantAccessibility:
      _ = permissions?.requestAccessibilityAccess()
      overlay?.dismissSilently()
    case .discardRecovery:
      recovery?.discardActiveRecovery()
      overlay?.dismissSilently()
    case .pasteEscapeRecovery, .lockLanguage, .dismissChip,
      .acknowledgeBluetoothAwareness, .closeBluetoothAwareness, .openBluetoothSettings:
      // These belong to the presentation that raised them and arrive through its
      // own `actions:` binding. Reaching here means one was presented without
      // one, which is a wiring defect rather than a race.
      assertionFailure("a presentation-local action reached the app router")
    }
  }
}
