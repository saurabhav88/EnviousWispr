import EnviousWisprCore
import Foundation
import os

/// #3849: the quit release's last-resort record. When a transcribe.cpp native call does not
/// return within the quit bound, the app ends at once (`_exit`); a Sentry capture made just
/// before that is usually lost, because the SDK stores envelopes asynchronously. So the quit
/// path writes this small, content-free note synchronously, and the next launch reports it.
///
/// Content-free by construction: the payload is these six typed fields and nothing else.
public struct ModelReleaseTimeoutNote: Codable, Sendable, Equatable {
  public let bundleIdentifier: String
  public let environment: String
  public let appVersion: String
  public let timestamp: Date
  /// Sessions alive when the release began; nil when the quit path could not observe it (a
  /// release that had already started elsewhere).
  public let sessions: Int?
  public let boundMs: Int

  public init(
    bundleIdentifier: String, environment: String, appVersion: String, timestamp: Date,
    sessions: Int?, boundMs: Int
  ) {
    self.bundleIdentifier = bundleIdentifier
    self.environment = environment
    self.appVersion = appVersion
    self.timestamp = timestamp
    self.sessions = sessions
    self.boundMs = boundMs
  }

  /// This build's identity, stamped now.
  public static func current(sessions: Int?, boundMs: Int) -> ModelReleaseTimeoutNote {
    ModelReleaseTimeoutNote(
      bundleIdentifier: Bundle.main.bundleIdentifier ?? "com.enviouswispr.app",
      environment: ObservabilityBootstrap.currentEnvironment,
      appVersion: ObservabilityBootstrap.appVersion, timestamp: Date(), sessions: sessions,
      boundMs: boundMs)
  }

  static let fileName = "model-release-timeout.json"

  /// This build's namespace (`<data dir>/Diagnostics/<bundle id>/`, the diary's folder), so a
  /// dev build never reads a production note, or the reverse.
  public static var productionDirectory: URL { DiagnosticsDiary.productionDirectory }

  // MARK: - Write (quit path)

  /// Writes the note synchronously and atomically. The quit path calls this from
  /// `applicationWillTerminate` immediately before `_exit`, so nothing here may suspend.
  public static func write(_ note: ModelReleaseTimeoutNote, to directory: URL) throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let data = try encoder.encode(note)
    try data.write(to: directory.appendingPathComponent(fileName), options: .atomic)
  }

  // MARK: - Consume (next launch)

  /// What one launch did with the note.
  public enum Consumed: Equatable, Sendable {
    /// No note: nothing was read, written or sent.
    case none
    /// A valid note, removed, then handed to the reporter.
    case reported(ModelReleaseTimeoutNote)
    /// A valid note, removed, not reported because crash reports are off.
    case removedCrashReportsOff
    /// A note that could not be read or decoded, removed, not reported.
    case removedUnusable
    /// The note could not be removed; not reported, so a later launch cannot report it twice.
    case removalFailed
  }

  /// The launch reader: consumes this build's note, if any. The file is removed before any
  /// report, and a note that cannot be removed is never reported, so one note is reported at
  /// most once. Delivery after that is best effort.
  @discardableResult
  public static func consume(
    in directory: URL, crashReportsEnabled: Bool,
    report: (ModelReleaseTimeoutNote) -> Void
  ) -> Consumed {
    let url = directory.appendingPathComponent(fileName)
    let manager = FileManager.default
    guard manager.fileExists(atPath: url.path) else { return .none }
    let note = (try? Data(contentsOf: url)).flatMap { try? decoder.decode(Self.self, from: $0) }
    do {
      try manager.removeItem(at: url)
    } catch {
      logger.error(
        "model release timeout note: removal failed code=\((error as NSError).code, privacy: .public)"
      )
      return .removalFailed
    }
    guard let note else { return .removedUnusable }
    guard crashReportsEnabled else { return .removedCrashReportsOff }
    report(note)
    return .reported(note)
  }

  /// Production launch step, run immediately after `ObservabilityBootstrap.initialize`.
  @MainActor
  public static func consumeAtLaunch(crashReportsEnabled: Bool) {
    consume(
      in: productionDirectory, crashReportsEnabled: crashReportsEnabled,
      report: SentryBreadcrumb.captureModelReleaseTimeout)
  }

  // MARK: - Coding

  private static var encoder: JSONEncoder {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = .sortedKeys
    return encoder
  }

  private static var decoder: JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
  }

  private static let logger = Logger(subsystem: "com.enviouswispr.app", category: "TranscribeCpp")
}
