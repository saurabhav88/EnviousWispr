import AppKit
import EnviousWisprAppKit

/// The real process-local scroll-wheel monitor (#3062).
///
/// **Translation only, no decisions.** Which events to rewrite and how live on
/// `WheelScrollSmoother` in the app layer; this type owns nothing but the AppKit
/// registration, so the unit-test target never installs a monitor on the
/// developer's desktop (`scripts/check-dependency-direction.sh` keeps the call
/// inside this module).
@MainActor
package final class LiveScrollWheelMonitor: ScrollWheelMonitoring {
  package init() {}

  package func install(_ handler: @escaping @MainActor (NSEvent) -> NSEvent?) -> Any? {
    NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
      // The monitor runs on the main thread; `assumeIsolated` asserts it. The
      // result crosses back out through a box because `NSEvent` is not
      // `Sendable` and the closure's return type must be.
      nonisolated(unsafe) var result: NSEvent? = event
      MainActor.assumeIsolated { result = handler(event) }
      return result
    }
  }

  package func remove(_ token: Any) {
    NSEvent.removeMonitor(token)
  }
}
