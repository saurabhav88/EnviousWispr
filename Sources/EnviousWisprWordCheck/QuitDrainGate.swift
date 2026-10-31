import Foundation

/// Counts every MLX entry in flight and refuses new ones once quit has begun (#3939). Process
/// wide because MLX's scheduler is: its static destructor commits the GPU command buffer, so
/// `exit()` must not run while any entry is still encoding into it. Admission and the flag share
/// one lock, so no entry can pass the check after `drainForTermination` has set it.
final class QuitDrainGate: @unchecked Sendable {
  private let condition = NSCondition()
  private var active = 0
  private var terminating = false

  /// `duringQuit`: quit cleanup (cache clear, a model's own release) is still admitted, and
  /// counted, so the drain waits for it too.
  func enter(duringQuit: Bool = false) -> Bool {
    condition.lock()
    defer { condition.unlock() }
    if terminating && !duringQuit { return false }
    active += 1
    return true
  }

  func leave() {
    condition.lock()
    active -= 1
    if active == 0 { condition.broadcast() }
    condition.unlock()
  }

  /// Refuses new work, then waits up to `timeout` seconds for entries in flight. Returns whether
  /// everything in flight ended.
  func drain(timeout: TimeInterval) -> Bool {
    condition.lock()
    defer { condition.unlock() }
    terminating = true
    let deadline = Date(timeIntervalSinceNow: timeout)
    while active > 0 {
      if !condition.wait(until: deadline) { return active == 0 }
    }
    return true
  }
}
