import AppKit

/// The overlay's window and workspace effects (#2455 C4, issue #2461).
///
/// **The abstraction was one level too low.** `OverlayPanelFactory` vended an
/// `NSPanel`, so every possible implementation WAS one — including the test
/// double, `CommandRecordingPanel: NSPanel`, which called `super` on every
/// override and therefore really displayed. That is the pill the founder sees
/// flash mid-suite: not an oversight in the fake, but the only fake the seam's
/// type permitted.
///
/// Driving a panel is now a protocol over BEHAVIOUR, so a recorder can satisfy it
/// without being a window.
@MainActor
package protocol OverlayPanelDriving: AnyObject {
  // Reads.
  var frame: CGRect { get }
  var isVisible: Bool { get }
  var windowNumber: Int { get }

  // Configuration.
  var backgroundColor: NSColor? { get set }
  var collectionBehavior: NSWindow.CollectionBehavior { get set }
  var contentView: NSView? { get set }
  var hasShadow: Bool { get set }
  var isMovableByWindowBackground: Bool { get set }
  var isOpaque: Bool { get set }
  var isReleasedWhenClosed: Bool { get set }
  var level: NSWindow.Level { get set }

  /// The move callback, replacing `NSWindowDelegate.windowDidMove`.
  ///
  /// `delegate` does NOT cross this boundary. The host used to BE the window's
  /// delegate, which forced it to inherit `NSObject` and made `windowDidMove`
  /// `nonisolated`. The live driver owns the delegate relationship now and hands
  /// the host a plain callback, so the host is an ordinary `@MainActor` type and
  /// the ordering `programmaticMoveDepth` depends on is preserved by the call
  /// being synchronous.
  var onMove: (@MainActor (CGRect) -> Void)? { get set }

  // Commands.
  func orderFrontRegardless()
  func orderOut()
  func setAccessibilityIdentifier(_ identifier: String?)
  func setFrame(_ frame: CGRect, display: Bool)
  func setFrame(_ frame: CGRect, display: Bool, animate: Bool)
}

/// A live workspace subscription, cancellable exactly once.
package protocol WorkspaceObservation: AnyObject {
  func cancel()
}

/// How the overlay learns the user switched Spaces.
///
/// Only the OBSERVER pair crosses. `NSWorkspace.shared.frontmostApplication`
/// (`OverlayWindowHost.swift:548`) stays a direct read: it observes and cannot
/// alter the desktop, and C3 established that reads stay out — `NSApp.windows` is
/// the precedent.
@MainActor
package protocol WorkspaceObserving: AnyObject {
  func observeActiveSpaceChanges(
    _ callback: @escaping @MainActor () -> Void
  ) -> any WorkspaceObservation
}

/// The overlay's two effects, carried together.
///
/// A composition carrier with no `shared`, no static storage and no default —
/// the same shape as `DesktopPresentationEffects`, and for the same reason: a
/// default is what lets a test reach the real desktop by simply not saying
/// otherwise.
package struct DesktopOverlayEffects {
  package let makePanel: @MainActor () -> any OverlayPanelDriving
  package let workspace: any WorkspaceObserving

  package init(
    makePanel: @escaping @MainActor () -> any OverlayPanelDriving,
    workspace: any WorkspaceObserving
  ) {
    self.makePanel = makePanel
    self.workspace = workspace
  }
}
