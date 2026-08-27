import EnviousWisprAppLive
import SwiftUI

/// #919: the thin launchable shell. This is all that remains in the app target
/// after the app-shell code moved into `EnviousWisprAppKit`. It owns ONLY:
///   - `@main` + the `@NSApplicationDelegateAdaptor` (must live in the `App`
///     struct, per Apple's `NSApplicationDelegateAdaptor` contract),
///   - app identity / Info.plist / entitlements / icon (in `Resources/`),
///   - the SwiftUI `Scene` declarations (window ids, sizes, resizability),
///   - constructing ONE `LiveApplication` in `init()` and attaching it to the
///     delegate before any lifecycle callback fires.
/// Everything else — every home, the construction order, the lifecycle work,
/// the view content — lives below. #2455 C1: this shell now imports ONLY
/// `EnviousWisprAppLive`, the sole production-choice site for live desktop-effect
/// implementations. The unit-test target links the kit and never AppLive. That
/// does not yet stop a test constructing a live implementation of its own — it
/// still links `EnviousWisprServices` — which C2 (#2459) closes.
@main
struct EnviousWisprApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
  @State private var application: LiveApplication

  init() {
    // Construct the composition root synchronously here (NOT lazily in a
    // delegate callback) so home construction keeps its pre-#919 ordering, then
    // hand it to the delegate before `applicationWillFinishLaunching` fires.
    let application = LiveApplication()
    // Initialize the stored `@State` BEFORE touching `appDelegate` (a property
    // wrapper access counts as using `self`, which Swift forbids until all
    // stored properties are initialized — same ordering the pre-#919 App used).
    _application = State(initialValue: application)
    appDelegate.attach(application: application)
  }

  var body: some Scene {
    // Real title (app name) so the Window menu, window switcher, and VoiceOver
    // have a name for this window; the visible title text is suppressed by the
    // principal toolbar item (the centered wordmark is the visible identity).
    // AppWindowCoordinator identifies this window by this title.
    Window(application.mainWindowTitle, id: "main") {
      application.mainWindowContent()
    }
    .defaultSize(width: 820, height: 600)
    .windowToolbarStyle(.unifiedCompact)

    // Onboarding window — non-resizable, centered, auto-opens on first launch.
    Window(application.onboardingWindowTitle, id: "onboarding") {
      application.onboardingWindowContent()
    }
    .windowResizability(.contentSize)
    .defaultSize(width: 500, height: 550)
  }
}
