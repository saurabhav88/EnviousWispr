import AppKit
import EnviousWisprAppKit

/// The real overlay window (#2455 C4).
///
/// Owns the `NSPanel` AND its delegate relationship. Before C4 the host was the
/// delegate, which forced `OverlayWindowHost` to inherit `NSObject` and made
/// `windowDidMove` `nonisolated`. Moving both here lets the host be an ordinary
/// `@MainActor` type that receives a plain callback.
@MainActor
package final class LiveOverlayPanelDriver: NSObject, OverlayPanelDriving, NSWindowDelegate {

  private let panel: NSPanel

  /// The real window, for `EnviousWisprDesktopEffectsTests` ONLY.
  ///
  /// A deliberate widening, and narrow: that target exists to assert what a real
  /// `NSPanel` does in response to the host's commands, which is unobservable
  /// through the protocol by design. Nothing else may reach it — the unit target
  /// does not link this module, and `check-dependency-direction.sh` says so.
  package var underlyingPanel: NSPanel { panel }

  package var onMove: (@MainActor (CGRect) -> Void)?

  package override init() {
    // Moved verbatim from `OverlayPanelFactory.live`. Borderless and
    // non-activating is what makes the pill appear without stealing focus; a
    // plain `NSWindow` here would take the keyboard from whatever the user is
    // typing in.
    panel = NSPanel(
      contentRect: NSRect(x: 0, y: 0, width: 185, height: 44),
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: false)
    super.init()
    panel.delegate = self
  }

  // MARK: - Reads

  package var frame: CGRect { panel.frame }
  package var isVisible: Bool { panel.isVisible }
  package var windowNumber: Int { panel.windowNumber }

  // MARK: - Configuration

  package var backgroundColor: NSColor? {
    get { panel.backgroundColor }
    set { panel.backgroundColor = newValue }
  }
  package var collectionBehavior: NSWindow.CollectionBehavior {
    get { panel.collectionBehavior }
    set { panel.collectionBehavior = newValue }
  }
  package var contentView: NSView? {
    get { panel.contentView }
    set { panel.contentView = newValue }
  }
  package var hasShadow: Bool {
    get { panel.hasShadow }
    set { panel.hasShadow = newValue }
  }
  package var isMovableByWindowBackground: Bool {
    get { panel.isMovableByWindowBackground }
    set { panel.isMovableByWindowBackground = newValue }
  }
  package var isOpaque: Bool {
    get { panel.isOpaque }
    set { panel.isOpaque = newValue }
  }
  package var isReleasedWhenClosed: Bool {
    get { panel.isReleasedWhenClosed }
    set { panel.isReleasedWhenClosed = newValue }
  }
  package var level: NSWindow.Level {
    get { panel.level }
    set { panel.level = newValue }
  }

  // MARK: - Commands

  package func orderFrontRegardless() { panel.orderFrontRegardless() }
  package func orderOut() { panel.orderOut(nil) }
  package func setAccessibilityIdentifier(_ identifier: String?) {
    panel.setAccessibilityIdentifier(identifier)
  }
  package func setFrame(_ frame: CGRect, display: Bool) {
    panel.setFrame(frame, display: display)
  }
  package func setFrame(_ frame: CGRect, display: Bool, animate: Bool) {
    panel.setFrame(frame, display: display, animate: animate)
  }

  // MARK: - NSWindowDelegate

  nonisolated package func windowDidMove(_ notification: Notification) {
    MainActor.assumeIsolated { [weak self] in
      guard let self else { return }
      onMove?(panel.frame)
    }
  }
}

/// The live Space-change subscription.
@MainActor
package final class LiveWorkspaceObserver: WorkspaceObserving {

  package init() {}

  package func observeActiveSpaceChanges(
    _ callback: @escaping @MainActor () -> Void
  ) -> any WorkspaceObservation {
    let token = NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
    ) { _ in
      MainActor.assumeIsolated { callback() }
    }
    return Observation(token: token)
  }

  /// Owns the opaque token, so nothing outside this module ever holds one.
  ///
  /// `cancel()` and `deinit` are both idempotent: removing twice is a no-op, and
  /// the alternative — cancelling in only one place — is the leak that outlives
  /// the host.
  private final class Observation: WorkspaceObservation {
    private var token: (any NSObjectProtocol)?

    init(token: any NSObjectProtocol) { self.token = token }

    func cancel() {
      guard let token else { return }
      self.token = nil
      NSWorkspace.shared.notificationCenter.removeObserver(token)
    }

    deinit { cancel() }
  }
}
