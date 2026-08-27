import AppKit
import EnviousWisprCore
import Testing

@testable import EnviousWisprAppKit
import EnviousWisprAppKitTestSupport

/// The language chip's dismissal belongs to the director, and the leaf owns no
/// clock (#2377 Phase 5, C3).
///
/// **The chip carried a second six-second timer that fired into nothing.** Its
/// `onAutoDismiss` was wired to `{}` at the root, so the leaf counted down for
/// six seconds and then called an empty closure, while the real dismissal came
/// from the catalog row's own dwell. Its `.onHover` cancelled and rescheduled
/// that dead timer beside the root's hover forwarding, and its `hovering` state
/// was never read.
///
/// Deleting it is therefore a removal of dead machinery rather than a change of
/// behaviour — and this suite is what makes that claim checkable rather than
/// asserted, from both ends: the leaf CANNOT be handed a timer callback, and the
/// director still dismisses on time.
@Suite(.tags(.productOutcome))
@MainActor
struct LanguageChipExpiryOwnershipTests {

  private static let payload = LanguageChipPayload(
    lang: "es", displayName: "Spanish", state: .askToLock, generation: 7)

  /// **A COMPILE contract, and it is the whole point of the row.**
  ///
  /// It asserts nothing at runtime because there is nothing to assert: the claim
  /// is that the leaf's initialiser no longer ACCEPTS a timer callback. That is
  /// a property of the type, so the compiler is the only thing that can check
  /// it, and a row that merely constructs the view is how you ask.
  ///
  /// Committed before the deletion, where it fails to build for want of
  /// `onAutoDismiss`.
  @Test("the chip is constructible with no timer callback at all")
  func chipTakesNoTimerCallback() {
    _ = LanguageChipView(payload: Self.payload, onLock: {}, onDismiss: {})
  }

  private final class Counts {
    var expires = 0
  }

  private final class Armed {
    var work: OverlayScheduledWork?
  }

  private static let screen = ScreenGeometry(
    id: ScreenID(rawValue: 1),
    frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
    visibleFrame: CGRect(x: 0, y: 85, width: 1512, height: 860))

  /// **The dismissal the deleted timer looked like it owned.**
  ///
  /// Passes before and after the deletion, deliberately: ownership already
  /// belonged to the director, so a row that changed verdict would mean the
  /// deletion moved behaviour rather than removing dead code.
  @Test("the director dismisses the chip on its own clock and reports the expiry once")
  func theDirectorOwnsTheChipsDismissal() throws {
    let counts = Counts()
    let armed = Armed()
    let host = OverlayWindowHost(screens: { OverlayScreenResolver { Self.screen } }, effects: .recording())
    defer { host.hide() }
    let d = OverlayDirector(
      host: host,
      scheduler: .manual { armed.work = $0 },
      announce: { _ in },
      livePreview: .disabled,
      grantAccessibility: {}, selections: { .shipped },
      firstRenderSchedule: { $0() })

    d.present(
      .languageChip(
        payload: Self.payload, onLock: {}, onDismiss: {},
        onExpire: { counts.expires += 1 }))

    guard case .languageChip? = d.renderModel.state.presentation?.content else {
      Issue.record("the chip never took the slot")
      return
    }
    let work = try #require(armed.work, "the director armed no clock for the chip")

    work.fire()

    #expect(
      d.renderModel.state.presentation == nil,
      "the chip's own clock fired and the chip is still on screen")
    #expect(
      counts.expires == 1,
      "the expiry ran \(counts.expires) times, not once, for this request")
  }
}
