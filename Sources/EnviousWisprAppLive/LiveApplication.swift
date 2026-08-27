import EnviousWisprAppKit
import EnviousWisprDesktopEffects
import SwiftUI

/// The production composition root (#2455 C1, issue #2458).
///
/// **What this module owns.** `WisprBootstrapper` takes a REQUIRED, non-defaulted
/// `makeHotkeyEffects`, so `EnviousWisprAppKit` exposes no implicit production
/// assembly path, and this is the only place a live implementation is named. That
/// is the ownership grounded review r2 demanded when it rejected "a passive
/// forwarding module would preserve the wording while changing nothing".
///
/// **Why the choice has to live here.** `EnviousWisprTests` declares
/// `EnviousWisprAppKit` and `EnviousWisprServices`, and NOT
/// `EnviousWisprDesktopEffects`. After C2 the Carbon and `NSEvent` calls live only
/// in that module.
///
/// What stops a unit test reaching them is `scripts/check-dependency-direction.sh`,
/// which scans the test targets and rejects that module by name — NOT the module
/// graph. Under Xcode the graph does not enforce itself: an undeclared import of
/// that module from the test target compiles and links (measured 2026-08-26).
/// C0's environment tripwire (#2457) stood in front of that gap; C5 (#2462) can
/// retire it for hotkeys now that the gate covers them.
@MainActor
package final class LiveApplication {
  /// App-lifetime owner of the bootstrapper. The shell strongly retains this
  /// `LiveApplication` in `@State`; the delegate's reference is `weak`, exactly as
  /// it was before this module existed. Mounted SwiftUI roots may also retain the
  /// bootstrapper, but its lifetime does not depend on them.
  private let bootstrapper: WisprBootstrapper

  package init() {
    // Construction stays synchronous and in this order for the same reason it
    // always has: home construction must keep its pre-#919 ordering, and the
    // delegate must be attached before `applicationWillFinishLaunching` fires.
    // One stateless live type conforms to both protocols, and the same instance
    // fills both fields of `DesktopPresentationEffects`.
    let presentation = LiveDesktopPresentationEffects()
    bootstrapper = WisprBootstrapper(
      makeHotkeyEffects: { LiveDesktopHotkeyEffects() },
      presentationEffects: DesktopPresentationEffects(
        application: presentation, panels: presentation),
      relocationRelauncher: LiveRelocationRelauncher(),
      // #2455 C4: the pill. `makePanel` is a factory rather than an instance
      // because the host builds its panel lazily, on first presentation.
      overlayEffects: DesktopOverlayEffects(
        makePanel: { LiveOverlayPanelDriver() },
        workspace: LiveWorkspaceObserver()))
  }

  // MARK: - Scene surface

  package var mainWindowTitle: String { bootstrapper.mainWindowTitle }
  package var onboardingWindowTitle: String { bootstrapper.onboardingWindowTitle }

  package func mainWindowContent() -> some View { bootstrapper.mainWindowContent() }
  package func onboardingWindowContent() -> some View {
    bootstrapper.onboardingWindowContent()
  }

  // MARK: - Lifecycle surface

  package func applicationWillFinishLaunching() {
    bootstrapper.applicationWillFinishLaunching()
    // #2377 Phase 6: arm the DEBUG marker sink in the callback BEFORE the
    // measured one, and AFTER this callback's own production work.
    //
    // Before `applicationDidFinishLaunching` because that interval is what is
    // measured, and the sink's one-time setup must not land inside it. After the
    // forwarding above because #739 requires Sparkle's cross-launch correlation
    // to run at the earliest callback, and putting measurement in front of it
    // would make a DEBUG instrument the first thing a launch does.
    //
    // #2455 C1: this moved down from the shell's `AppDelegate` so the executable
    // imports only this module. It still brackets the same bootstrapper production
    // call in the same order. The measured interval now EXCLUDES the shell's weak
    // `application` lookup and the dispatch into this type, which were previously
    // inside it; production lifecycle ordering is unchanged.
    #if DEBUG
      OverlayFirstRenderMarkers.prepare()
    #endif
  }
  package func applicationDidFinishLaunching() {
    // #2377 Phase 6: DEBUG-only measurement of this forwarding call, which is
    // where launch work happens. `capture` reads the clock and nothing else; the
    // environment read, the string and the write all run in `emit`, after the
    // interval has closed.
    #if DEBUG
      let launchEnter = OverlayFirstRenderMarkers.capture(.launchEnter)
    #endif
    bootstrapper.applicationDidFinishLaunching()
    #if DEBUG
      OverlayFirstRenderMarkers.emit(
        launchEnter, OverlayFirstRenderMarkers.capture(.launchExit))
    #endif
  }
  package func applicationDidBecomeActive() {
    bootstrapper.applicationDidBecomeActive()
  }
  package func applicationWillTerminate() {
    bootstrapper.applicationWillTerminate()
  }
}
