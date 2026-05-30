import AppKit
import EnviousWisprAppKit
import Foundation

/// AppDelegate manages the menu bar status item lifecycle via AppKit.
///
/// SwiftUI's MenuBarExtra has known click-routing issues when launched outside
/// Xcode or as a bare binary, so the app uses an `NSApplicationDelegate`.
///
/// #919: `AppDelegate` stays in the thin shell (the `@NSApplicationDelegateAdaptor`
/// must live in the `@main` `App` struct's module). It is a pure AppKit adapter:
/// it owns no app state and holds a single `weak` ref to the `WisprBootstrapper`
/// (constructed and attached synchronously in `EnviousWisprApp.init()`, before
/// any delegate callback fires). The forced delegate callbacks forward to the
/// bootstrapper, which drives Sparkle + the lifecycle coordinator internally —
/// so the shell imports ONLY `EnviousWisprAppKit`, never the engine modules.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  private weak var bootstrapper: WisprBootstrapper?

  /// Receive the composition root from `EnviousWisprApp.init()` before any
  /// delegate callback fires.
  func attach(bootstrapper: WisprBootstrapper) {
    self.bootstrapper = bootstrapper
  }

  /// Issue #739: Sparkle's cross-launch correlation must run at this earliest
  /// callback, before SwiftUI mounts the App's scenes.
  func applicationWillFinishLaunching(_ notification: Notification) {
    assertAttached()
    bootstrapper?.applicationWillFinishLaunching()
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    assertAttached()
    bootstrapper?.applicationDidFinishLaunching()
  }

  func applicationDidBecomeActive(_ notification: Notification) {
    bootstrapper?.applicationDidBecomeActive()
  }

  func applicationWillTerminate(_ notification: Notification) {
    bootstrapper?.applicationWillTerminate()
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    // Menu bar app — keep running when windows close.
    // User quits via "Quit EnviousWispr" in the status bar menu.
    return false
  }

  /// Loud DEBUG tripwire for a wiring regression: the bootstrapper must never be
  /// nil when a lifecycle callback fires (`attach(...)` runs synchronously in
  /// `EnviousWisprApp.init()`, and the shell strong-holds it via `@State`, so
  /// the weak ref cannot drop while the app is alive). #919: the prior
  /// release-build Sentry breadcrumb on this unreachable path was dropped so the
  /// shell needs no `EnviousWisprServices` import; the DEBUG assert still catches
  /// any wiring regression at development time.
  private func assertAttached() {
    #if DEBUG
      if bootstrapper == nil {
        assertionFailure(
          "AppDelegate.bootstrapper was nil during a lifecycle callback — "
            + "EnviousWisprApp.init() wiring failure.")
      }
    #endif
  }
}
