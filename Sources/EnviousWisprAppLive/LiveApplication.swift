import EnviousWisprAppKit
import EnviousWisprServices
import SwiftUI

/// The production composition root (#2455 C1, issue #2458).
///
/// **What this module owns, and why it is not a forwarder.** `WisprBootstrapper`
/// now takes a REQUIRED, non-defaulted `makeHotkeyService`, so
/// `EnviousWisprAppKit` no longer exposes an IMPLICIT production assembly path.
/// AppKit can still be made to assemble one — it imports Services, so a caller
/// there could pass a live factory explicitly — but nothing does, and the
/// production source chooses the live implementation here and nowhere else. That
/// is the ownership grounded review r2 demanded when it rejected "a passive
/// forwarding module would preserve the wording while changing nothing".
///
/// **Why the choice has to live above AppKit, and what that is not yet.**
/// `EnviousWisprTests` links `EnviousWisprAppKit` and `EnviousWisprServices`. After
/// C1 it cannot get a production root by accident — `WisprBootstrapper.init` has no
/// default — but it CAN still construct `HotkeyService(telemetry: .live)` directly,
/// because Services is still in its link graph. C2 (#2459) moves the live
/// implementation into `EnviousWisprDesktopEffects`, which the test target does not
/// link, and that is the wall. C0's environment tripwire (#2457) is the tripwire in
/// front of it.
///
/// C2 (#2459) replaces the concrete `HotkeyService` construction below with a live
/// adapter from `EnviousWisprDesktopEffects` and drops this module's direct
/// `EnviousWisprServices` edge. The seam itself does not move.
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
    bootstrapper = WisprBootstrapper(
      makeHotkeyService: {
        // #1175: the live telemetry sink is constructor-injected so it is in
        // place before `start()` runs any registration (heart path + bootstrap
        // ordering). Moving the construction here did not move that guarantee.
        HotkeyService(telemetry: .live)
      })
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
