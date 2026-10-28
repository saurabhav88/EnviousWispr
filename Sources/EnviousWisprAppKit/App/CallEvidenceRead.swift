import ApplicationServices
import EnviousWisprServices
import Foundation
import os

/// One evidence read for the call watcher, off the main actor and bounded (#4012 §3.3): the
/// Accessibility walk blocks its thread, so it runs on its own serial queue (never the shared
/// Swift worker pool), and the caller waits at most one second; a read that does not finish in
/// time has no independent call proof. Trusted Teams retain microphone-only Ask evidence;
/// other unavailable reads are `.unknown`, never "no call". Only one read runs at a time:
/// while an abandoned read is stuck, later reads answer at once without piling up behind it.
enum CallEvidenceRead {
  /// Where reads run, and whether one is still running. The app shares one; a test makes its own.
  final class Lane: Sendable {
    let queue = DispatchQueue(label: "com.enviouswispr.call-evidence", qos: .userInitiated)
    let reading = OSAllocatedUnfairLock(initialState: false)
    static let shared = Lane()
  }

  static func boundedSnapshot(
    rule: CallAppCatalog.Rule, pid: Int32, retained: CallEvidenceReader.RetainedTarget? = nil,
    bound: Duration = .seconds(1), lane: Lane = .shared,
    isTrusted: @escaping @Sendable () -> Bool = { AXIsProcessTrusted() },
    read: (@Sendable (CallAppCatalog.Rule, Int32) -> CallEvidenceReader.Snapshot)? = nil
  ) async -> CallEvidenceReader.Snapshot {
    let operation: @Sendable (CallAppCatalog.Rule, Int32) -> CallEvidenceReader.Snapshot = read ?? { rule, pid in
      if let retained {
        guard retained.rule == rule, retained.holderPID == pid else { return .init(startEvidence: .unknown) }
        return CallEvidenceReader.snapshot(for: retained)
      }
      return CallEvidenceReader.snapshot(for: rule, holderPID: pid)
    }
    // The inner scan can lose to this outer timer (#4094). Preserve Ask without granting
    // automatic proof, and check trust at fallback time rather than before the scan.
    let unavailable: @Sendable () -> CallEvidenceReader.Snapshot = {
      guard retained == nil else { return .init(startEvidence: .unknown) }
      guard case .callApp(.teams) = rule, isTrusted() else { return .init(startEvidence: .unknown) }
      return .init(startEvidence: .microphoneOnly(family: .teams, room: "pid-\(pid)"))
    }
    let reading = lane.reading
    let claimed = reading.withLock { busy -> Bool in
      if busy { return false }
      busy = true
      return true
    }
    guard claimed else { return unavailable() }
    return await withCheckedContinuation {
      (continuation: CheckedContinuation<CallEvidenceReader.Snapshot, Never>) in
      let resumed = OSAllocatedUnfairLock(initialState: false)
      let finish: @Sendable (CallEvidenceReader.Snapshot) -> Void = { value in
        let first = resumed.withLock { done -> Bool in
          if done { return false }
          done = true
          return true
        }
        if first {
          let result = retained == nil ? value
            : .init(startEvidence: .unknown, continuity: value.continuity, owner: value.owner)
          continuation.resume(returning: result)
        }
      }
      lane.queue.async {
        let value = operation(rule, pid)
        reading.withLock { $0 = false }
        finish(value)
      }
      // A timer, not a task: it fires even when every worker thread is busy.
      let seconds = Double(bound.components.seconds) + Double(bound.components.attoseconds) / 1e18
      DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + seconds) {
        finish(unavailable())
      }
    }
  }
}
