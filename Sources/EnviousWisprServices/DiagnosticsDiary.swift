import EnviousWisprCore
import Foundation

/// One content-free value kept in the diagnostics diary: the scalar types the dictation telemetry
/// rows carry. Encoded as the bare JSON scalar.
enum DiagnosticsScalar: Codable, Equatable, Sendable {
  case string(String)
  case int(Int)
  case double(Double)
  case bool(Bool)

  /// The scalar for a telemetry property value, or nil for any other type (arrays, dictionaries,
  /// non-finite numbers). `Bool` is matched first and only for a real `Bool`, so a count never
  /// reads as a flag.
  init?(propertyValue value: Any) {
    switch value {
    case let bool as Bool: self = .bool(bool)
    case let int as Int: self = .int(int)
    case let double as Double:
      guard double.isFinite else { return nil }
      self = .double(double)
    case let string as String: self = .string(string)
    default: return nil
    }
  }

  var propertyValue: Any {
    switch self {
    case .string(let value): value
    case .int(let value): value
    case .double(let value): value
    case .bool(let value): value
    }
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    if let bool = try? container.decode(Bool.self) {
      self = .bool(bool)
    } else if let int = try? container.decode(Int.self) {
      self = .int(int)
    } else if let double = try? container.decode(Double.self) {
      self = .double(double)
    } else {
      self = .string(try container.decode(String.self))
    }
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .string(let value): try container.encode(value)
    case .int(let value): try container.encode(value)
    case .double(let value): try container.encode(value)
    case .bool(let value): try container.encode(value)
    }
  }
}

/// A private, local record of the last 20 dictations (#3269), so a user who opts out of usage
/// metrics can still hand the founder something to troubleshoot with, by choice, in one feedback
/// report. Each entry merges one take's `dictation.terminal` and `dictation.completed` rows,
/// reduced to an explicit allowlist of content-free fields after the same redaction PostHog
/// properties get. It records whatever the privacy switches say, and nothing here leaves the Mac:
/// only a user-ticked feedback report attaches a snapshot (chunk 5).
///
/// All state and disk work runs on one serial queue, so callers on the main actor never touch the
/// disk and a snapshot always includes every record enqueued before it. Every failure is silent
/// and local: the diary is a limb and must never throw into dictation.
final class DiagnosticsDiary: @unchecked Sendable {

  /// Which telemetry row an event came from. The two keep separate objects in an entry because
  /// shared field names (`result`, the transports) mean different things on each row.
  enum Source: Sendable {
    case terminal, completed
  }

  /// One projected row, ready to merge: built on the caller's actor, merged on the queue.
  struct Event: Sendable, Equatable {
    let source: Source
    let takeID: String
    let fields: [String: DiagnosticsScalar]
  }

  struct Entry: Codable, Equatable, Sendable {
    var takeID: String
    var firstObservedAt: Date
    var terminal: [String: DiagnosticsScalar]?
    var completed: [String: DiagnosticsScalar]?

    enum CodingKeys: String, CodingKey {
      case takeID = "take_id"
      case firstObservedAt = "first_observed_at"
      case terminal, completed
    }
  }

  struct Document: Codable, Equatable {
    var schemaVersion: Int
    var entries: [Entry]

    enum CodingKeys: String, CodingKey {
      case schemaVersion = "schema_version"
      case entries
    }
  }

  static let schemaVersion = 1
  static let maxEntries = 20
  static let maxAge: TimeInterval = 7 * 24 * 60 * 60
  static let fileName = "diary.json"

  /// Fields kept from both rows, each copied from the identically named property.
  static let sharedFields: Set<String> = [
    "result", "selected_transport", "effective_transport", "input_selection_mode",
    "capture_native_rate_hz", "capture_native_channel_count", "capture_input_channel",
  ]

  /// Fields kept only from `dictation.terminal`.
  static let terminalFields: Set<String> = sharedFields.union([
    "backend", "reason", "delivery_disposition", "input_device_kind", "whole_buffer_rms",
    "max_window_rms", "peak_audio_level", "duration_ms", "vad_raw_sample_count",
    "vad_filtered_sample_count", "vad_retained_ratio", "vad_conditioning_reason",
    "vad_stage_reached", "vad_backend", "vad_input_route", "vad_ready", "vad_model_reused",
    "vad_monitor_to_first_chunk_ms", "vad_first_chunk_latency_ms", "vad_first_chunk_should_stop",
  ])

  /// Fields kept only from `dictation.completed`.
  static let completedFields: Set<String> = sharedFields.union([
    "input_mode", "asr_backend", "llm_provider", "filler_removal", "target_app", "paste_result",
    "e2e_seconds", "asr_seconds", "llm_seconds", "paste_latency_ms", "recording_seconds",
    "stop_reason", "interrupted_by", "asr_salvage_outcome", "asr_retry_outcome",
    "history_save_status", "history_save_error_class", "route_reason", "route_fallback_reason",
    "output_transport", "route_resolution_source", "input_resolution_source",
    "capture_ring_drop_count", "capture_converter_error_count", "capture_zero_output_count",
    "capture_rate_divergence_detected", "capture_format_stabilized", "capture_rebuilt_for_format",
    "salvaged_lead_trim_ms",
  ])

  /// The diary file for this build: `<StorageRoot.standardDirectory>/Diagnostics/<bundle id>/`.
  static var productionDirectory: URL {
    StorageRoot.standardDirectory
      .appendingPathComponent("Diagnostics", isDirectory: true)
      .appendingPathComponent(
        Bundle.main.bundleIdentifier ?? "com.enviouswispr.app", isDirectory: true)
  }

  /// Reduces one telemetry row to a diary event: redaction first, then the row's allowlist and
  /// scalar check. Nil when the row has no hyphenated-UUID `take_id`, so a take is never merged
  /// into another. Pure, so it runs on the caller's actor before the hop to the queue.
  static func event(source: Source, properties: [String: Any]) -> Event? {
    let sanitized = ObservabilityBootstrap.sanitizePostHogProperties(properties)
    guard let takeID = sanitized["take_id"] as? String, isHyphenatedUUID(takeID) else {
      return nil
    }
    return Event(source: source, takeID: takeID, fields: project(source: source, sanitized))
  }

  static func project(source: Source, _ properties: [String: Any]) -> [String: DiagnosticsScalar] {
    let allowed = source == .terminal ? terminalFields : completedFields
    var fields: [String: DiagnosticsScalar] = [:]
    for (key, value) in properties where allowed.contains(key) {
      if let scalar = DiagnosticsScalar(propertyValue: value), accepts(scalar, for: key) {
        fields[key] = scalar
      }
    }
    return fields
  }

  /// The value type each allowed field carries on its telemetry row. A value of any other type is
  /// dropped, so a string can never ride in a numeric or flag field. Numbers accept an integral
  /// value too: JSON stores `2.0` as `2`, and `capture_native_rate_hz` is an Int on one row and a
  /// Double on the other.
  private static func accepts(_ value: DiagnosticsScalar, for key: String) -> Bool {
    switch key {
    case "vad_ready", "vad_model_reused", "vad_first_chunk_should_stop",
      "filler_removal", "capture_rate_divergence_detected",
      "capture_format_stabilized", "capture_rebuilt_for_format":
      if case .bool = value { return true }
    case "capture_native_channel_count", "capture_input_channel", "duration_ms",
      "vad_raw_sample_count", "vad_filtered_sample_count", "paste_latency_ms",
      "capture_ring_drop_count", "capture_converter_error_count",
      "capture_zero_output_count", "salvaged_lead_trim_ms":
      if case .int = value { return true }
    case "capture_native_rate_hz", "whole_buffer_rms", "max_window_rms",
      "peak_audio_level", "vad_retained_ratio", "vad_monitor_to_first_chunk_ms",
      "vad_first_chunk_latency_ms", "e2e_seconds", "asr_seconds",
      "llm_seconds", "recording_seconds":
      switch value {
      case .int: return true
      case .double(let number): return number.isFinite
      default: return false
      }
    default:
      if case .string = value { return true }
    }
    return false
  }

  static func isHyphenatedUUID(_ raw: String) -> Bool {
    guard let uuid = UUID(uuidString: raw) else { return false }
    return raw == uuid.uuidString || raw == uuid.uuidString.lowercased()
  }

  private let directory: URL
  private let fileURL: URL
  private let now: @Sendable () -> Date
  private let writeData: @Sendable (Data, URL) throws -> Void
  private let queue = DispatchQueue(label: "com.enviouswispr.diagnostics-diary", qos: .utility)

  // Queue-confined state.
  private var entries: [Entry] = []
  private var isLoaded = false
  /// True after an unreadable or unsupported file, until a write replaces it.
  private var isUnavailable = false

  /// - Parameters:
  ///   - writeData: test seam for a failing write. Production always passes the durable writer,
  ///     which creates a unique 0600 temp file, syncs it and renames it into place.
  init(
    directory: URL,
    now: @escaping @Sendable () -> Date = { Date() },
    writeData: @escaping @Sendable (Data, URL) throws -> Void = { data, url in
      try DurableJSONFile.write(data: data, to: url, tempPrefix: ".diary")
    }
  ) {
    self.directory = directory
    self.fileURL = directory.appendingPathComponent(Self.fileName)
    self.now = now
    self.writeData = writeData
  }

  static func production() -> DiagnosticsDiary {
    DiagnosticsDiary(directory: productionDirectory)
  }

  /// Launch work: load the file and prune it on the queue, whatever the privacy switches say.
  func activate() {
    queue.async { self.pruneAndPersist() }
  }

  /// The observation time is read here, on the caller's actor, so a take is stamped when its row
  /// was emitted rather than when the queue gets to it.
  func record(_ event: Event) {
    let observedAt = now()
    queue.async { self.merge(event, observedAt: observedAt) }
  }

  /// Test seam: returns once every operation enqueued before it has run. Loads and prunes nothing
  /// itself, so a test can observe what a write or `activate` left on disk.
  func waitForPendingOperations() async {
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      queue.async { continuation.resume() }
    }
  }

  /// The pruned diary as deterministic JSON, or nil when it is empty or unavailable. Runs after
  /// every record enqueued before it.
  func snapshot() async -> Data? {
    await withCheckedContinuation { continuation in
      queue.async { continuation.resume(returning: self.makeSnapshot()) }
    }
  }

  // MARK: - Queue-confined work

  private func loadIfNeeded() {
    guard !isLoaded else { return }
    isLoaded = true
    DurableJSONFile.prepareDirectory(at: directory)
    DurableJSONFile.tightenFileIfPresent(at: fileURL)
    guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
    guard let data = try? Data(contentsOf: fileURL), let decoded = Self.decode(data) else {
      isUnavailable = true
      return
    }
    entries = decoded
  }

  private func merge(_ event: Event, observedAt: Date) {
    loadIfNeeded()
    var next = entries
    if let index = next.firstIndex(where: { $0.takeID == event.takeID }) {
      switch event.source {
      case .terminal: next[index].terminal = event.fields
      case .completed: next[index].completed = event.fields
      }
    } else {
      next.append(
        Entry(
          takeID: event.takeID, firstObservedAt: observedAt,
          terminal: event.source == .terminal ? event.fields : nil,
          completed: event.source == .completed ? event.fields : nil))
    }
    next = Self.pruned(next, now: now())
    if persist(next) {
      entries = next
      isUnavailable = false
    }
  }

  @discardableResult
  private func pruneAndPersist() -> Bool {
    loadIfNeeded()
    guard !isUnavailable else { return false }
    let next = Self.pruned(entries, now: now())
    guard next != entries else { return true }
    guard persist(next) else { return false }
    entries = next
    return true
  }

  private func makeSnapshot() -> Data? {
    guard pruneAndPersist(), !entries.isEmpty else { return nil }
    return try? Self.encode(entries)
  }

  private func persist(_ next: [Entry]) -> Bool {
    guard let data = try? Self.encode(next) else { return false }
    do {
      try writeData(data, fileURL)
      return true
    } catch {
      return false
    }
  }

  // MARK: - Pure helpers

  /// Drops entries first seen more than seven days ago, then keeps the 20 newest, newest first
  /// (ties broken by take id so the order is deterministic).
  static func pruned(_ entries: [Entry], now: Date) -> [Entry] {
    let cutoff = now.addingTimeInterval(-maxAge)
    let fresh = entries.filter { $0.firstObservedAt >= cutoff }
    let sorted = fresh.sorted {
      $0.firstObservedAt != $1.firstObservedAt
        ? $0.firstObservedAt > $1.firstObservedAt : $0.takeID < $1.takeID
    }
    return Array(sorted.prefix(maxEntries))
  }

  static func encode(_ entries: [Entry]) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    return try encoder.encode(Document(schemaVersion: schemaVersion, entries: entries))
  }

  /// Decodes a stored file, then re-validates every entry the same way a new row is checked, so a
  /// hand-edited or damaged file cannot carry an extra field or an unredacted value into a
  /// snapshot. Nil for unreadable JSON or an unsupported schema version.
  static func decode(_ data: Data) -> [Entry]? {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    guard let document = try? decoder.decode(Document.self, from: data),
      document.schemaVersion == schemaVersion
    else { return nil }
    var byTake: [String: Entry] = [:]
    for entry in document.entries where isHyphenatedUUID(entry.takeID) {
      guard byTake[entry.takeID] == nil else { continue }
      byTake[entry.takeID] = Entry(
        takeID: entry.takeID, firstObservedAt: entry.firstObservedAt,
        terminal: entry.terminal.map { revalidate($0, source: .terminal) },
        completed: entry.completed.map { revalidate($0, source: .completed) })
    }
    return Array(byTake.values)
  }

  private static func revalidate(
    _ fields: [String: DiagnosticsScalar], source: Source
  ) -> [String: DiagnosticsScalar] {
    let sanitized = ObservabilityBootstrap.sanitizePostHogProperties(
      fields.mapValues(\.propertyValue))
    return project(source: source, sanitized)
  }
}
