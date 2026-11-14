import AppKit
import EnviousWisprAppKit

/// A local rehearsal listener for one Setup window. All other events keep their normal dispatch.
@MainActor
package final class LiveSetupShortcutMonitor: SetupShortcutMonitoring {
  package init() {}

  package func install(
    in window: NSWindow, handling: @escaping @MainActor (NSEvent) -> Bool
  ) -> Any? {
    NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) {
      [weak window] event in
      let consumed = MainActor.assumeIsolated {
        Self.consumes(event, in: window, handling: handling)
      }
      return consumed ? nil : event
    }
  }

  package func remove(_ token: Any) { NSEvent.removeMonitor(token) }

  static func consumes(
    _ event: NSEvent, in window: NSWindow?, handling: @MainActor (NSEvent) -> Bool
  ) -> Bool {
    guard let window, window.isKeyWindow, event.window === window else { return false }
    return handling(event)
  }
}
