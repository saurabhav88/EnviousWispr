import AppKit
import EnviousWisprCore
import Observation

/// Owns the main-window bridge, Setup entry points and application activation policy.
@MainActor
@Observable
final class AppWindowCoordinator: UpdateDialogPresenting {
  private let isOnboardingComplete: @MainActor () -> Bool
  private var windowCloseObserver: (any NSObjectProtocol)?
  var setupSession: SetupSession?
  /// #4842: the main window, an AppKit window this app creates and releases. Its close never
  /// quits the app (a SwiftUI `Window` primary scene did, for some 2.6.1 users).
  let mainWindowPresenter = MainWindowPresenter()
  private(set) var mainWindowVisitIsSetupHandoff = false
  private var openedFirstSurface = false

  /// #2455 C3: required and non-defaulted. Every activation and Dock-policy call
  /// this type makes goes through it, so a default would let a unit test move the
  /// real app between accessory and regular — the pill-flash half of the symptom
  /// this epic exists to remove.
  private let application: any ApplicationActivating

  /// #2480: the "Show app in Dock" setting, read at each fall point.
  private let showInDock: @MainActor () -> Bool

  /// #2480: true while Sparkle has an update dialog up, so a window closing
  /// underneath it cannot drop the app to accessory and strand the dialog.
  private var updateDialogActive = false

  /// #3147 PR3: open transcript windows, registered by the window's own content
  /// (`TranscriptWindowRoot`) once AppKit gives it a window. Weak, so a closed window
  /// leaves on its own. Never matched by title: the title is the translated file name.
  private let transcriptWindows = NSHashTable<NSWindow>.weakObjects()

  init(
    application: any ApplicationActivating,
    showInDock: @escaping @MainActor () -> Bool,
    isOnboardingComplete: @escaping @MainActor () -> Bool
  ) {
    self.application = application
    self.showInDock = showInDock
    self.isOnboardingComplete = isOnboardingComplete
    mainWindowPresenter.onMainWindowClosed = { [weak self] closing in
      self?.refreshActivationPolicy(excluding: closing)
    }
  }

  // MARK: - Dock policy (#2480)
  //
  // Rises happen only at events we own (launch, a user open, a Sparkle dialog)
  // and always go to `.regular`. Falls happen only at events AppKit reliably
  // posts (`willClose`), a Sparkle session end, or the setting flipping, and are
  // the only places a decision is made. No code tries to detect a window
  // APPEARING: #2480's review rounds found no complete signal for that
  // (`didChangeOcclusionStateNotification` tracks occlusion, not every
  // `isVisible` change, and an observer can miss a launch-time window).

  /// The whole policy rule, pure. `.regular` (Dock icon, app menu, Cmd-Tab) when
  /// the user wants the Dock icon or anything of ours is on screen; otherwise
  /// `.accessory` (menu bar icon only).
  static func activationPolicy(
    showInDock: Bool, mainWindowPresented: Bool, onboardingPresented: Bool,
    transcriptWindowPresented: Bool, updateDialogActive: Bool
  ) -> ApplicationPolicy {
    showInDock || mainWindowPresented || onboardingPresented || transcriptWindowPresented
      || updateDialogActive
      ? .regular : .accessory
  }

  /// Launch rise, from `applicationWillFinishLaunching` before any scene or Sparkle
  /// starts. `.regular` under EITHER setting: the main window opens at launch, and
  /// with the setting off the Dock icon then shows only until that window closes,
  /// which is what "off" promises. Before #2480 launch forced `.accessory`, which
  /// left the launch window behind other apps with no app menu or Cmd-Tab entry.
  func beginLaunch() {
    application.setPolicy(.regular)
  }

  /// Sparkle is about to show a modal (`UpdateDialogPresenting`).
  func updateDialogWillShow() {
    updateDialogActive = true
    application.setPolicy(.regular)
    application.activate(.standard)
  }

  /// Sparkle's whole update session ended (`UpdateDialogPresenting`).
  func updateSessionDidEnd() {
    updateDialogActive = false
    refreshActivationPolicy(excluding: nil)
  }

  /// Fall point. Reads our windows ONCE, now, at a moment when they are stable,
  /// leaving out the window that is closing (it still reads visible during
  /// `willClose`).
  func refreshActivationPolicy(excluding closing: NSWindow?) {
    let windows = NSApp.windows.filter { $0 !== closing }
    let main = mainWindowPresenter.window.flatMap { $0 === closing ? nil : $0 }
    application.setPolicy(
      Self.activationPolicy(
        showInDock: showInDock(),
        mainWindowPresented: Self.isMainWindowPresented(
          main.map { (isVisible: $0.isVisible, isMiniaturized: $0.isMiniaturized) }),
        onboardingPresented: windows.contains {
          Self.matchesOnboardingWindowIdentity($0) && ($0.isVisible || $0.isMiniaturized)
        },
        transcriptWindowPresented: transcriptWindows.allObjects.contains {
          $0 !== closing && ($0.isVisible || $0.isMiniaturized)
        },
        updateDialogActive: updateDialogActive))
  }

  /// #3147 PR3: a transcript window appeared. A rise, so the window has an app menu,
  /// Dock icon and Cmd-Tab entry even when the main window is closed.
  func registerTranscriptWindow(_ window: NSWindow) {
    guard !transcriptWindows.contains(window) else { return }
    transcriptWindows.add(window)
    application.setPolicy(.regular)
  }

  /// #3147 PR3: brings a registered transcript window back to the front (Paste needing the user
  /// from that window). Through the injected activation seam, like every rise here.
  func showTranscriptWindow(_ window: NSWindow) {
    guard transcriptWindows.contains(window) else { return }
    window.makeKeyAndOrderFront(nil)
    application.setPolicy(.regular)
    application.activate(.ignoringOtherApps)
  }

  /// Whether `window` is a registered transcript window (for the close observer and tests).
  func isTranscriptWindow(_ window: NSWindow) -> Bool {
    transcriptWindows.contains(window)
  }

  /// Install the Setup and transcript window close observer (#2480: the Dock-policy fall
  /// point). The main window reports its own close through `MainWindowPresenter` (#4842).
  /// Called once from `AppLifecycleCoordinator.runDidFinishLaunching`.
  func installOnLaunch() {
    // Store token so we can remove on termination (H11 observer leak fix).
    windowCloseObserver = NotificationCenter.default.addObserver(
      forName: NSWindow.willCloseNotification,
      object: nil,
      queue: .main
    ) { [weak self] notification in
      guard let window = notification.object as? NSWindow else { return }
      MainActor.assumeIsolated {
        guard let self else { return }
        // Match by identity so status-bar/panel windows never trigger a re-decision.
        guard
          Self.matchesOnboardingWindowIdentity(window) || self.transcriptWindows.contains(window)
        else { return }
        self.refreshActivationPolicy(excluding: window)
        self.transcriptWindows.remove(window)
      }
    }
  }

  /// The onboarding scene's window. Owner: `OnboardingWindowIdentity`.
  private static func matchesOnboardingWindowIdentity(_ window: NSWindow) -> Bool {
    OnboardingWindowIdentity.matches(window)
  }

  /// #1392: the pure presentation decision, input-driven so it's testable without touching real
  /// `NSWindow`/`NSApp` state. The main window "counts" if it exists and is visible or minimized,
  /// not just currently onscreen: bare `isVisible` would revert to accessory (and strand the
  /// window) if the user minimized it while an attended update check was in flight. An app-wide
  /// Cmd+H is deliberately not presence; reverting to accessory then is accepted (#1392 r2).
  static func isMainWindowPresented(
    _ main: (isVisible: Bool, isMiniaturized: Bool)?
  ) -> Bool {
    guard let main else { return false }
    return main.isVisible || main.isMiniaturized
  }

  func tearDown() {
    if let observer = windowCloseObserver {
      NotificationCenter.default.removeObserver(observer)
      windowCloseObserver = nil
    }
  }

  /// Show the unified window (building it when closed, #4842), set .regular, activate.
  ///
  /// Always opens something, so it returns true (#2480: the Dock-icon reopen handler
  /// reports "handled" from this).
  @discardableResult
  func showWindow() -> Bool {
    mainWindowPresenter.show()
    application.setPolicy(.regular)
    application.activate(.ignoringOtherApps)
    return true
  }

  /// #2480: Dock-icon reopen. Returns whether it handled the click. Until onboarding
  /// is done the window the user needs is Setup, even when the main window is also on
  /// screen (first run can leave it visible, #3149); afterwards it is the main window.
  /// When that window is already on screen, AppKit's default bringing it forward is
  /// right.
  func reopenFromDock() -> Bool {
    let onboardingDone = isOnboardingComplete()
    let neededWindowOnScreen =
      onboardingDone
      ? mainWindowPresenter.window?.isVisible == true
      : NSApp.windows.contains { Self.matchesOnboardingWindowIdentity($0) && $0.isVisible }
    guard !neededWindowOnScreen else { return false }
    guard onboardingDone else {
      return openOnboardingWindow()
    }
    return showWindow()
  }

  /// #4842: the launch's first window, once. Setup when it is admitted (the main window stays
  /// unshown until Setup finishes); otherwise the main window. An interrupted Setup visit that
  /// completes inside `openOnboardingWindow()` has already shown the main window through
  /// `finishSetup`, so it is shown only when it does not exist yet. The surface that opens
  /// activates the app, so launch activates once.
  func openFirstSurfaceAtLaunch(automaticallyOpenSetup: Bool) {
    guard !openedFirstSurface else { return }
    openedFirstSurface = true
    if automaticallyOpenSetup, openOnboardingWindow() { return }
    guard mainWindowPresenter.window == nil else { return }
    showWindow()
  }

  @discardableResult
  func openOnboardingWindow() -> Bool {
    guard !isOnboardingComplete(), let setupSession, setupSession.begin() else { return false }
    application.setPolicy(.regular)
    setupSession.present()
    // Setup covers the main window; ordered out, not closed, so it keeps its place.
    mainWindowPresenter.orderOut()
    return true
  }

  func restartOnboarding() {
    guard let setupSession else { return }
    setupSession.reset()
    openOnboardingWindow()
  }

  func endMainWindowVisit() {
    mainWindowVisitIsSetupHandoff = false
  }

  /// The Setup session has already marked the visit complete and dismissed its window.
  func finishSetup() {
    mainWindowVisitIsSetupHandoff = true
    showWindow()
    refreshActivationPolicy(excluding: nil)
  }

}

/// What Sparkle needs from the Dock-policy owner (#2480). A required init
/// parameter of `SparkleUpdateController`, so an unwired state cannot compile.
@MainActor
protocol UpdateDialogPresenting: AnyObject {
  /// Sparkle is about to show a modal: make the app regular and bring it forward.
  func updateDialogWillShow()
  /// The whole update session ended: re-decide the Dock policy.
  func updateSessionDidEnd()
}
