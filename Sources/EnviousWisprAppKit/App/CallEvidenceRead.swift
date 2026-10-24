import EnviousWisprServices
import Foundation
import os

/// One evidence read for the call watcher, off the main actor and bounded (#4012 §3.3): the
/// Accessibility walk blocks its thread, so it runs on its own serial queue (never the shared
/// Swift worker pool), and the caller waits at most one second; a read that does not finish in
/// time is `.unknown`, never "no call". Only one read runs at a time: while an abandoned read
/// is still stuck, later reads answer `.unknown` at once instead of piling up behind it.
enum CallEvidenceRead {
  /// Where reads run, and whether one is still running. The app shares one; a test makes its own.
  final class Lane: Sendable {
    let queue = DispatchQueue(label: "com.enviouswispr.call-evidence", qos: .userInitiated)
    let reading = OSAllocatedUnfairLock(initialState: false)
    static let shared = Lane()
  }

  static func bounded(
    rule: CallAppCatalog.Rule, pid: Int32, bound: Duration = .seconds(1), lane: Lane = .shared,
    read: @escaping @Sendable (CallAppCatalog.Rule, Int32) -> CallEvidenceReader.Evidence = {
      CallEvidenceReader.evidence(for: $0, holderPID: $1)
    }
  ) async -> CallEvidenceReader.Evidence {
    let reading = lane.reading
    let claimed = reading.withLock { busy -> Bool in
      if busy { return false }
      busy = true
      return true
    }
    guard claimed else { return .unknown }
    return await withCheckedContinuation {
      (continuation: CheckedContinuation<CallEvidenceReader.Evidence, Never>) in
      let resumed = OSAllocatedUnfairLock(initialState: false)
      let finish: @Sendable (CallEvidenceReader.Evidence) -> Void = { value in
        let first = resumed.withLock { done -> Bool in
          if done { return false }
          done = true
          return true
        }
        if first { continuation.resume(returning: value) }
      }
      lane.queue.async {
        let value = read(rule, pid)
        reading.withLock { $0 = false }
        finish(value)
      }
      // A timer, not a task: it fires even when every worker thread is busy.
      let seconds = Double(bound.components.seconds) + Double(bound.components.attoseconds) / 1e18
      DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + seconds) {
        finish(.unknown)
      }
    }
  }
}
