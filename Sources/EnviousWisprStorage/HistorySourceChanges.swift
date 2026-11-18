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
    case admitted(UInt64)
    case settled(UInt64, Scope)
    /// Another process changed this source (#4598). It names what to re-check first, but it
    /// has no writer interval, so it can never certify coverage on its own.
    case external(Scope)
    case unknown
  }

  package struct Delta: Sendable {
    package private(set) var scopes: Set<Scope> = []
    private var revisions: Set<UInt64> = []
    private var external = false

    package init() {}

    package mutating func include(_ change: Change) {
      switch change {
      case .admitted(let revision):
        revisions.insert(revision)
      case .settled(let revision, let scope):
        revisions.insert(revision)
        scopes.insert(scope)
      case .external(let scope):
        external = true
        scopes.insert(scope)
      case .unknown:
        scopes.insert(.all)
      }
    }

    func spans(after first: UInt64, through last: UInt64) -> Bool {
      guard !external, !scopes.contains(.all), first <= last else { return false }
      return UInt64(revisions.count(where: { $0 > first && $0 <= last })) == last - first
    }
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

  /// One atomic read of the counter and whether any writer is open. Every `finish` advances
  /// `revision` before a stable value is exposed, so a revision sampled while unsettled never
  /// equals a later `revision` (the stable source).
  package var admission: (revision: UInt64, settled: Bool) {
    state.withLock { ($0.revision, $0.active == 0) }
  }

  /// A change without a reliable writer interval cannot keep the old full-scope certificate.
  /// A named scope is re-checked first; `.all` (the default) means precision was lost.
  package func externalChange(_ scope: Scope = .all) {
    state.withLock {
      $0.revision &+= 1
      publish(scope == .all ? .unknown : .external(scope))
    }
  }

  /// Advance the source revision without a notification (#4598): the caller enqueues the full
  /// re-check itself, so no certificate taken before this point can be presented as current.
  package func advanceWithoutNotice() {
    state.withLock { $0.revision &+= 1 }
  }

  func begin() {
    state.withLock {
      $0.active += 1
      $0.revision &+= 1
      publish(.admitted($0.revision))
    }
  }

  func finish(_ scope: Scope) {
    state.withLock {
      $0.active -= 1
      $0.revision &+= 1
      publish(.settled($0.revision, scope))
    }
  }

  private func publish(_ change: Change) {
    if case .dropped = continuation.yield(change) {
      // A dropped notification makes its exact scope unknown.
      continuation.yield(.unknown)
    }
  }
}
