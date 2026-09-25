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
  /// #1413: what the other-audio hold did for this take, written at its restore.
  var otherAudio: OtherAudioTerminalFacts?
  /// #3111: which instruction EG-1's named-language prompt family selected for this take
  /// (`named`, `english`, `unsure`, `conflict`, `untested`, `mixed`, `scanLimit`). Written once the prompt is
  /// PLANNED, before the model is asked, so it says what was chosen, never whether polish
  /// succeeded or what language was delivered. Absent for every other provider and family.
  var polishLanguageHint: String?

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
    if let otherAudio { out.merge(otherAudio.terminalProperties) { current, _ in current } }
    if let polishLanguageHint { out["polish_language_hint"] = polishLanguageHint }
    return out
  }
}

/// #1413. The other-audio facts that ride on `dictation.terminal`: zero new rows,
/// a handful of closed-vocabulary properties on a row already paid for, and only
/// for takes whose mode was not `nothing`. A timing whose operation did not run
/// is nil and stays absent on the wire.
public struct OtherAudioTerminalFacts: Equatable, Sendable {
  public var mode: String
  public var volume: String
  public var mute: String
  public var media: String
  public var outputTransport: String?
  public var applyMicros: Int?
  public var restoreMicros: Int?
  public var recordMicros: Int?
  public var failure: String?
  /// v1.1: `adapter` / `scripted` / `none`, which media route answered the
  /// pause, and the adapter's bounded failure class (`load`, `timeout`, `exit`,
  /// `parse`, `send`) when it was tried and failed. The fleet-wide "did an OS
  /// update turn the adapter off" question is answered here, never by Sentry.
  public var mediaRoute: String?
  public var adapterFailure: String?

  public init(
    mode: String, volume: String, mute: String, media: String, outputTransport: String? = nil,
    applyMicros: Int? = nil, restoreMicros: Int? = nil, recordMicros: Int? = nil,
    failure: String? = nil, mediaRoute: String? = nil, adapterFailure: String? = nil
  ) {
    self.mode = mode
    self.volume = volume
    self.mute = mute
    self.media = media
    self.outputTransport = outputTransport
    self.applyMicros = applyMicros
    self.restoreMicros = restoreMicros
    self.recordMicros = recordMicros
    self.failure = failure
    self.mediaRoute = mediaRoute
    self.adapterFailure = adapterFailure
  }

  var terminalProperties: [String: Any] {
    var out: [String: Any] = [
      "other_audio_mode": mode, "other_audio_volume": volume, "other_audio_mute": mute,
      "other_audio_media": media,
    ]
    if let outputTransport { out["other_audio_output_transport"] = outputTransport }
    if let applyMicros { out["other_audio_apply_us"] = applyMicros }
    if let restoreMicros { out["other_audio_restore_us"] = restoreMicros }
    if let recordMicros { out["other_audio_record_us"] = recordMicros }
    if let failure { out["other_audio_failure"] = failure }
    if let mediaRoute { out["other_audio_media_route"] = mediaRoute }
    if let adapterFailure { out["other_audio_adapter_failure"] = adapterFailure }
    return out
  }
}

/// In-memory, per-take, bounded. Opened at `dictation.started` (the acceptance seam),
/// written by the three VAD marker calls and by optional per-take facts (the other-audio
/// hold, #1413; EG-1's prompt selection, #3111), consumed once by `dictation.terminal`.
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

  /// #1413: mutates the MOST RECENTLY OPENED entry and returns its take id, or nil
  /// when nothing is open. The other-audio hold has no take id of its own (no
  /// existing handoff carries one to the coordinator), and exactly one take is in
  /// flight when its restore runs, so the newest open entry is that take.
  @discardableResult
  func updateNewest(_ mutate: (inout TakeStageSummary) -> Void) -> String? {
    lock.withLock {
      guard let takeID = order.last, var entry = entries[takeID] else { return nil }
      mutate(&entry)
      entries[takeID] = entry
      return takeID
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
