import Darwin
import Foundation
import SwiftUI

/// Optional, per-instance measurement sink. Nil in ordinary app composition. Events carry
/// identity/counts only; they are not logs, analytics, word text or proof that pixels drew.
package struct CustomWordsProbe: Sendable {
  package enum Event: Sendable, Equatable {
    case editRequested(wordID: UUID)
    case projectionStarted(revision: Int)
    case projectionFinished(revision: Int, rowCount: Int)
    /// A dictionary command joined the coordinator's queue (#4086). Every later event of
    /// that command carries the same `command` number.
    case admitted(command: Int, operation: Operation)
    case storageStarted(command: Int, operation: Operation)
    /// The file worker finished the command's whole locked transaction.
    case storageReturned(command: Int, operation: Operation, outcome: Outcome)
    case published(command: Int, operation: Operation)
    /// The command's receipt completed: storage, adoption, publication and any learning
    /// memory effect are all done, and the next command may start.
    case completed(command: Int, operation: Operation)
  }

  package enum Operation: Sendable, Equatable {
    case add, addBatch, update, generatedAliases, remove, removeBatch
    case restoreBuiltin, removeOverride, redeleteBuiltin
    case importCommit, enrichmentRepair, enrichmentRead, enrichmentApply, enrichmentCancel
    case refresh, action, usageFlush
  }

  /// `committed`: the durable write finished. `unchanged`: the transaction returned
  /// normally and wrote nothing. `failed`: it threw, and nothing was written.
  package enum Outcome: Sendable, Equatable { case committed, unchanged, failed }

  package let record: @Sendable (Event, UInt64) -> Void

  package init(record: @escaping @Sendable (Event, UInt64) -> Void) { self.record = record }

  package func emit(_ event: Event) {
    record(event, clock_gettime_nsec_np(CLOCK_UPTIME_RAW))
  }
}

private struct CustomWordsProbeKey: EnvironmentKey {
  static let defaultValue: CustomWordsProbe? = nil
}

extension EnvironmentValues {
  package var customWordsProbe: CustomWordsProbe? {
    get { self[CustomWordsProbeKey.self] }
    set { self[CustomWordsProbeKey.self] = newValue }
  }
}

/// Non-observed reference state: counting a body calculation must not publish SwiftUI state
/// from inside that calculation and trigger another render. One counter per view lifetime.
@MainActor
final class CustomWordsProjectionProbeCounter {
  private var revision = 0
  func next() -> Int { revision += 1; return revision }
}
