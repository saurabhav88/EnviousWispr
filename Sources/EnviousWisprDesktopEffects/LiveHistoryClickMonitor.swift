import AppKit
import EnviousWisprAppKit

/// The real process-local left-click watcher behind History's rename fields (#4611): clicking
/// away from an open field saves it.
///
/// **Translation only, no decisions.** Whether a click is outside the field and what it does
/// live in the app layer (`HistoryInlineTitle`); this type owns nothing but the AppKit
/// registration, so the unit-test target never installs a monitor on the developer's desktop
/// (`scripts/check-dependency-direction.sh` keeps the call inside this module).
@MainActor
package final class LiveHistoryClickMonitor: HistoryClickMonitoring {
  package init() {}

  package func install(_ handler: @escaping @MainActor (NSEvent) -> Void) -> Any? {
    NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp]) { event in
      // The monitor runs on the main thread; `assumeIsolated` asserts it.
      MainActor.assumeIsolated { handler(event) }
      return event
    }
  }

  package func remove(_ token: Any) {
    NSEvent.removeMonitor(token)
  }
}
