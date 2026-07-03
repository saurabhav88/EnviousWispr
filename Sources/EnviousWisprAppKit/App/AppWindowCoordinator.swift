import AppKit
import EnviousWisprCore
import Observation

/// PR-B.2 of #763 — App-owned home for main + onboarding window identity,
/// the two `NSWindow.willCloseNotification` observers, the SwiftUI
/// open/dismiss bridges, and activation-policy transitions. Extracted from
/// `AppDelegate` so the AppKit adapter shrinks toward its ≤120-line target.
///
/// Strong owner is `EnviousWisprApp` as `@State`; `AppDelegate` holds a weak
/// ref pushed via `attach(...)`. Injected into both Window scenes via
/// `.environment(...)` so `DiagnosticsSettingsView` reaches it through
/// `@Environment` instead of an `NSApp.delegate` downcast.
@MainActor
@Observable
final class AppWindowCoordinator {
  /// Open-eligibility seam. Returns `true` only when onboarding state exists
  /// and is not `.completed`. Folds today's stacked `guard let appState` +
  /// `guard onboardingState != .completed` into one closure, preserving the
  /// `appState`-nil → no-open behavior.
  private let canOpenOnboarding: @MainActor () -> Bool
  /// Onboarding-completed seam. Used by the onboarding-close observer's abort
  /// gate; `appState`-nil → `false`.
  private let isOnboardingComplete: @MainActor () -> Bool

  /// Main window, captured lazily on first titled-window appearance.
  private weak var mainWindow: NSWindow?
  /// `NSWindow.willCloseNotification` observer token for the main window.
  private var windowCloseObserver: (any NSObjectProtocol)?
  /// Onboarding window, captured lazily on first open so the close observer
  /// can match by identity rather than title.
  private weak var onboardingWindow: NSWindow?
  /// `NSWindow.willCloseNotification` observer token for the onboarding window.
  private var onboardingCloseObserver: (any NSObjectProtocol)?

  /// SwiftUI `openWindow(id: "main")` bridge, set by `ActionWirer`.
  var openMainWindowAction: (() -> Void)?
  /// SwiftUI `openWindow(id: "onboarding")` bridge, set by `ActionWirer`.
  var openOnboardingAction: (() -> Void)?
  /// SwiftUI `dismissWindow(id: "onboarding")` bridge, set by `ActionWirer`.
  var dismissOnboardingAction: (() -> Void)?
  /// Icon-refresh seam, set by `AppDelegate.attach(...)`. PR-B.3 retargets it
  /// to `MenuBarController`; the seam keeps the coordinator from reaching back
  /// into AppDelegate's menu-icon logic.
  var onOnboardingDismissed: (() -> Void)?

  /// Defensive race flag: set when `openOnboardingWindow()` is called before
  /// `openOnboardingAction` is wired; drained by `consumePendingOpenOnboarding()`.
  private var pendingOpenOnboarding: Bool = false

  init(
    canOpenOnboarding: @escaping @MainActor () -> Bool,
    isOnboardingComplete: @escaping @MainActor () -> Bool
  ) {
    self.canOpenOnboarding = canOpenOnboarding
    self.isOnboardingComplete = isOnboardingComplete
  }

  /// Install the main-window close observer. Called once from
  /// `AppDelegate.applicationDidFinishLaunching` at the same position the
  /// inline observer block occupied before PR-B.2.
  func installOnLaunch() {
    // When the unified window closes, revert to .accessory immediately.
    // There's only one window now, so no need for the 200ms re-check delay.
    // Store token so we can remove on termination (H11 observer leak fix).
    windowCloseObserver = NotificationCenter.default.addObserver(
      forName: NSWindow.willCloseNotification,
      object: nil,
      queue: .main
    ) { [weak self] notification in
      guard let window = notification.object as? NSWindow else { return }
      MainActor.assumeIsolated {
        guard let self else { return }
        // Capture the main window on the first close of a window we can
        // positively identify as ours. See `isMainWindow` — matching by scene
        // identity (not merely "titled and not onboarding") keeps a transient
        // titled dialog, e.g. Sparkle's attended-update window, from being
        // mistaken for the main window and flipping the app to `.accessory`
        // while the real window is still open (#1296 review).
        if self.mainWindow == nil, self.isMainWindow(window) {
          self.mainWindow = window
        }
        // Match by identity so status-bar/panel windows never trigger the reset.
        guard window === self.mainWindow else { return }
        NSApp.setActivationPolicy(.accessory)
      }
    }
  }

  /// Positively identifies our main window, the SwiftUI `Window("", id: "main")`.
  /// It carries the "main" scene identifier and an intentionally blank title (the
  /// toolbar wordmark is the identity). Preferring the scene identifier, with a
  /// blank-title fallback, means titled system dialogs (Sparkle's attended-update
  /// window, save/open panels — all of which carry non-empty titles) never match.
  private func isMainWindow(_ window: NSWindow) -> Bool {
    guard window.styleMask.contains(.titled) else { return false }
    // Definitive: our `Window(id: "main")` scene carries the "main" identifier.
    if window.identifier?.rawValue.contains("main") == true { return true }
    // Fallback for when the scene identifier is unavailable: the main window is
    // the only top-level titled window with a blank title. Reject sheets and
    // attached/child windows so a transient blank-title sheet is never mistaken
    // for it (cloud review #1311); onboarding ("Setup") and system dialogs carry
    // non-empty titles and are excluded by the blank-title test.
    return window.title.isEmpty && !window.isSheet && window.parent == nil
  }

  /// Remove both window-close observers. Called once from
  /// `AppDelegate.applicationWillTerminate`.
  func tearDown() {
    if let observer = windowCloseObserver {
      NotificationCenter.default.removeObserver(observer)
      windowCloseObserver = nil
    }
    if let observer = onboardingCloseObserver {
      NotificationCenter.default.removeObserver(observer)
      onboardingCloseObserver = nil
    }
  }

  /// Show the unified window: bring it to front, set .regular, activate.
  func showWindow() {
    if let action = openMainWindowAction {
      action()
    } else {
      // Fallback: find and show the existing main window by scene identity.
      for window in NSApp.windows where isMainWindow(window) {
        window.makeKeyAndOrderFront(nil)
        break
      }
    }
    NSApp.setActivationPolicy(.regular)
    NSApp.activate(ignoringOtherApps: true)
  }

  /// Open the onboarding window and begin monitoring for early close (abort flow).
  func openOnboardingWindow() {
    // (1) Eligibility — was `guard let appState` + `guard != .completed`.
    guard canOpenOnboarding() else { return }
    // (2) Not-yet-wired queue guard: if the SwiftUI bridge has not been wired
    // yet, queue the request instead of dropping it. Drained by
    // `consumePendingOpenOnboarding()` once `ActionWirer.task` runs.
    guard openOnboardingAction != nil else {
      pendingOpenOnboarding = true
      return
    }
    openOnboardingAction?()
    NSApp.setActivationPolicy(.regular)
    NSApp.activate(ignoringOtherApps: true)
    // Hide the main window so only the onboarding window is visible during setup.
    if let mainWin = self.mainWindow {
      mainWin.orderOut(nil)
    }

    // Capture the onboarding NSWindow by identity on first open.
    // We defer one run-loop cycle so SwiftUI has time to create/order the window
    // before we search NSApp.windows.
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      // SwiftUI Window(id: "onboarding") sets the title to the scene name ("Setup").
      // We capture by identity here so the close observer can match by reference,
      // not by title — title matching would fail if the scene name ever changes.
      if self.onboardingWindow == nil {
        self.onboardingWindow = NSApp.windows.first {
          $0.title == AppConstants.onboardingWindowTitle
        }
      }
      // Ensure the window is visible — openWindow(id:) is a silent no-op when
      // reopening a single-instance Window scene that was previously dismissed.
      self.onboardingWindow?.makeKeyAndOrderFront(nil)
    }

    // Monitor for user closing the onboarding window before completion.
    // Match by window identity (captured above), not by title string.
    if onboardingCloseObserver == nil {
      onboardingCloseObserver = NotificationCenter.default.addObserver(
        forName: NSWindow.willCloseNotification,
        object: nil,
        queue: .main
      ) { [weak self] notification in
        guard let window = notification.object as? NSWindow else { return }
        MainActor.assumeIsolated {
          guard let self else { return }
          // Match by captured identity; fall back to title if not yet captured.
          let isOnboardingWindow =
            (self.onboardingWindow != nil)
            ? window === self.onboardingWindow
            : window.title == AppConstants.onboardingWindowTitle
          guard isOnboardingWindow else { return }
          self.onboardingWindow = nil
          // Only treat as abort if onboarding not yet completed.
          if !self.isOnboardingComplete() {
            self.onOnboardingDismissed?()
          }
        }
      }
    }
  }

  /// Called by the onboarding Done button via the onComplete callback.
  /// State-driven: flips isOnboardingPresented to false, ActionWirer's onChange
  /// dismisses the window.
  func closeOnboardingWindow() {
    dismissOnboardingAction?()
    NSApp.setActivationPolicy(.accessory)
    onOnboardingDismissed?()
  }

  /// Drain a queued onboarding-open request. Returns `true` iff it replayed a
  /// queued open. Called by `ActionWirer.task` after the three SwiftUI bridge
  /// closures are wired; the return value lets `ActionWirer` avoid a double-open.
  func consumePendingOpenOnboarding() -> Bool {
    guard pendingOpenOnboarding else { return false }
    pendingOpenOnboarding = false
    openOnboardingWindow()
    return true
  }
}
