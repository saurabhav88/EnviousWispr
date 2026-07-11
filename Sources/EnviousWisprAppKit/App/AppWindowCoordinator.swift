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
  private static func matchesMainWindowIdentity(_ window: NSWindow) -> Bool {
    // The main window carries the app name as its title (visually suppressed by
    // the principal toolbar item, but still set for the Window menu / VoiceOver).
    // Match on it: onboarding ("Setup"), Sparkle's update dialog, and save/open
    // panels all carry different titles, so none is mistaken for the main window.
    window.styleMask.contains(.titled) && window.title == AppConstants.appName
  }

  private func isMainWindow(_ window: NSWindow) -> Bool {
    Self.matchesMainWindowIdentity(window)
  }

  /// #1392: the pure presentation decision, input-driven so it's testable
  /// without touching real `NSWindow`/`NSApp` state. A window "counts" if it
  /// matches the main-window identity AND is visible or minimized — not just
  /// currently onscreen. Bare `isVisible` alone would revert to accessory
  /// (and effectively strand the window) if the user minimized Settings
  /// while an attended update check was in flight (#1392 r1 finding).
  ///
  /// r2 correction (code-diff review): deliberately does NOT also treat
  /// "the whole app is Cmd+H-hidden" as presence. A window the user already
  /// closed can still linger in `NSApp.windows` in a hidden-but-retained
  /// state (SwiftUI single-instance `Window(id:)` scenes may keep the
  /// underlying `NSWindow` around to support instant reopen); an app-wide
  /// hidden flag can't distinguish that from a genuinely-still-open window
  /// the user merely Cmd+H'd. Reverting to accessory while the app is
  /// Cmd+H-hidden is accepted, documented behavior (Live UAT preface above)
  /// — the user explicitly hid the whole app, so losing the Dock icon is not
  /// a regression, and this check only ever needs to protect a window the
  /// user can currently see or reach via the Dock/minimized state.
  static func isMainWindowPresented(
    windowStates: [(matchesIdentity: Bool, isVisible: Bool, isMiniaturized: Bool)]
  ) -> Bool {
    windowStates.contains { state in
      state.matchesIdentity && (state.isVisible || state.isMiniaturized)
    }
  }

  /// #1392: whether the user still has a main app window right now. Static
  /// and state-free — callers that don't own a window reference (Sparkle's
  /// attended-update-session-end hook) can check without a new stored
  /// dependency. Thin snapshot wrapper around the pure decision above; Live
  /// UAT is what proves this wrapper's real-`NSApp` snapshot is correct.
  static func isMainWindowPresented() -> Bool {
    isMainWindowPresented(
      windowStates: NSApp.windows.map {
        (
          matchesIdentity: matchesMainWindowIdentity($0), isVisible: $0.isVisible,
          isMiniaturized: $0.isMiniaturized
        )
      })
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
