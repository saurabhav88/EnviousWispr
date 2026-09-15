import Foundation

/// #2958. What the three record-start VAD boundaries (#1780) observed for ONE take,
/// carried on that take's `dictation.terminal` row instead of three PostHog rows of
/// their own. The Sentry breadcrumb twins are unchanged; only the PostHog side folds.
///
/// Every field is omit-when-nil on the wire: a boundary the take never reached has no
/// value, and `stageReached` says which boundary was the last one seen.
struct TakeStageSummary: Equatable {
  /// The furthest record-start boundary this take reported, in pipeline order.
  enum Stage: String, Comparable {
    case none
    case prepared
    case firstChunkStarted = "first_chunk_started"
    case firstChunkCompleted = "first_chunk_completed"

    private var order: Int {
      switch self {
      case .none: return 0
      case .prepared: return 1
      case .firstChunkStarted: return 2
      case .firstChunkCompleted: return 3
      }
    }

    static func < (lhs: Stage, rhs: Stage) -> Bool { lhs.order < rhs.order }
  }

  var stageReached: Stage = .none
  var backend: String?
  var inputRoute: String?
  var ready: Bool?
  var modelReused: Bool?
  var monitorToFirstChunkMs: Double?
  var firstChunkLatencyMs: Double?
  var firstChunkShouldStop: Bool?

  /// The terminal-row projection. Keys are prefixed `vad_` beside the #2184 conditioning
  /// fields that already live on the same row; `vad_stage_reached` is always present when
  /// a summary exists, the rest omit when the boundary was never reached.
  var terminalProperties: [String: Any] {
    var out: [String: Any] = ["vad_stage_reached": stageReached.rawValue]
    if let backend { out["vad_backend"] = backend }
    if let inputRoute { out["vad_input_route"] = inputRoute }
    if let ready { out["vad_ready"] = ready }
    if let modelReused { out["vad_model_reused"] = modelReused }
    if let monitorToFirstChunkMs { out["vad_monitor_to_first_chunk_ms"] = monitorToFirstChunkMs }
    if let firstChunkLatencyMs { out["vad_first_chunk_latency_ms"] = firstChunkLatencyMs }
    if let firstChunkShouldStop { out["vad_first_chunk_should_stop"] = firstChunkShouldStop }
    return out
  }
}

/// In-memory, per-take, bounded. Opened at `dictation.started` (the acceptance seam),
/// written by the three VAD marker calls, consumed once by `dictation.terminal`.
///
/// Rules, each of which a test names:
/// - A marker for a take that was never opened, or already closed, writes nothing. A late
///   callback from a torn-down session (which `CaptureVADSignalSource` already fences by
///   generation) therefore cannot resurrect a row.
/// - Takes are independent: take B's markers never touch take A's entry, and A's terminal
///   can render after B was accepted (`KernelLifecycleTelemetrySink.emitTerminal`).
/// - Capacity is bounded; the OLDEST open entry is evicted first. An evicted take renders a
///   terminal with no summary, never a fabricated `none`.
/// - No timers, no persistence, no waits: this is a dictionary behind a lock.
///
/// A lock rather than an actor because the marker calls arrive on `MainActor` while the
/// terminal is rendered from the kernel's telemetry path; neither may suspend on the other
/// (`observability-operations.md` RULE: observability-is-a-limb).
final class TakeStageLedger: @unchecked Sendable {
  static let defaultCapacity = 8

  private let lock = NSLock()
  private var entries: [String: TakeStageSummary] = [:]
  private var order: [String] = []
  private let capacity: Int

  init(capacity: Int = TakeStageLedger.defaultCapacity) {
    self.capacity = max(1, capacity)
  }

  /// Opens (or resets) the entry for an accepted take, evicting the oldest open take when
  /// the bound is exceeded.
  func open(takeID: String) {
    lock.withLock {
      if entries[takeID] == nil {
        order.append(takeID)
      } else {
        order.removeAll { $0 == takeID }
        order.append(takeID)
      }
      entries[takeID] = TakeStageSummary()
      while order.count > capacity, let oldest = order.first {
        order.removeFirst()
        entries[oldest] = nil
      }
    }
  }

  /// Mutates an OPEN entry; returns false when there is none, in which case nothing is
  /// written.
  @discardableResult
  func update(takeID: String, _ mutate: (inout TakeStageSummary) -> Void) -> Bool {
    lock.withLock {
      guard var entry = entries[takeID] else { return false }
      mutate(&entry)
      entries[takeID] = entry
      return true
    }
  }

  /// Removes and returns the entry, or nil when the take was never opened, already
  /// closed, or evicted.
  func close(takeID: String) -> TakeStageSummary? {
    lock.withLock {
      guard let entry = entries.removeValue(forKey: takeID) else { return nil }
      order.removeAll { $0 == takeID }
      return entry
    }
  }

  var openCount: Int { lock.withLock { entries.count } }
}
