import AppKit
import EnviousWisprCore
import SwiftUI
import Testing

@testable import EnviousWisprAppKit

/// #2542: the refusal that keeps an invisible Quick Add panel off the screen.
///
/// **A real-panel suite, and deliberately so.** `present` builds its panel through
/// `ensurePanel()` before it measures anything, so any test reaching the refusal
/// puts a window-server-backed `NSPanel` into the process. That is what this target
/// is for; the unit target stays free of live desktop effects. Cloud review on
/// PR #2545 named the boundary.
///
/// Nothing is ever ordered on screen: keying goes through the injected presenter,
/// which records instead of performing.
@MainActor
@Suite(.tags(.productOutcome))
struct QuickAddPanelHostRealPanelTests {

  /// Records the one call the host makes, instead of making it.
  ///
  /// A local double rather than the unit target's recorder, which is not visible
  /// from here. It answers the single member `present` reaches.
  private final class RecordingPresenter: PanelPresenting {
    private(set) var keyed: [ObjectIdentifier] = []
    func makeKeyAndOrderFront(_ panel: NSPanel) {
      keyed.append(ObjectIdentifier(panel))
    }
  }

  /// **The refusal's own comment names the failure and nothing exercised it.**
  ///
  /// `present` refuses a panel whose size cannot be worked out, because a window
  /// ordered onto the screen at a size nobody could compute is invisible while the
  /// caller is told it opened: the user sees nothing, the telemetry says `opened`,
  /// and every event after it describes a panel that was never there.
  ///
  /// Measured on #2388 — replacing that refusal with "size it 360×240 and report
  /// success" left the whole Quick Add suite green across 56 tests.
  ///
  /// **The return value is the assertion that matters**, because it is the only
  /// thing the caller reads. Nothing being keyed is the second half: a refused
  /// panel must not take the keyboard on its way out.
  @Test("A panel whose size cannot be worked out is refused, and nothing is keyed")
  func anUnmeasurablePanelIsRefused() {
    let presenter = RecordingPresenter()
    let host = QuickAddPanelHost(presenter: presenter)

    #expect(host.present(EmptyView().frame(width: 0, height: 0)) == false)
    #expect(presenter.keyed.isEmpty, "a refused panel must not take the keyboard")
  }

  /// **The two-way control, without which the guard above passes for a host that
  /// refuses EVERYTHING** — which is the same invisible panel by another route.
  @Test("An ordinary panel still opens, so the refusal is not blanket")
  func aMeasurablePanelStillOpens() {
    let presenter = RecordingPresenter()
    let host = QuickAddPanelHost(presenter: presenter)

    #expect(host.present(Color.clear.frame(width: 320, height: 180)) == true)
    #expect(presenter.keyed.count == 1, "exactly one keying, for the one panel shown")
    host.dismiss()
  }
}
