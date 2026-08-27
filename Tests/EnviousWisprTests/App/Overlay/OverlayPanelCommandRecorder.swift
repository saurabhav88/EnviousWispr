import AppKit
import EnviousWisprAppKit
import EnviousWisprAppKitTestSupport
import Foundation

/// Every command the host issued against a panel, in order.
///
/// **`close` is gone (#2455 C4).** It existed as a negative tripwire — production
/// must never call it — and `OverlayPanelDriving` simply does not declare it, so
/// the case it guarded is now unrepresentable rather than merely unasserted. That
/// is the stronger form of the same check.
enum OverlayPanelCommand: Equatable {
  case constructed(panel: ObjectIdentifier)
  case setFrame(panel: ObjectIdentifier, frame: CGRect, display: Bool, animated: Bool)
  case setContentView(panel: ObjectIdentifier, view: ObjectIdentifier?)
  case orderFrontRegardless(panel: ObjectIdentifier)
  case orderOut(panel: ObjectIdentifier)
}

/// Owns every panel the host has produced and the commands each one received.
///
/// **The panels are no longer `NSPanel`s (#2455 C4.)** This type's predecessor
/// vended `CommandRecordingPanel: NSPanel`, which called `super` on every
/// override — so a suite asking for a fake pill got a real one, and the founder
/// watched it flash. The seam vended an `NSPanel`, so a non-displaying double was
/// not expressible; C4 moved the seam to behaviour and this records against that.
///
/// **One recorder per test, one factory closure per recorder.** `panel` answers
/// "the current occupant" without reading private host state; `constructionCount`
/// counts `.constructed` receipts rather than keeping a second, independently
/// incrementable counter — one authority for "how many panels exist" instead of
/// two that could drift.
@MainActor
final class OverlayPanelCommandRecorder {

  private(set) var panels: [RecordingOverlayPanelDriver] = []

  var panel: RecordingOverlayPanelDriver? { panels.last }

  /// Flattened from every panel this recorder vended, tagged by panel identity,
  /// so the assertions that ask "which panel got this" still can.
  var commands: [OverlayPanelCommand] {
    var out: [OverlayPanelCommand] = []
    for p in panels {
      let id = ObjectIdentifier(p)
      out.append(.constructed(panel: id))
      for c in p.commands {
        switch c {
        case .setFrame(let f, let display, let animated):
          out.append(.setFrame(panel: id, frame: f, display: display, animated: animated))
        case .setContentView(let view):
          out.append(.setContentView(panel: id, view: view))
        case .orderFrontRegardless:
          out.append(.orderFrontRegardless(panel: id))
        case .orderOut:
          out.append(.orderOut(panel: id))
        case .accessibilityIdentifier:
          // Not in the original vocabulary; the suites that care assert on the
          // driver directly rather than through this flattening.
          break
        }
      }
    }
    return out
  }

  var constructionCount: Int { panels.count }

  /// The effects a host under test receives.
  ///
  /// Replaces `makeFactory()`. Each call vends a NEW driver, matching the old
  /// factory's contract — the host builds its panel lazily and may rebuild it.
  func makeEffects(
    workspace: RecordingWorkspaceObserver = RecordingWorkspaceObserver()
  ) -> DesktopOverlayEffects {
    DesktopOverlayEffects(
      makePanel: { [weak self] in
        let driver = RecordingOverlayPanelDriver()
        self?.panels.append(driver)
        return driver
      },
      workspace: workspace)
  }
}
