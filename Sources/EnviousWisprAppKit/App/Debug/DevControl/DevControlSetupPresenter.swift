#if DEBUG
  import AppKit
  import SwiftUI

  /// Shows the new Setup's screens for the door's existing backend session (#4528 chunk D0,
  /// plan M74). DEBUG only, until D7a moves Setup's production window onto these screens.
  ///
  /// Lifecycle, decided before wiring:
  /// - show: one window; a second show only refocuses it (the flow is never restarted);
  /// - close (the window's close button): hides the window and detaches the screen model; the
  ///   flow, its transfers and its visit continue, and a later show reattaches;
  /// - stop, quit and completion: the door calls `close()` from its single ownership release,
  ///   so no DEBUG window or `onChange` subscriber outlives the session.
  /// It owns no flow, timer, settings writer or recommendation: it renders the coordinator the
  /// door already built.
  @MainActor
  final class DevControlSetupPresenter: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private var model: SetupScreenModel?

    var isVisible: Bool { window?.isVisible ?? false }

    /// Shows (or refocuses) the Setup screens for `coordinator`.
    func show(coordinator: OnboardingCoordinator) {
      if let window {
        window.makeKeyAndOrderFront(nil)
        return
      }
      let model = SetupScreenModel(coordinator: coordinator)
      let window = NSWindow(
        contentRect: NSRect(
          x: 0, y: 0, width: SetupLayout.windowWidth, height: SetupLayout.contentHeight),
        styleMask: [.titled, .closable], backing: .buffered, defer: false)
      window.title = String(localized: "Setup")
      window.isReleasedWhenClosed = false
      window.contentViewController = NSHostingController(rootView: SetupWindowRoot(model: model))
      window.delegate = self
      window.center()
      self.model = model
      self.window = window
      NSApp.activate()
      window.makeKeyAndOrderFront(nil)
    }

    /// Closes the window, if any (stop, quit and completion call this).
    func close() {
      window?.close()
    }

    func windowWillClose(_ notification: Notification) {
      model?.detach()
      model = nil
      window?.delegate = nil
      window = nil
    }
  }
#endif
