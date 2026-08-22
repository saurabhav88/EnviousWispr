import Foundation
import Testing

@testable import EnviousWisprAppKit

/// #2292 C4c. The once-per-session accessibility toast policy.
///
/// **Product Outcome.** When these fail the user is either nagged about
/// Accessibility on every dictation, or never told at all that auto-paste needs
/// a permission they have not granted.
///
/// The rule is unchanged from `RecordingOverlayPanel`; what changed is that it
/// is now reachable. Inside the panel it could only be exercised by driving a
/// live window, so none of these four cases existed.
@MainActor
@Suite(.tags(.productOutcome))
struct OverlayAccessibilityEligibilityTests {

  @Test("the first ask this session earns the toast")
  func firstAskShowsIt() {
    let e = OverlayAccessibilityEligibility(warningDismissed: { false })
    #expect(e.claim())
  }

  @Test("the second ask this session does not")
  func secondAskIsSuppressed() {
    let e = OverlayAccessibilityEligibility(warningDismissed: { false })
    _ = e.claim()
    #expect(e.claim() == false, "the user is being told about Accessibility twice in one session")
  }

  @Test("a dismissed standing warning suppresses it from the start")
  func dismissedWarningSuppressesIt() {
    let e = OverlayAccessibilityEligibility(warningDismissed: { true })
    #expect(e.claim() == false, "the user dismissed the warning and was shown it anyway")
  }

  /// **The latch must not spend itself on a call that was refused.** Otherwise a
  /// user who dismisses the warning, then re-enables it, is never told again —
  /// the one showing having been consumed by a call that displayed nothing.
  @Test("a refused ask does not spend the one showing")
  func refusedAskDoesNotSpendTheLatch() {
    var dismissed = true
    let e = OverlayAccessibilityEligibility(warningDismissed: { dismissed })
    #expect(e.claim() == false)

    dismissed = false

    #expect(e.claim(), "the refused ask consumed the session's one showing")
  }

  /// The provider is read on EVERY ask, not captured once. A user who dismisses
  /// the warning mid-session must stop being told from that moment.
  @Test("dismissing the warning mid-session stops the toast")
  func providerIsReadEachTime() {
    var dismissed = false
    let e = OverlayAccessibilityEligibility(warningDismissed: { dismissed })

    dismissed = true

    #expect(e.claim() == false, "the dismissed provider was captured at init rather than read")
  }
}
