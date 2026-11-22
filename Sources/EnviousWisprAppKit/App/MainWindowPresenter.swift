import AppKit
import EnviousWisprCore
import SwiftUI

/// Owns the app's main window as an AppKit window that hosts the SwiftUI root (#4842).
///
/// Why AppKit and not a SwiftUI `Window` scene: Apple documents that an app whose primary scene is a
/// single `Window` quits when that window closes. Two 2.6.1 users saw the app quit seconds after
/// closing the main window, with `applicationShouldTerminateAfterLastWindowClosed` returning false.
/// A window this type creates and releases leaves the app's lifetime to AppKit, whose default is to
/// keep running, the way Superwhisper and Spokenly do.
///
/// Lifecycle:
/// - show: one window; a second show refocuses it. The first show of a window builds fresh content.
/// - close (red button, Cmd+W, Window menu): AppKit closes it; this type forgets the window at once
///   so an immediate show builds a new one with fresh content (founder 2026-11-22: a reopened window
///   starts fresh), keeps the closing window alive until the next main-queue turn so every other
///   `willClose` observer still sees it, and tells the coordinator which window closed.
/// - quit: nothing to tear down; the window goes with the process.
/// It never calls `close()` itself (OverlayRetainedWindowTests' guard covers this module).
@MainActor
final class MainWindowPresenter: NSObject, NSWindowDelegate {
  /// The open main window, or nil when it is closed or not yet shown.
  private(set) var window: NSWindow?

  /// Builds the window's SwiftUI root. Installed by the bootstrapper with a weak capture of itself
  /// (a strong one would cycle bootstrapper → coordinator → presenter → closure → bootstrapper).
  var makeContent: (@MainActor () -> AnyView)?

  /// The main window is closing. The coordinator re-decides the Dock policy without it.
  var onMainWindowClosed: (@MainActor (NSWindow) -> Void)?

  /// The saved-frame key. Tests use a throwaway name so they never read or overwrite the user's
  /// saved main-window frame (`NSWindow Frame main`).
  var frameName = MainWindowLayout.frameName

  /// Reads the saved frame for `name` into `window`; injected in tests.
  var restoreSavedFrame: (NSWindow, String) -> Bool = { window, name in
    window.setFrameUsingName(name)
  }

  /// The closing window, held until the next main-queue turn (see the type comment).
  private var closingWindow: NSWindow?

  /// Shows the main window, building it (and fresh content) when none is open.
  func show() {
    let window = self.window ?? makeWindow()
    if window.isMiniaturized { window.deminiaturize(nil) }
    window.makeKeyAndOrderFront(nil)
  }

  /// Takes the window off screen without closing it (Setup covers it; closing would reset it).
  func orderOut() {
    window?.orderOut(nil)
  }

  private func makeWindow() -> NSWindow {
    let window = NSWindow(
      contentRect: NSRect(origin: .zero, size: MainWindowLayout.firstOpen),
      styleMask: [.titled, .closable, .miniaturizable, .resizable],
      backing: .buffered, defer: false)
    window.identifier = NSUserInterfaceItemIdentifier(MainWindowLayout.frameName)
    // The real title (the app name) names the window for VoiceOver, the window switcher and the
    // Window menu command; the toolbar's centered wordmark is the visible identity.
    window.title = LaunchWindowIdentity.mainTitle
    window.toolbarStyle = .unifiedCompact
    window.isReleasedWhenClosed = false
    // The app opens this window itself at launch, so macOS login restoration must not add one.
    window.isRestorable = false
    window.tabbingMode = .disallowed
    window.collectionBehavior.insert(.fullScreenPrimary)
    // The Window menu entry is our own command (it also reopens a closed window), so the automatic
    // list entry would show it twice.
    window.isExcludedFromWindowsMenu = true
    let host = NSHostingController(rootView: makeContent?() ?? AnyView(EmptyView()))
    // The window's size is the user's (and the saved frame's), not the content's: by default the
    // host resizes its window to the SwiftUI content's ideal size, which shrank it on first show
    // and would override the saved frame. The minimum is set on the window below.
    host.sizingOptions = []
    window.contentViewController = host
    window.contentMinSize = MainWindowLayout.minimum
    // Assigning the hosting controller shrinks the window to the not-yet-laid-out content size, and
    // `center()` reads the frame as it is (SetupWindowPresenter hit this). Size first, then center,
    // then let a saved frame from an earlier launch win.
    window.setContentSize(MainWindowLayout.firstOpen)
    window.center()
    _ = restoreSavedFrame(window, frameName)
    window.setFrameAutosaveName(frameName)
    window.delegate = self
    self.window = window
    return window
  }

  func windowWillClose(_ notification: Notification) {
    guard let closing = notification.object as? NSWindow, closing === window else { return }
    window = nil
    closingWindow = closing
    onMainWindowClosed?(closing)
    DispatchQueue.main.async { [weak self] in
      guard let self, self.closingWindow === closing else { return }
      closing.delegate = nil
      closing.contentViewController = nil
      self.closingWindow = nil
    }
  }
}

/// Window › EnviousWispr: brings back the main window, open or closed (#4842). A SwiftUI `Window`
/// scene used to add this entry itself; the AppKit window is left out of the automatic window list
/// (`isExcludedFromWindowsMenu`) so the entry appears once, where the window list goes.
package struct MainWindowMenuCommand: Commands {
  let title: String
  let show: @MainActor () -> Void

  package init(title: String, show: @escaping @MainActor () -> Void) {
    self.title = title
    self.show = show
  }

  package var body: some Commands {
    CommandGroup(before: .windowList) {
      Button(title) { show() }
    }
  }
}

/// The main window's sizes. Moved unchanged from the SwiftUI scene and root they used to sit on
/// (#4639 first-open size; #1024/#1296 minimum).
enum MainWindowLayout {
  /// First open for a new user; 1100x760 fits the smallest supported screen (13-inch MacBook Air,
  /// 1440x900). macOS restores the user's own size after that.
  static let firstOpen = NSSize(width: 1100, height: 760)
  /// 750 = two-card frame chrome (outer inset 28 + sidebar 200 + spacing 14 = 242) + the History
  /// split floors inside the detail card (230+8+260=498), so the window never crushes that split.
  static let minimum = NSSize(width: 750, height: 400)
  /// The saved-frame key the SwiftUI `Window(id: "main")` used (`NSWindow Frame main`), kept so
  /// every existing user keeps their size and position.
  static let frameName = "main"
}
