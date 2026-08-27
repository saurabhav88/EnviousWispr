import AppKit
import EnviousWisprAppKit
import Foundation

/// The overlay double that is NOT a window (#2455 C4).
///
/// **This is the pill that used to flash.** Its predecessor,
/// `CommandRecordingPanel: NSPanel`, called `super` on every override, so a test
/// asking for a fake pill got a real one that really appeared on the developer's
/// screen mid-suite. The fake was not sloppy — `OverlayPanelFactory` vended an
/// `NSPanel`, so a non-displaying implementation was not expressible. C4 moved the
/// seam up to BEHAVIOUR, and this is what that buys.
///
/// It records commands in ORDER, because the assertions that matter here are
/// sequential: configure before showing, order out before releasing the hosting
/// view. Separate counters cannot express an interleaving.
@MainActor
package final class RecordingOverlayPanelDriver: OverlayPanelDriving {

  package init() {}

  package enum Command: Equatable {
    case setFrame(CGRect, display: Bool, animated: Bool)
    case setContentView(ObjectIdentifier?)
    case orderFrontRegardless
    case orderOut
    case accessibilityIdentifier(String?)
  }

  package private(set) var commands: [Command] = []

  // MARK: - Reads

  /// Starts at the shipped pill's size, so geometry maths sees the real starting
  /// point rather than `.zero` — a fake that starts at the origin makes every
  /// centring calculation trivially correct.
  package private(set) var frame = CGRect(x: 0, y: 0, width: 185, height: 44)
  package private(set) var isVisible = false
  package let windowNumber = 0

  // MARK: - Configuration

  package var backgroundColor: NSColor?
  package var collectionBehavior: NSWindow.CollectionBehavior = []
  package var contentView: NSView? {
    didSet { commands.append(.setContentView(contentView.map(ObjectIdentifier.init))) }
  }
  package var hasShadow = false
  package var isMovableByWindowBackground = false
  package var isOpaque = true
  package var isReleasedWhenClosed = true
  package var level: NSWindow.Level = .normal
  package var onMove: (@MainActor (CGRect) -> Void)?

  // MARK: - Commands

  package func setFrame(_ value: CGRect, display: Bool) {
    frame = value
    commands.append(.setFrame(value, display: display, animated: false))
    onMove?(value)
  }

  package func setFrame(_ value: CGRect, display: Bool, animate: Bool) {
    frame = value
    commands.append(.setFrame(value, display: display, animated: animate))
    onMove?(value)
  }

  package func orderFrontRegardless() {
    isVisible = true
    commands.append(.orderFrontRegardless)
  }

  package func orderOut() {
    isVisible = false
    commands.append(.orderOut)
  }

  package func setAccessibilityIdentifier(_ identifier: String?) {
    commands.append(.accessibilityIdentifier(identifier))
  }

  // MARK: - Driving the host from the OS side

  /// The user dragged the pill.
  ///
  /// **`setFrame` fires `onMove` too, and that is the point.** The live driver's
  /// `onMove` fires for programmatic moves as well as drags — AppKit reports both
  /// — and `programmaticMoveDepth` is what tells them apart. An earlier revision of this
  /// fake suppressed the callback on `setFrame`, reasoning that it would conflate
  /// the two — which had it backwards: with no programmatic callback, the depth
  /// counter is never exercised, and every test of it passes without testing it.
  /// A fake arranged so a guard cannot fire is the guard's coverage removed.
  ///
  /// The difference is WHERE the callback lands: `setFrame`'s arrives inside
  /// `withProgrammaticMove`, this one arrives outside it.
  package func simulateUserMove(to origin: CGPoint) {
    frame.origin = origin
    onMove?(frame)
  }
}

/// A workspace observer that never subscribes to anything.
@MainActor
package final class RecordingWorkspaceObserver: WorkspaceObserving {

  package init() {}

  package private(set) var observerCount = 0
  package private(set) var cancelledCount = 0
  private var callback: (@MainActor () -> Void)?

  package func observeActiveSpaceChanges(
    _ callback: @escaping @MainActor () -> Void
  ) -> any WorkspaceObservation {
    observerCount += 1
    self.callback = callback
    return Observation { [weak self] in self?.cancelledCount += 1 }
  }

  /// The user switched Spaces.
  package func simulateActiveSpaceChange() { callback?() }

  private final class Observation: WorkspaceObservation {
    private var onCancel: (() -> Void)?
    init(onCancel: @escaping () -> Void) { self.onCancel = onCancel }
    package func cancel() {
      onCancel?()
      onCancel = nil
    }
    deinit { cancel() }
  }
}

extension DesktopOverlayEffects {
  /// The default for a test that does not care about the panel — it still gets a
  /// recorder rather than a window, which is the whole point.
  @MainActor
  package static func recording(
    panel: RecordingOverlayPanelDriver = RecordingOverlayPanelDriver(),
    workspace: RecordingWorkspaceObserver = RecordingWorkspaceObserver()
  ) -> DesktopOverlayEffects {
    DesktopOverlayEffects(makePanel: { panel }, workspace: workspace)
  }
}
