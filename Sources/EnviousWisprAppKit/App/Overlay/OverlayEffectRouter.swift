import EnviousWisprPipeline
import Foundation

/// Where an `OverlayEffect` goes (#2292, C4c).
///
/// **Targets are settable because the composition root cannot construct them in
/// dependency order.** The director is built early — everything that shows a
/// pill needs it — while the Live Preview coordinator and the language-chip
/// presenter are built much later, and both are effect targets. The shipped code
/// had the same ordering and solved it with `set*Handler` calls on the panel
/// AFTER those objects existed; this is the same shape with one owner instead of
/// three fields scattered across a 1,300-line function.
///
/// Every reference is WEAK. An effect target must never be what keeps a limb
/// alive, and an unset target is a limb that is not installed rather than a
/// programming error — Live Preview is genuinely absent below macOS 26.
@MainActor
final class OverlayEffectRouter {

  weak var livePreview: LivePreviewCoordinator?
  weak var languageChips: LanguageSuggestionPresenter?

  func deliver(_ effect: OverlayEffect) {
    switch effect {
    case .recordingIntentChanged(let isRecording):
      // #1988. The preview starts and stops with the recording pill, and the
      // heart path never learns it exists.
      livePreview?.setRecording(isRecording)

    case .languageChipAutoDismissed(let generation):
      // The chip expiring on its own is NOT a user action, which is why it is an
      // effect carrying its generation rather than an `OverlayAction`: the
      // presenter needs to know a specific chip lapsed, not that someone pressed
      // something.
      languageChips?.autoDismiss(generation: generation)

    case .escapeRecoveryExpired:
      // The pill went without an Undo press. The director has already dropped
      // its custody of the payload, which is the whole obligation here; the row
      // stays in History under its own expiry, which is the unhurried door a
      // VoiceOver user who missed a three-second dwell needs.
      break
    }
  }
}
