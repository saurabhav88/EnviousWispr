import AppKit
import ApplicationServices

/// The activation and panel-presentation calls that reach the desktop (#2455 C3,
/// issue #2460).
///
/// **Why these live in AppKit and the hotkey contract lives in Services.** An
/// interface belongs with its CONSUMER. `DesktopHotkeyEffects` sits in Services
/// because `HotkeyService` — its only consumer — is there. Every consumer of these
/// two is in AppKit: `AppWindowCoordinator`, `SparkleUpdateController`,
/// `AppLifecycleCoordinator`, `CenteredRelocationPresenter`, `QuickAddPanelHost`,
/// `WisprBootstrapper` and `ActionWirer`. Putting them in Services would move them
/// everything that uses them and make that module a place interfaces go when
/// nobody decided where they belong.
///
/// **AppKit still never imports `EnviousWisprDesktopEffects`.** The conformances
/// live in that module and are injected downward from `EnviousWisprAppLive`, so
/// this direction of the graph is unchanged and there is no temporary edge to
/// remove later.
///
/// **`PanelPresenting` takes an `NSPanel`, unlike the hotkey contract, which is
/// framework-pure.** That is deliberate and bounded: the panel is created and
/// owned by AppKit, which already has `NSPanel` in every signature around it, so
/// hiding the type here would buy nothing and cost a wrapper. What crosses is a
/// COMMAND — "give this panel the keyboard" — not an opaque handle a caller could
/// misuse. C4 (#2461) takes the overlay's own panel driving, where the calculus is
/// different because the tests there must be able to observe the commands.

package enum ApplicationActivationMode: Sendable {
  /// `NSApp.activate()`.
  case standard
  /// `NSApp.activate(ignoringOtherApps: true)`.
  ///
  /// A SEPARATE case rather than a Bool, and separate from `.standard` rather than
  /// mapped onto `activate(ignoringOtherApps: false)`: the parameterless overload
  /// is its own AppKit entry point, used at
  /// `SparkleUpdateController.swift:134`, and routing it through the other one
  /// would change which API that site calls on every macOS version.
  case ignoringOtherApps
}

package enum ApplicationPolicy: Sendable {
  case accessory
  case regular
}

/// Bring the app forward, and set whether it appears in the Dock.
///
/// Both operations, not one. An earlier revision of the plan listed a single
/// parameterless `activate()`; `setPolicy` is what moves the app between accessory
/// and regular, and a dictation app that cannot do that is a menu-bar app whose
/// windows never take focus properly.
@MainActor
package protocol ApplicationActivating: AnyObject {
  func activate(_ mode: ApplicationActivationMode)
  func setPolicy(_ policy: ApplicationPolicy)

  /// Bring ANOTHER running application to the front.
  ///
  /// Same family as the two above, and it took a review round to see why: the
  /// distinction that felt load-bearing — our app versus the user's — is about
  /// WHOSE focus moves, while the symptom is identical either way. A unit test
  /// that calls this steals focus on the developer's machine exactly as
  /// `NSApp.activate` does. Escape Recovery uses it to hand the caret back after a
  /// cancel.
  @discardableResult
  func activate(_ application: NSRunningApplication) -> Bool

  /// Bring another application forward through the Accessibility API.
  ///
  /// The route macOS 14+ needs: a background process is refused the foreground by
  /// `NSRunningApplication.activate()`, so the AX path is the one that works.
  /// Separate from `activate(_:)` above because Escape Recovery tries THIS first
  /// and falls back to that — two calls, and a test must be able to see which one
  /// the code chose.
  func forceActivate(processIdentifier: pid_t) -> Bool

  /// Put the caret in a specific field.
  ///
  /// The THIRD route in this family, and the one that made the point: I closed
  /// `activateFallback`, then `forceActivate`, and reported the hole shut both
  /// times while this one still defaulted live. Restoring the app alone hands the
  /// caret back to wherever that app last left it, which after a cancel is
  /// frequently a different field — so this is not decoration.
  func focus(_ element: AXUIElement) -> Bool
}

/// Give a panel the keyboard and bring it to the front.
@MainActor
package protocol PanelPresenting: AnyObject {
  func makeKeyAndOrderFront(_ panel: NSPanel)
}

/// The two presentation seams, carried together.
///
/// A non-defaulted composition CARRIER, not a service locator: no `shared`, no
/// static storage, no environment key, no default. AppLive fills both fields from
/// one stateless live instance; `WisprBootstrapper` retains only `application` and
/// passes `panels` straight to the collaborators that consume it. Leaf types
/// receive the narrow protocol they actually use — holding one of these
/// existentials never implies holding the other.
package struct DesktopPresentationEffects {
  package let application: any ApplicationActivating
  package let panels: any PanelPresenting

  package init(application: any ApplicationActivating, panels: any PanelPresenting) {
    self.application = application
    self.panels = panels
  }
}
