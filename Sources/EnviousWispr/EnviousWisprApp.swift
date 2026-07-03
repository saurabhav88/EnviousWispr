import EnviousWisprAppKit
import SwiftUI

/// #919: the thin launchable shell. This is all that remains in the app target
/// after the app-shell code moved into `EnviousWisprAppKit`. It owns ONLY:
///   - `@main` + the `@NSApplicationDelegateAdaptor` (must live in the `App`
///     struct, per Apple's `NSApplicationDelegateAdaptor` contract),
///   - app identity / Info.plist / entitlements / icon (in `Resources/`),
///   - the SwiftUI `Scene` declarations (window ids, sizes, resizability),
///   - constructing ONE `WisprBootstrapper` in `init()` and attaching it to the
///     delegate before any lifecycle callback fires.
/// Everything else — every home, the construction order, the lifecycle work,
/// the view content — lives in the kit. The unit-test target links the kit, so
/// `xcodebuild test` never launches this app.
@main
struct EnviousWisprApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
  @State private var bootstrapper: WisprBootstrapper

  init() {
    // Construct the composition root synchronously here (NOT lazily in a
    // delegate callback) so home construction keeps its pre-#919 ordering, then
    // hand it to the delegate before `applicationWillFinishLaunching` fires.
    let bootstrapper = WisprBootstrapper()
    // Initialize the stored `@State` BEFORE touching `appDelegate` (a property
    // wrapper access counts as using `self`, which Swift forbids until all
    // stored properties are initialized — same ordering the pre-#919 App used).
    _bootstrapper = State(initialValue: bootstrapper)
    appDelegate.attach(bootstrapper: bootstrapper)
  }

  var body: some Scene {
    // Blank title so macOS doesn't render the window name in the compact
    // toolbar (it would duplicate the centered wordmark); the centered toolbar
    // item is the visible identity. AppWindowCoordinator identifies this window
    // structurally (titled, not the onboarding window), not by title string.
    Window("", id: "main") {
      bootstrapper.mainWindowContent()
    }
    .defaultSize(width: 820, height: 600)
    .windowToolbarStyle(.unifiedCompact)

    // Onboarding window — non-resizable, centered, auto-opens on first launch.
    Window(bootstrapper.onboardingWindowTitle, id: "onboarding") {
      bootstrapper.onboardingWindowContent()
    }
    .windowResizability(.contentSize)
    .defaultSize(width: 500, height: 550)
  }
}
