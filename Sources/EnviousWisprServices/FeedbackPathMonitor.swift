import Foundation
import Network

/// Whether the Mac has a network path, for the feedback outbox (#3269). A path permits a send
/// attempt; only Sentry's answer proves delivery. Injected so tests drive path changes directly.
protocol FeedbackPathMonitoring: AnyObject, Sendable {
  /// The latest known state; `false` until the first update, so nothing is attempted blind.
  var isSatisfied: Bool { get }
  /// Starts watching. `onChange` receives every state, including the first one.
  func start(onChange: @escaping @Sendable (Bool) -> Void)
  func cancel()
}

/// The production monitor: its own `NWPathMonitor`, independent of the update checker's, and it
/// reports the initial state rather than suppressing it.
final class FeedbackPathMonitor: FeedbackPathMonitoring, @unchecked Sendable {
  private let monitor = NWPathMonitor()
  private let queue = DispatchQueue(label: "com.enviouswispr.feedback-path", qos: .utility)
  private let lock = NSLock()
  private var satisfied = false

  var isSatisfied: Bool { lock.withLock { satisfied } }

  func start(onChange: @escaping @Sendable (Bool) -> Void) {
    monitor.pathUpdateHandler = { [weak self] path in
      guard let self else { return }
      let isSatisfied = path.status == .satisfied
      lock.withLock { satisfied = isSatisfied }
      onChange(isSatisfied)
    }
    monitor.start(queue: queue)
  }

  func cancel() { monitor.cancel() }
}
