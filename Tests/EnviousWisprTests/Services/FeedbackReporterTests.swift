import Foundation
import Testing

@testable import EnviousWisprServices

/// #3153: what the Send Feedback form accepts, and (#3269) what it saves to the outbox.
@Suite("Feedback reporter (#3153)", .tags(.productOutcome))
@MainActor
struct FeedbackReporterTests {

  // MARK: - Draft

  @Test("An empty or whitespace-only message cannot be sent")
  func emptyMessageRejected() {
    #expect(FeedbackDraft.issue(message: "", email: "") == .emptyMessage)
    #expect(FeedbackDraft.issue(message: "  \n\t ", email: "") == .emptyMessage)
    #expect(FeedbackDraft(message: "   ", email: "") == nil)
  }

  @Test("The length cap is inclusive at 4000 characters, after trimming")
  func lengthCap() {
    let atCap = String(repeating: "a", count: FeedbackDraft.maxMessageLength)
    #expect(FeedbackDraft.maxMessageLength == 4000)
    #expect(FeedbackDraft(message: atCap, email: "")?.message == atCap)
    #expect(FeedbackDraft.issue(message: atCap + "a", email: "") == .messageTooLong)
    // Surrounding whitespace does not count against the cap.
    #expect(FeedbackDraft(message: "  " + atCap + "\n", email: "")?.message == atCap)
  }

  @Test("A long message keeps every character; only surrounding whitespace is trimmed")
  func longMessageIntact() {
    let body = String(
      (0..<78).map { "Line \($0): the paste landed twice in Slack, then once." }
        .joined(separator: "\n").prefix(3900))
    #expect(body.count == 3900)
    #expect(FeedbackDraft(message: "\n  " + body + "  \n", email: "")?.message == body)
  }

  @Test("Email: empty sends none; a shaped address is kept trimmed; a malformed one blocks Send")
  func emailRules() {
    #expect(FeedbackDraft(message: "hi", email: "")?.email == nil)
    #expect(FeedbackDraft(message: "hi", email: "   ")?.email == nil)
    #expect(FeedbackDraft(message: "hi", email: " a@b.co ")?.email == "a@b.co")
    #expect(FeedbackDraft.issue(message: "hi", email: "a@b") == .invalidEmail)
    #expect(FeedbackDraft.issue(message: "hi", email: "a b@c.co") == .invalidEmail)
    // A reply could never reach these (second-pass review): empty domain label, trailing comma.
    #expect(FeedbackDraft.issue(message: "hi", email: "a@b..co") == .invalidEmail)
    #expect(FeedbackDraft.issue(message: "hi", email: "a@b.co,") == .invalidEmail)
    // Cloud review: dot and hyphen edges in either part.
    for bad in ["a..b@example.com", ".a@example.com", "a.@example.com", "a@-example.com",
      "a@example-.com", "a@example.c0m", "a@.example.com"]
    {
      #expect(FeedbackDraft.issue(message: "hi", email: bad) == .invalidEmail, "\(bad)")
    }
    // Local enumeration round: real internationalized addresses must be accepted.
    for good in [
      "a.b@example.com", "a_b-c@sub.example-site.co.uk", "o'neil@example.ie", "josé@example.com",
      "a@bücher.de", "a@例子.中国", "a@b.xn--p1ai", "a@b.XN--P1AI",
    ] {
      #expect(FeedbackDraft.issue(message: "hi", email: good) == nil, "\(good)")
    }
    #expect(FeedbackDraft(message: "hi", email: "first.last+tag@mail.example-site.io")?.email
      == "first.last+tag@mail.example-site.io")
    #expect(FeedbackDraft(message: "hi", email: "a@b") == nil)
  }

  // MARK: - Unsent draft

  @Test("An unsent draft survives a new store (popover, window or app closed) until cleared")
  func draftSurvivesUntilCleared() throws {
    let suite = "FeedbackDraftStoreTests.\(UUID().uuidString)"
    defer { UserDefaults().removePersistentDomain(forName: suite) }
    let first = FeedbackDraftStore(defaults: { UserDefaults(suiteName: suite)! })
    #expect(first.message == "")
    #expect(first.email == "")
    first.save(message: "it pasted twice in slack", email: "a@b.co")

    // A fresh store over the same defaults is what a reopened popover or relaunched app sees.
    let reopened = FeedbackDraftStore(defaults: { UserDefaults(suiteName: suite)! })
    #expect(reopened.message == "it pasted twice in slack")
    #expect(reopened.email == "a@b.co")

    // An emptied field is removed, not stored as "".
    reopened.save(message: "still here", email: "")
    #expect(UserDefaults(suiteName: suite)!.object(forKey: "feedback.draft.email") == nil)
    #expect(reopened.message == "still here")

    reopened.clear()
    #expect(FeedbackDraftStore(defaults: { UserDefaults(suiteName: suite)! }).message == "")
    #expect(UserDefaults(suiteName: suite)!.object(forKey: "feedback.draft.message") == nil)
  }

  @Test("A saved report clears the draft only if it still holds what was sent")
  func clearOnlyIfUnchanged() throws {
    let suite = "FeedbackDraftStoreTests.\(UUID().uuidString)"
    defer { UserDefaults().removePersistentDomain(forName: suite) }
    let store = FeedbackDraftStore(defaults: { UserDefaults(suiteName: suite)! })
    store.save(message: "first report", email: "a@b.co")

    // A form reopened while the report was saving, and edited there.
    let reopened = FeedbackDraftStore(defaults: { UserDefaults(suiteName: suite)! })
    reopened.save(message: "a second thought", email: "a@b.co")
    #expect(store.clear(ifStill: "first report", email: "a@b.co") == false)
    #expect(reopened.message == "a second thought")

    #expect(store.clear(ifStill: "a second thought", email: "a@b.co") == true)
    #expect(reopened.message == "")
    #expect(reopened.email == "")
  }

  @Test("A message within 4,000 characters but over Sentry's 4,096 code points cannot be sent")
  func codePointLimit() {
    // Each flag is one character but two code points.
    let flags = String(repeating: "🇩🇪", count: 2049)
    #expect(flags.count == 2049)
    #expect(flags.unicodeScalars.count == 4098)
    #expect(FeedbackDraft.issue(message: flags, email: "") == .messageTooLong)
    let fits = String(repeating: "🇩🇪", count: 2048)
    #expect(FeedbackDraft.issue(message: fits, email: "") == nil)
  }

  // MARK: - Send (#3269: the outbox)

  nonisolated static let context = FeedbackRecord.Context(
    appVersion: "2.5.2", appBuild: "252", release: "com.enviouswispr.app@2.5.2",
    environment: "development", osVersion: "15.4.0", osBuild: "24E248")

  /// A sender that never gets through, so a saved report stays on disk to be read back.
  nonisolated static let unreachable = FeedbackSender(
    dsn: FeedbackOutboxTests.dsn, http: { _ in throw URLError(.notConnectedToInternet) },
    now: { Date() })

  private static func outbox(online: Bool = true, directory: URL) -> FeedbackOutbox {
    let path = FeedbackOutboxTests.FakePath(satisfied: online)
    return FeedbackOutbox(directory: directory, sender: unreachable, path: path)
  }

  private static func tempDirectory() -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("ew-3269-reporter-\(UUID().uuidString)", isDirectory: true)
  }

  @Test("Send freezes exactly the form's choices into the saved report")
  func sendFreezesTheReport() async throws {
    let directory = Self.tempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let outbox = Self.outbox(directory: directory)
    let draft = try #require(
      FeedbackDraft(message: "  it pasted twice in slack  ", email: " someone@example.com "))
    let snapshot = FeedbackDiagnosticsSnapshot(data: Data(#"{"schema_version":1}"#.utf8))
    let id = try #require(UUID(uuidString: "5D1E6A2B-9C3F-4E7A-8B10-2F4C6D8E0A1B"))
    let when = Date(timeIntervalSince1970: 1_790_000_000)

    let outcome = await FeedbackReporter.send(
      draft, diagnostics: snapshot, outbox: outbox, now: when, id: id, context: Self.context)

    #expect(outcome == .saved(offline: false))
    let saved = try FeedbackOutboxTests.records(in: directory)
    #expect(saved.count == 1)
    let record = try #require(saved.first)
    #expect(record.id == id)
    #expect(record.submittedAt == when)
    #expect(record.message == "it pasted twice in slack")
    #expect(record.email == "someone@example.com")
    #expect(record.attachment == snapshot.data)
    #expect(record.context == Self.context)
    #expect(record.state == .pending)
  }

  @Test("Unticked means no attachment; offline at Send is reported for the confirmation line")
  func uncheckedAndOffline() async throws {
    let directory = Self.tempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let outbox = Self.outbox(online: false, directory: directory)
    let draft = try #require(FeedbackDraft(message: "love it", email: ""))

    let outcome = await FeedbackReporter.send(
      draft, diagnostics: nil, outbox: outbox, now: Date(), id: UUID(), context: Self.context)

    #expect(outcome == .saved(offline: true))
    let record = try #require(try FeedbackOutboxTests.records(in: directory).first)
    #expect(record.attachment == nil)
    #expect(record.email == nil)
  }

  @Test("A report that cannot be saved says so, and nothing is kept")
  func unavailableStorage() async throws {
    let directory = Self.tempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let outbox = FeedbackOutbox(
      directory: directory, sender: Self.unreachable,
      path: FeedbackOutboxTests.FakePath(satisfied: true),
      writeData: { _, _ in throw CocoaError(.fileWriteNoPermission) })
    let draft = try #require(FeedbackDraft(message: "hi", email: ""))

    let outcome = await FeedbackReporter.send(
      draft, diagnostics: nil, outbox: outbox, now: Date(), id: UUID(), context: Self.context)

    #expect(outcome == .unavailable)
    #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("outbox.json").path) == false)
  }
}
