import AppKit
import EnviousWisprAppKit

/// The real process-local key-down monitor behind the Settings search arrival's key watcher
/// (#3545).
///
/// **Translation only, no decisions.** Which window's keys count and what a key means live on
/// `SettingsArrivalKeyWatcher` in the app layer; this type owns nothing but the AppKit
/// registration, so the unit-test target never installs a monitor on the developer's desktop
/// (`scripts/check-dependency-direction.sh` keeps the call inside this module).
@MainActor
package final class LiveSettingsKeyMonitor: SettingsKeyMonitoring {
  package init() {}

  package func install(_ handler: @escaping @MainActor (NSEvent) -> Void) -> Any? {
    NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
      // The monitor runs on the main thread; `assumeIsolated` asserts it. The key is passed on
      // unchanged.
      MainActor.assumeIsolated { handler(event) }
      return event
    }
  }

  package func remove(_ token: Any) {
    NSEvent.removeMonitor(token)
  }
}
