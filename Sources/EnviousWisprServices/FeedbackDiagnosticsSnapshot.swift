import Foundation

/// The one file a feedback report carries when the user ticks "Include diagnostics" (#3269): the
/// diagnostics diary and, when saved, the PostHog anonymous id that links it to earlier usage
/// reports. Built once; the form previews these exact bytes and the report attaches the same
/// bytes, so what the user reads is what is sent.
public struct FeedbackDiagnosticsSnapshot: Equatable, Sendable {
  public static let filename = "enviouswispr-diagnostics.json"
  public static let contentType = "application/json"

  /// The UTF-8 JSON file: `schema_version`, `diary`, and `analytics_distinct_id` when known.
  public let data: Data

  /// The file as text, for the preview.
  public var text: String { String(decoding: data, as: UTF8.self) }

  private struct File: Encodable {
    let schemaVersion = 1
    let diary: DiagnosticsDiary.Document
    let analyticsDistinctID: String?

    enum CodingKeys: String, CodingKey {
      case schemaVersion = "schema_version"
      case diary
      case analyticsDistinctID = "analytics_distinct_id"
    }
  }

  /// Nil when the diary snapshot is missing, unreadable or empty: a report never carries an
  /// id-only file. The diary is re-validated on the way in, and the id must be canonical.
  static func make(diarySnapshot: Data?, joinKey: String?) -> FeedbackDiagnosticsSnapshot? {
    guard let diarySnapshot, let entries = DiagnosticsDiary.decode(diarySnapshot),
      !entries.isEmpty
    else { return nil }
    let file = File(
      diary: DiagnosticsDiary.Document(
        schemaVersion: DiagnosticsDiary.schemaVersion,
        entries: DiagnosticsDiary.ordered(entries)),
      analyticsDistinctID: joinKey.flatMap(ObservabilityBootstrap.canonicalAnonymousPostHogID))
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    guard let data = try? encoder.encode(file) else { return nil }
    return FeedbackDiagnosticsSnapshot(data: data)
  }

  /// A fresh snapshot for the feedback form: this launch's diary plus the saved join key. Never
  /// starts PostHog and reads no SDK files.
  @MainActor
  public static func load() async -> FeedbackDiagnosticsSnapshot? {
    let diary = await TelemetryService.shared.diagnosticsSnapshot()
    return make(diarySnapshot: diary, joinKey: ObservabilityBootstrap.savedPostHogID())
  }
}
