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
    case unknown
  }

  package struct Delta: Sendable {
    package private(set) var scopes: Set<Scope> = []
    private var revisions: Set<UInt64> = []

    package init() {}

    package mutating func include(_ change: Change) {
      switch change {
      case .admitted(let revision):
        revisions.insert(revision)
      case .settled(let revision, let scope):
        revisions.insert(revision)
        scopes.insert(scope)
      case .unknown:
        scopes.insert(.all)
      }
    }

    func spans(after first: UInt64, through last: UInt64) -> Bool {
      guard !scopes.contains(.all), first <= last else { return false }
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

  /// A change without a reliable writer interval cannot keep the old full-scope certificate.
  package func externalChange() {
    state.withLock {
      $0.revision &+= 1
      publish(.unknown)
    }
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
