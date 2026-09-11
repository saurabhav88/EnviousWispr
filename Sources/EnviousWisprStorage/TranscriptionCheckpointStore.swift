import EnviousWisprCore
import Foundation

/// #2787 — persists the latest `TranscriptionCheckpoint` for the take in
/// flight, so the NEXT launch can report where a take was when this process
/// died. Metadata only (`TranscriptionCheckpoint`); one file; overwritten per
/// stage; deleted on every terminal the app lives to see.
///
/// Why disk and not a Sentry event at quit: a Force Quit is SIGKILL and no
/// code in the dying process runs, so anything worth reporting has to be on
/// disk BEFORE the step that might never return. The write is a few hundred
/// bytes via temp file + rename, at most six times per take.
///
/// `current` is the in-memory mirror for the graceful-quit path
/// (`TelemetryService.FlushContext`), where the process is still alive.
public final class TranscriptionCheckpointStore: @unchecked Sendable {
  public static let fileName = "transcription_checkpoint.json"

  private let fileURL: URL
  private let lock = NSLock()
  private var mirror: TranscriptionCheckpoint?

  /// The production store, in the app's support directory.
  public convenience init() {
    self.init(directory: AppConstants.appSupportURL)
  }

  /// Tests inject a private directory.
  public init(directory: URL) {
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    fileURL = directory.appendingPathComponent(Self.fileName)
  }

  /// The checkpoint most recently written in THIS process, or nil.
  public var current: TranscriptionCheckpoint? {
    lock.withLock { mirror }
  }

  /// Applies one kernel event: `.mark` writes (or overwrites) the checkpoint,
  /// `.clear` removes it. Best-effort: a write failure is logged by the caller
  /// only through the absence of a later report, never surfaced to the user.
  public func apply(_ event: TranscriptionCheckpointEvent, now: Date = Date()) {
    switch event {
    case .mark(let takeID, let backend, let stage, let chunksScheduled):
      let checkpoint = TranscriptionCheckpoint(
        takeID: takeID, backend: backend, stage: stage, stageEnteredAt: now,
        chunksScheduled: chunksScheduled, appVersion: AppConstants.appVersion)
      lock.withLock { mirror = checkpoint }
      write(checkpoint)
    case .clear:
      lock.withLock { mirror = nil }
      try? FileManager.default.removeItem(at: fileURL)
    }
  }

  /// A checkpoint left by a PREVIOUS process, consumed exactly once: the file
  /// is deleted BEFORE the read is returned, so a report can never repeat
  /// across launches. Returns nil when there is none, when deletion fails
  /// (nothing may be reported that could be reported again), or when the file
  /// cannot be decoded (a corrupt or foreign file is deleted too).
  public func takeOrphan() -> TranscriptionCheckpoint? {
    guard let data = try? Data(contentsOf: fileURL) else { return nil }
    // Consume FIRST: a checkpoint whose deletion failed must not be reported,
    // or the same orphan is reported again at every launch until it succeeds.
    do {
      try FileManager.default.removeItem(at: fileURL)
    } catch {
      return nil
    }
    return try? Self.decoder.decode(TranscriptionCheckpoint.self, from: data)
  }

  private func write(_ checkpoint: TranscriptionCheckpoint) {
    guard let data = try? Self.encoder.encode(checkpoint) else { return }
    let tmp = fileURL.appendingPathExtension("tmp-\(UUID().uuidString)")
    do {
      try data.write(to: tmp, options: [.atomic])
      _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: tmp)
    } catch {
      try? FileManager.default.removeItem(at: tmp)
    }
  }

  private static let encoder: JSONEncoder = {
    let e = JSONEncoder()
    e.dateEncodingStrategy = .iso8601
    return e
  }()

  private static let decoder: JSONDecoder = {
    let d = JSONDecoder()
    d.dateDecodingStrategy = .iso8601
    return d
  }()
}
