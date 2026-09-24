import AppKit
import EnviousWisprAppKit
import EnviousWisprServices

/// The real activation and panel-presentation calls (#2455 C3).
///
/// One stateless type conforms to both protocols because both are `NSApp`-adjacent;
/// splitting them would be two objects wrapping the same singleton. Consumers still
/// receive only the narrow protocol they use.
///
/// **Translation only, no decisions.** Which mode, which policy, and when are
/// AppKit's calls to make; this converts an enum case into the AppKit entry point
/// that case names, and nothing else. A `guard` or a policy check added here would
/// put half the activation rule in a module no test can read.
@MainActor
package final class LiveDesktopPresentationEffects: ApplicationActivating, PanelPresenting {

  package init() {}

  package func activate(_ mode: ApplicationActivationMode) {
    switch mode {
    case .standard:
      // The parameterless overload, preserved exactly. NOT
      // `activate(ignoringOtherApps: false)` — that is a different AppKit entry
      // point, and the one site using this form (#739's Sparkle flow) has always
      // called this one.
      NSApp.activate()
    case .ignoringOtherApps:
      NSApp.activate(ignoringOtherApps: true)
    }
  }

  package func setPolicy(_ policy: ApplicationPolicy) {
    switch policy {
    case .accessory:
      // `@discardableResult` is not on AppKit's declaration, and every existing
      // call site ignored the Bool. Discarding it explicitly preserves that
      // rather than introducing a warning the next reader silences differently.
      _ = NSApp.setActivationPolicy(.accessory)
    case .regular:
      _ = NSApp.setActivationPolicy(.regular)
    }
  }

  @discardableResult
  package func activate(_ application: NSRunningApplication) -> Bool {
    application.activate()
  }

  package func forceActivate(processIdentifier: pid_t) -> Bool {
    PasteService.forceActivateApp(pid: processIdentifier)
  }

  package func focus(_ element: AXUIElement) -> Bool {
    PasteService.focusElement(element)
  }

  /// The window read is the paste cascade's (`LivePastedRegionAXOperations.window(of:)`) and the
  /// raise is `PasteService.raiseWindow`; each call is bounded by the usual 0.5 s. The field's
  /// timeout goes back to `0`, the global default it had.
  package func raiseWindow(of element: AXUIElement) -> Bool? {
    let ax = LivePastedRegionAXOperations()
    let bound = PasteService.axMessagingTimeoutSeconds
    guard ax.setMessagingTimeout(element, seconds: bound) else { return nil }
    defer { _ = ax.setMessagingTimeout(element, seconds: 0) }
    guard case .window(let window) = ax.window(of: element) else { return nil }
    return PasteService.raiseWindow(window) { ax.setMessagingTimeout($0, seconds: bound) }
  }

  package func makeKeyAndOrderFront(_ panel: NSPanel) {
    panel.makeKeyAndOrderFront(nil)
  }
}
