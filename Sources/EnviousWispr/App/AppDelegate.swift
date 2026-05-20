import AppKit
import EnviousWisprServices
import Foundation

/// AppDelegate manages the menu bar status item lifecycle via AppKit.
///
/// SwiftUI's MenuBarExtra has known click-routing issues when launched outside
/// Xcode or as a bare binary, so the app uses an `NSApplicationDelegate`.
///
/// PR-B of #763: `AppDelegate` is a thin AppKit adapter. It owns no app state
/// — `EnviousWisprApp` owns the App-owned homes as `@State` and pushes two
/// weak refs in via `attach(...)` synchronously during `EnviousWisprApp.init()`,
/// before any `NSApplicationDelegate` callback fires. The five forced delegate
/// callbacks forward to `SparkleUpdateController` and `AppLifecycleCoordinator`.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  private weak var sparkleUpdateController: SparkleUpdateController?
  private weak var appLifecycleCoordinator: AppLifecycleCoordinator?

  /// Receive App-owned home refs from `EnviousWisprApp.init()` before any
  /// delegate callback fires.
  func attach(
    sparkleUpdateController: SparkleUpdateController,
    appLifecycleCoordinator: AppLifecycleCoordinator
  ) {
    self.sparkleUpdateController = sparkleUpdateController
    self.appLifecycleCoordinator = appLifecycleCoordinator
  }

  /// Issue #739: Sparkle's cross-launch correlation must run at this earliest
  /// callback, before SwiftUI mounts the App's scenes (PR-B.1 of #763).
  func applicationWillFinishLaunching(_ notification: Notification) {
    assertAttached(sparkleUpdateController, "sparkleUpdateController")
    sparkleUpdateController?.startUpdater()
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    assertAttached(appLifecycleCoordinator, "appLifecycleCoordinator")
    appLifecycleCoordinator?.runDidFinishLaunching()
  }

  func applicationDidBecomeActive(_ notification: Notification) {
    appLifecycleCoordinator?.runDidBecomeActive()
  }

  func applicationWillTerminate(_ notification: Notification) {
    appLifecycleCoordinator?.runWillTerminate()
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    // Menu bar app — keep running when windows close.
    // User quits via "Quit EnviousWispr" in the status bar menu.
    return false
  }

  /// Loud tripwire for a wiring regression: a weak ref must never be nil when
  /// a lifecycle callback fires (`attach(...)` runs synchronously in
  /// `EnviousWisprApp.init()`). Debug builds crash so the mistake is caught
  /// before any release ships; release builds emit a Sentry breadcrumb so a
  /// future regression is diagnosable. The nil path is unreachable in a
  /// correctly-wired build.
  private func assertAttached<T: AnyObject>(_ ref: T?, _ name: String) {
    #if DEBUG
      if ref == nil {
        assertionFailure(
          "AppDelegate.\(name) was nil during a lifecycle callback — "
            + "EnviousWisprApp.init() wiring failure.")
      }
    #endif
    if ref == nil {
      SentryBreadcrumb.add(
        stage: "app_delegate", message: "lifecycle ref nil", data: ["ref": name])
    }
  }
}
