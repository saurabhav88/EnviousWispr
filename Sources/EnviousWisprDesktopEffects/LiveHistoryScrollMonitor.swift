import AppKit
import EnviousWisprAppKit

/// The real process-local scroll and drag watcher for History's meeting page on macOS 14
/// (#3147 PR4A).
///
/// **Translation only, no decisions.** Whether an event counts (the pointer over the transcript)
/// lives in the app layer; this type owns nothing but the AppKit registration, so the unit-test
/// target never installs a monitor on the developer's desktop
/// (`scripts/check-dependency-direction.sh` keeps the call inside this module).
@MainActor
package final class LiveHistoryScrollMonitor: HistoryScrollMonitoring {
  package init() {}

  package func install(_ handler: @escaping @MainActor () -> Void) -> Any? {
    NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .leftMouseDragged]) { event in
      // The monitor runs on the main thread; `assumeIsolated` asserts it.
      MainActor.assumeIsolated { handler() }
      return event
    }
  }

  package func remove(_ token: Any) {
    NSEvent.removeMonitor(token)
  }
}
