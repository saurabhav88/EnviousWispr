import EnviousWisprCore
import Foundation

/// #3546 §3.7 T3: the single owner of the crash-report model tags. Each engine's load
/// owner (Parakeet: `ASRManager`; Whisper: `TranscribeCppWhisperBackend`) reports a snapshot of
/// what it was asked to load, its load phase and what it serves now, with its own
/// increasing sequence number. A snapshot older than one already seen for that engine is
/// dropped, so a late report from a superseded load cannot overwrite a newer one; only the
/// ACTIVE engine's latest snapshot reaches the Sentry scope.
@MainActor
package final class ASRModelScopeOwner {
  package enum Phase: String, Sendable, Equatable {
    case loading
    case loaded
    case failed
    case cancelled
  }

  package struct Snapshot: Sendable, Equatable {
    package let requested: ASRModelIdentity?
    package let phase: Phase?
    package let serving: ASRModelIdentity?

    package init(requested: ASRModelIdentity?, phase: Phase?, serving: ASRModelIdentity?) {
      self.requested = requested
      self.phase = phase
      self.serving = serving
    }

    static let empty = Snapshot(requested: nil, phase: nil, serving: nil)
  }

  package static let shared = ASRModelScopeOwner(sink: SentryBreadcrumb.updateASRModelScope)

  private var active: ASRBackendType = .parakeet
  private var latest: [ASRBackendType: UInt64] = [:]
  private var snapshots: [ASRBackendType: Snapshot] = [:]
  private let sink: @MainActor (Snapshot) -> Void

  package init(sink: @escaping @MainActor (Snapshot) -> Void) {
    self.sink = sink
  }

  /// One engine's snapshot. `sequence` must be read with the snapshot, before any await.
  package func observe(_ backend: ASRBackendType, sequence: UInt64, snapshot: Snapshot) {
    guard sequence > latest[backend, default: 0] else { return }
    latest[backend] = sequence
    snapshots[backend] = snapshot
    if backend == active { sink(snapshot) }
  }

  /// The active engine changed: its own latest snapshot (or no tags) replaces the old one.
  package func activate(_ backend: ASRBackendType) {
    active = backend
    sink(snapshots[backend] ?? .empty)
  }
}
