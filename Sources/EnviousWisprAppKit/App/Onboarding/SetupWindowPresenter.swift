import AppKit
import SwiftUI

/// Presents one window for the app's Setup session (#4528 M85).
///
/// Lifecycle, decided before wiring:
/// - show: one window; a second show only refocuses it (the flow is never restarted);
/// - close: detach the screen model and notify the session; a later show reattaches;
/// - stop, quit and completion: the session dismisses without a user-close notification;
/// - on-screen state (telemetry M67): every transition re-reads `isOnScreen` and hands it to the
///   model: show and refocus (`makeKeyAndOrderFront`), the system's occlusion changes (covered,
///   another Space, app hidden or unhidden), miniaturize and deminiaturize, and close (off for
///   good). Signals only, no polling; a screen mounted while off screen reports nothing until it
///   is on screen again, and then once (the observer's own dedup).
/// It owns no flow, timer, settings writer or recommendation: it renders the coordinator the
/// session already built.
@MainActor
final class SetupWindowPresenter: NSObject, NSWindowDelegate {
  private var window: NSWindow?
  private var model: SetupScreenModel?
  var onClose: (() -> Void)?

  var isVisible: Bool { window?.isVisible ?? false }
  /// The live screen model, for tests.
  var screenModel: SetupScreenModel? { model }
  /// Whether the window is actually on screen. Injected in tests, which have no window server
  /// occlusion; production asks the window and the app.
  var isOnScreen: (NSWindow) -> Bool = { window in
    window.isVisible && !window.isMiniaturized && !NSApp.isHidden
      && window.occlusionState.contains(.visible)
  }

  /// Hands the window's current on-screen state to the model (every transition calls this).
  func updateVisibility() {
    guard let window, let model else { return }
    model.setWindowVisible(isOnScreen(window))
  }

  /// Shows (or refocuses) the Setup screens for `coordinator`. A real screen on screen is
  /// reported to the session's telemetry observer (M67); nil sends nothing.
  func show(
    coordinator: OnboardingCoordinator, telemetry: OnboardingTelemetryObserver?,
    sources: SetupScreenSources = SetupScreenSources(),
    activateApp: (@MainActor () -> Void)? = nil,
    downloadsVisible: (@MainActor (Bool) -> Void)? = nil
  ) {
    if let window {
      activateApp?()
      window.makeKeyAndOrderFront(nil)
      updateVisibility()
      return
    }
    let model = SetupScreenModel(coordinator: coordinator)
    model.sources = sources
    model.onDownloadsVisible = downloadsVisible
    model.onPresented = { [weak telemetry] step, resumed in
      telemetry?.screenPresented(step, resumed: resumed)
    }
    model.onFilmEnded = { [weak telemetry] result, scene in
      telemetry?.filmEnded(result, lastScene: scene)
    }
    let window = NSWindow(
      contentRect: NSRect(
        x: 0, y: 0, width: SetupLayout.windowWidth, height: SetupLayout.contentHeight),
      styleMask: [.titled, .closable], backing: .buffered, defer: false)
    window.identifier = NSUserInterfaceItemIdentifier(LaunchWindowIdentity.onboardingID)
    window.title = String(localized: "Setup")
    window.isReleasedWhenClosed = false
    window.contentViewController = NSHostingController(rootView: SetupWindowRoot(model: model))
    window.delegate = self
    window.center()
    self.model = model
    self.window = window
    // Bring the app forward through the desktop-effects owner (dependency direction:
    // live desktop calls live only in EnviousWisprDesktopEffects).
    activateApp?()
    window.makeKeyAndOrderFront(nil)
    updateVisibility()
  }

  /// Takes the window down, if any (stop, quit and completion call this). It orders the window
  /// out and releases it rather than calling `close()`: this module never closes a window
  /// (OverlayRetainedWindowTests' guard), and the cleanup is the one the close button runs.
  func dismiss() {
    window?.orderOut(nil)
    release()
  }

  func windowDidChangeOcclusionState(_ notification: Notification) { updateVisibility() }
  func windowDidMiniaturize(_ notification: Notification) { updateVisibility() }
  func windowDidDeminiaturize(_ notification: Notification) { updateVisibility() }

  /// The person's close button.
  func windowWillClose(_ notification: Notification) {
    release()
    onClose?()
  }

  private func release() {
    model?.detach()
    model = nil
    window?.delegate = nil
    window = nil
  }
}
