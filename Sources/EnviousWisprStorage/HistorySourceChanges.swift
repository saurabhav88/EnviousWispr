import os
import Foundation

/// In-process publication fence for canonical History writers. No I/O or catalog ownership.
package final class HistorySourceChanges: Sendable {
  package enum Scope: Hashable, Sendable {
    case transcript(UUID)
    case meeting(UUID)
    case all
  }

  package enum Change: Sendable {
    case admitted
    case settled(Scope)
  }

  private struct State {
    var revision: UInt64 = 0
    var active = 0
  }

  private let state = OSAllocatedUnfairLock(initialState: State())
  private let continuation: AsyncStream<Change>.Continuation
  package let changes: AsyncStream<Change>

  package init() {
    (changes, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(64))
  }

  deinit { continuation.finish() }

  package var revision: UInt64? {
    state.withLock { $0.active == 0 ? $0.revision : nil }
  }

  func begin() {
    state.withLock {
      $0.active += 1
      $0.revision &+= 1
    }
    publish(.admitted)
  }

  func finish(_ scope: Scope) {
    state.withLock {
      $0.active -= 1
      $0.revision &+= 1
    }
    publish(.settled(scope))
  }

  private func publish(_ change: Change) {
    if case .dropped = continuation.yield(change) {
      // A dropped notification makes its exact scope unknown.
      continuation.yield(.settled(.all))
    }
  }
}
