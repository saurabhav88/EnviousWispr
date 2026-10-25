import Foundation
import Sentry
import Testing

@testable import EnviousWisprASR
@testable import EnviousWisprServices
import EnviousWisprAppKitTestSupport

/// #3849: the quit release's last-resort note and its next-launch report.
///
/// **What a dashboard shows wrong when this fails:** a quit that ended the process because a
/// native call was stuck never reaches Sentry, reaches it twice, reaches it with crash reports
/// off, carries fields beyond the six declared ones, or a dev quit lands in the production issue.
@Suite("Model release timeout note (#3849)", .serialized, .tags(.observabilityContract))
struct ModelReleaseTimeoutNoteTests {

  /// The declared payload, spelled independently of the type under test.
  static let declaredKeys: Set<String> = [
    "bundleIdentifier", "environment", "appVersion", "timestamp", "sessions", "boundMs",
  ]

  static func note(sessions: Int? = 2) -> ModelReleaseTimeoutNote {
    ModelReleaseTimeoutNote(
      bundleIdentifier: "com.enviouswispr.app.dev", environment: "development",
      appVersion: "2.5.4", timestamp: Date(timeIntervalSince1970: 1_800_000_000),
      sessions: sessions, boundMs: 2_000)
  }

  static func directory() -> URL {
    TestTemporaryDirectory.url
      .appendingPathComponent("ew-3849-note-\(UUID().uuidString)", isDirectory: true)
      .appendingPathComponent("com.enviouswispr.app.dev", isDirectory: true)
  }

  static func file(in directory: URL) -> URL {
    directory.appendingPathComponent("model-release-timeout.json")
  }

  /// Every note the reader handed to the reporter.
  final class Reports: @unchecked Sendable {
    private let lock = NSLock()
    private var notes: [ModelReleaseTimeoutNote] = []
    func append(_ note: ModelReleaseTimeoutNote) { lock.withLock { notes.append(note) } }
    var all: [ModelReleaseTimeoutNote] { lock.withLock { notes } }
  }

  @Test("a written note is read back, reported once and removed")
  func roundTripReportsAndDeletes() throws {
    let directory = Self.directory()
    defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
    try ModelReleaseTimeoutNote.write(Self.note(), to: directory)
    let json = try #require(
      try JSONSerialization.jsonObject(with: Data(contentsOf: Self.file(in: directory)))
        as? [String: Any])
    #expect(Set(json.keys) == Self.declaredKeys, "the file holds the declared fields only")
    let reports = Reports()
    let outcome = ModelReleaseTimeoutNote.consume(
      in: directory, crashReportsEnabled: true, report: reports.append)
    #expect(outcome == .reported(Self.note()))
    #expect(reports.all == [Self.note()])
    #expect(!FileManager.default.fileExists(atPath: Self.file(in: directory).path))
  }

  @Test("with crash reports off the note is removed and nothing is reported")
  func crashReportsOffDeletesWithoutReporting() throws {
    let directory = Self.directory()
    defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
    try ModelReleaseTimeoutNote.write(Self.note(), to: directory)
    let reports = Reports()
    let outcome = ModelReleaseTimeoutNote.consume(
      in: directory, crashReportsEnabled: false, report: reports.append)
    #expect(outcome == .removedCrashReportsOff)
    #expect(reports.all.isEmpty)
    #expect(!FileManager.default.fileExists(atPath: Self.file(in: directory).path))
  }

  @Test("a malformed note is removed and never reported")
  func malformedDeletesWithoutReporting() throws {
    let directory = Self.directory()
    defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try Data("{\"sessions\": \"two\"".utf8).write(to: Self.file(in: directory))
    let reports = Reports()
    let outcome = ModelReleaseTimeoutNote.consume(
      in: directory, crashReportsEnabled: true, report: reports.append)
    #expect(outcome == .removedUnusable)
    #expect(reports.all.isEmpty)
    #expect(!FileManager.default.fileExists(atPath: Self.file(in: directory).path))
  }

  @Test("an unreadable note is removed and never reported")
  func unreadableDeletesWithoutReporting() throws {
    let directory = Self.directory()
    defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
    // A folder where the file should be: present, but its bytes cannot be read.
    try FileManager.default.createDirectory(
      at: Self.file(in: directory), withIntermediateDirectories: true)
    let reports = Reports()
    let outcome = ModelReleaseTimeoutNote.consume(
      in: directory, crashReportsEnabled: true, report: reports.append)
    #expect(outcome == .removedUnusable)
    #expect(reports.all.isEmpty)
    #expect(!FileManager.default.fileExists(atPath: Self.file(in: directory).path))
  }

  @Test("a note that cannot be removed is never reported, so no later launch reports it twice")
  func removalFailureNeverReports() throws {
    let directory = Self.directory()
    defer {
      try? FileManager.default.setAttributes(
        [.posixPermissions: 0o755], ofItemAtPath: directory.path)
      try? FileManager.default.removeItem(at: directory.deletingLastPathComponent())
    }
    try ModelReleaseTimeoutNote.write(Self.note(), to: directory)
    try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: directory.path)
    let reports = Reports()
    let outcome = ModelReleaseTimeoutNote.consume(
      in: directory, crashReportsEnabled: true, report: reports.append)
    #expect(outcome == .removalFailed)
    #expect(reports.all.isEmpty)
    #expect(FileManager.default.fileExists(atPath: Self.file(in: directory).path), "control")
  }

  @Test("no note is a quiet no-op")
  func missingNoteIsNoOp() throws {
    let directory = Self.directory()
    defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
    let reports = Reports()
    #expect(
      ModelReleaseTimeoutNote.consume(
        in: directory, crashReportsEnabled: true, report: reports.append) == .none)
    #expect(!FileManager.default.fileExists(atPath: directory.path), "nothing is created")
    #expect(reports.all.isEmpty)
  }

  @Test("each build reads only its own namespace")
  func namespacesStayIsolated() throws {
    let root = TestTemporaryDirectory.url
      .appendingPathComponent("ew-3849-ns-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let dev = root.appendingPathComponent("com.enviouswispr.app.dev", isDirectory: true)
    let production = root.appendingPathComponent("com.enviouswispr.app", isDirectory: true)
    try ModelReleaseTimeoutNote.write(Self.note(), to: dev)
    try ModelReleaseTimeoutNote.write(Self.note(sessions: 5), to: production)
    let productionBytes = try Data(contentsOf: Self.file(in: production))
    let reports = Reports()
    ModelReleaseTimeoutNote.consume(in: dev, crashReportsEnabled: true, report: reports.append)
    #expect(reports.all == [Self.note()])
    #expect(try Data(contentsOf: Self.file(in: production)) == productionBytes)
    // The production location is the build's own bundle folder.
    #expect(
      ModelReleaseTimeoutNote.productionDirectory.lastPathComponent
        == (Bundle.main.bundleIdentifier ?? "com.enviouswispr.app"))
    #expect(
      ModelReleaseTimeoutNote.productionDirectory.deletingLastPathComponent()
        .lastPathComponent == "Diagnostics")
  }

  @Test("a second launch finds nothing to report")
  func secondConsumeDoesNotReportAgain() throws {
    let directory = Self.directory()
    defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
    try ModelReleaseTimeoutNote.write(Self.note(), to: directory)
    let reports = Reports()
    ModelReleaseTimeoutNote.consume(
      in: directory, crashReportsEnabled: true, report: reports.append)
    #expect(
      ModelReleaseTimeoutNote.consume(
        in: directory, crashReportsEnabled: true, report: reports.append) == .none)
    #expect(reports.all.count == 1)
  }

  @Test("a note that cannot be written still ends the process, and says so")
  func writeFailureIsReportedLocally() throws {
    let root = TestTemporaryDirectory.url
      .appendingPathComponent("ew-3849-blocked-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    // A plain file where the note's folder must be created.
    try Data("x".utf8).write(to: root)
    var exits = 0
    let outcome = TranscribeCppProcessExit.releaseBeforeExit(
      release: { _ in .timedOut(sessions: 1) },
      noteDirectory: root.appendingPathComponent("com.enviouswispr.app.dev"),
      exitNow: { exits += 1 })
    #expect(outcome == .exited(noteWritten: false))
    #expect(exits == 1, "a failed note write never keeps a stuck process alive")
  }

  @Test("the report keeps only install identity from the reporting launch's scope")
  func reportScopeDropsTheReportingLaunch() throws {
    // Populated as production leaves it by the time the reader runs (stable tags and the
    // `polish` context from `initialize`), plus later launch state.
    let scope = Scope()
    let install: [String: String] = [
      "app.role": "host", "process.role": "main", "crash.context_schema": "1",
      "app.build_type": "debug", "analytics.distinct_id": "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE",
    ]
    for (key, value) in install { scope.setTag(value: value, key: key) }
    scope.setTag(value: "11111111-2222-3333-4444-555555555555", key: "process.launch_id")
    scope.setTag(value: "whisper", key: "asr.backend")
    scope.setTag(value: "true", key: "synthetic")  // this launch's fault injection, not the quit's
    scope.setContext(value: ["phase": "idle"], key: "polish")
    scope.setContext(value: ["active": true], key: "recording_state")
    scope.setUser(User(userId: "install-user"))
    scope.addBreadcrumb(Breadcrumb(level: .info, category: "relaunch"))
    SentryBreadcrumb.scopeForModelReleaseTimeout(scope)
    let serialized = scope.serialize()
    #expect(serialized["tags"] as? [String: String] == install)
    #expect((serialized["context"] as? [String: Any] ?? [:]).isEmpty)
    #expect((serialized["breadcrumbs"] as? [Any] ?? []).isEmpty)
    #expect((serialized["user"] as? [String: Any])?["id"] as? String == "install-user")
  }

  @Test("the report carries only the declared fields and splits dev from production")
  func eventHasOnlyDeclaredExtrasAndStableEnvironmentGrouping() {
    let event = SentryBreadcrumb.makeModelReleaseTimeoutEvent(
      Self.note(), environment: "production")
    #expect(event.level == .error)
    #expect(event.message?.formatted == "model_release_timeout")
    #expect(event.tags == ["diagnostic.kind": "model_release_timeout"])
    #expect(Set((event.extra ?? [:]).keys) == Self.declaredKeys)
    #expect(event.extra?["sessions"] as? Int == 2)
    #expect(event.extra?["boundMs"] as? Int == 2_000)
    #expect(event.extra?["timestamp"] as? String == "2027-01-15T08:00:00Z")
    #expect(event.fingerprint == ["model_release_timeout", "production"])
    // Sent by the next launch, possibly after an update: the event names the quit that failed.
    #expect(event.releaseName == "com.enviouswispr.app@2.5.4")
    #expect(event.timestamp == Date(timeIntervalSince1970: 1_800_000_000))
    let dev = SentryBreadcrumb.makeModelReleaseTimeoutEvent(Self.note(), environment: "development")
    #expect(dev.fingerprint == ["model_release_timeout", "development"])
    // An unobserved count is left out, never invented.
    let unknown = SentryBreadcrumb.makeModelReleaseTimeoutEvent(
      Self.note(sessions: nil), environment: "production")
    #expect(Set((unknown.extra ?? [:]).keys) == Self.declaredKeys.subtracting(["sessions"]))
  }
}
