import EnviousWisprPipeline
import Foundation

/// Whether the accessibility toast has earned the slot this time (#2292, C4c).
///
/// **This policy is the panel's, and it does not belong in the reducer.** The
/// reducer's `.accessibilityToast` row presents the toast unconditionally and
/// must keep doing so: a reducer that reads a provider is no longer a function
/// of its events, which is the whole reason the decision and the effect were
/// split apart. So the once-per-session latch and the dismissed-warning check
/// move OUT to the boundary between "the pipeline decided what to say" and
/// "the overlay shows it".
///
/// The gain is not the relocation. It is that `claim()` is three cases and a
/// latch, directly testable, where the same rule inside the panel was reachable
/// only by driving a live window.
@MainActor
final class OverlayAccessibilityEligibility {

  private var shownThisSession = false
  private let warningDismissed: () -> Bool

  init(warningDismissed: @escaping () -> Bool) {
    self.warningDismissed = warningDismissed
  }

  /// True when the toast should be SHOWN, and latches so the next call is false.
  ///
  /// Named `claim` rather than `isEligible` because it is not a question: asking
  /// it spends the one showing this session. A property named for a query that
  /// mutates is the shape a reader trusts without checking.
  func claim() -> Bool {
    guard !shownThisSession, !warningDismissed() else { return false }
    shownThisSession = true
    return true
  }
}

/// Wiring for the accessibility notice, out of the composition root.
///
/// `WisprBootstrapper` is at 1359 lines against a 1360 ceiling, so this follows
/// the precedent `EscapeRecoveryWiring` set for exactly that reason: the root
/// spends one line and the feature is implemented here.
enum OverlayAccessibilityWiring {

  /// The overlay's show closure, with the accessibility notice routed through
  /// its eligibility policy and everything else passed straight through.
  @MainActor
  static func showOverlay(
    director: OverlayDirector, eligibility: OverlayAccessibilityEligibility
  ) -> @MainActor (OverlayIntent) -> Void {
    { [weak director] intent in
      guard let director else { return }
      guard case .accessibilityToast = intent else {
        director.send(.pipeline(intent), actions: nil)
        return
      }
      director.presentAccessibilityNotice(showingToast: eligibility.claim())
    }
  }
}
