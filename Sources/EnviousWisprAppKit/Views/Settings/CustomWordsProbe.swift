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
    case storageStarted(operation: Operation)
    case storageReturned(operation: Operation, outcome: Outcome)
    case published(operation: Operation)
  }

  package enum Operation: Sendable, Equatable { case add, update, remove, removeBatch, other(String) }

  /// A normal manager return may be a no-op (for example a deleted edit target).
  /// `returned` deliberately makes no claim that a durable write actually happened.
  package enum Outcome: Sendable, Equatable { case returned, failed }

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
