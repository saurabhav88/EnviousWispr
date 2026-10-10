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
    let first = FeedbackDraftStore(defaults: { TestDefaults.suite(suite)! })
    #expect(first.message == "")
    #expect(first.email == "")
    first.save(message: "it pasted twice in slack", email: "a@b.co")

    // A fresh store over the same defaults is what a reopened popover or relaunched app sees.
    let reopened = FeedbackDraftStore(defaults: { TestDefaults.suite(suite)! })
    #expect(reopened.message == "it pasted twice in slack")
    #expect(reopened.email == "a@b.co")

    // An emptied field is removed, not stored as "".
    reopened.save(message: "still here", email: "")
    #expect(TestDefaults.suite(suite)!.object(forKey: "feedback.draft.email") == nil)
    #expect(reopened.message == "still here")

    reopened.clear()
    #expect(FeedbackDraftStore(defaults: { TestDefaults.suite(suite)! }).message == "")
    #expect(TestDefaults.suite(suite)!.object(forKey: "feedback.draft.message") == nil)
  }

  @Test("A saved report clears the draft only if it still holds what was sent")
  func clearOnlyIfUnchanged() throws {
    let suite = "FeedbackDraftStoreTests.\(UUID().uuidString)"
    defer { UserDefaults().removePersistentDomain(forName: suite) }
    let store = FeedbackDraftStore(defaults: { TestDefaults.suite(suite)! })
    store.save(message: "first report", email: "a@b.co")

    // A form reopened while the report was saving, and edited there.
    let reopened = FeedbackDraftStore(defaults: { TestDefaults.suite(suite)! })
    reopened.save(message: "a second thought", email: "a@b.co")
    #expect(store.clear(ifStill: "first report", email: "a@b.co") == false)
    #expect(reopened.message == "a second thought")

    #expect(store.clear(ifStill: "a second thought", email: "a@b.co") == true)
    #expect(reopened.message == "")
    #expect(reopened.email == "")
  }

  @Test("When a save finishes: words typed meanwhile survive, and a closed form stays quiet")
  func settleAfterSave() throws {
    func store() -> (FeedbackDraftStore, String) {
      let suite = "FeedbackDraftStoreTests.\(UUID().uuidString)"
      return (FeedbackDraftStore(defaults: { TestDefaults.suite(suite)! }), suite)
    }

    // Same form on screen, newer words typed that the store has not caught up with yet.
    let (a, suiteA) = store()
    defer { UserDefaults().removePersistentDomain(forName: suiteA) }
    a.save(message: "sent words", email: "")
    #expect(
      a.settleAfterSave(
        saved: true, isSendingFormOnScreen: true, form: ("sent words, and more", ""),
        sent: ("sent words", "")) == true)
    #expect(a.message == "sent words, and more")

    // Same form, nothing typed since Send: the draft clears.
    let (b, suiteB) = store()
    defer { UserDefaults().removePersistentDomain(forName: suiteB) }
    b.save(message: "sent words", email: "a@b.co")
    #expect(
      b.settleAfterSave(
        saved: true, isSendingFormOnScreen: true, form: ("sent words", "a@b.co"),
        sent: ("sent words", "a@b.co")) == true)
    #expect(b.message == "")

    // The sending form closed and a reopened one saved newer words: they survive, and the old
    // form is told not to show a result or close anything.
    let (c, suiteC) = store()
    defer { UserDefaults().removePersistentDomain(forName: suiteC) }
    c.save(message: "a second thought", email: "")
    #expect(
      c.settleAfterSave(
        saved: true, isSendingFormOnScreen: false, form: ("sent words", ""),
        sent: ("sent words", "")) == false)
    #expect(c.message == "a second thought")

    // Not saved (full or unavailable): the draft is untouched.
    let (d, suiteD) = store()
    defer { UserDefaults().removePersistentDomain(forName: suiteD) }
    d.save(message: "sent words", email: "")
    #expect(
      d.settleAfterSave(
        saved: false, isSendingFormOnScreen: true, form: ("sent words", ""),
        sent: ("sent words", "")) == true)
    #expect(d.message == "sent words")
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

  @Test("A draft's category is frozen into the saved report; no choice saves none")
  func sendFreezesTheCategory() async throws {
    let directory = Self.tempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let outbox = Self.outbox(directory: directory)
    let chosen = try #require(
      FeedbackDraft(message: "Shift stuck", email: "", category: .typingOrShortcutInterference))
    let plain = try #require(FeedbackDraft(message: "love it", email: ""))
    #expect(plain.category == nil, "ordinary feedback needs no category")
    for (draft, id) in [
      (chosen, UUID(uuidString: "5D1E6A2B-9C3F-4E7A-8B10-2F4C6D8E0A1B")!),
      (plain, UUID(uuidString: "6D1E6A2B-9C3F-4E7A-8B10-2F4C6D8E0A1B")!),
    ] {
      let outcome = await FeedbackReporter.send(
        draft, diagnostics: nil, outbox: outbox, now: Date(timeIntervalSince1970: 1_790_000_000),
        id: id, context: Self.context)
      #expect(outcome == .saved(offline: false))
    }
    let saved = try FeedbackOutboxTests.records(in: directory)
    #expect(Set(saved.map(\.category)) == [.typingOrShortcutInterference, nil])
    #expect(saved.first { $0.message == "Shift stuck" }?.category == .typingOrShortcutInterference)
    #expect(saved.first { $0.message == "love it" }?.category == nil)
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

  @Test("Send freezes the help-check outcome with the report, and none when no check ran")
  func sendFreezesTheHelpOutcome() async throws {
    let directory = Self.tempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let outbox = Self.outbox(directory: directory)
    let draft = try #require(FeedbackDraft(message: "paste fails", email: ""))
    let help = FeedbackSenderTests.helpOutcome

    _ = await FeedbackReporter.send(
      draft, diagnostics: nil, helpOutcome: help, outbox: outbox, now: Date(), id: UUID(),
      context: Self.context)
    _ = await FeedbackReporter.send(
      draft, diagnostics: nil, outbox: outbox, now: Date(), id: UUID(), context: Self.context)

    let saved = try FeedbackOutboxTests.records(in: directory)
    #expect(saved.map(\.helpOutcome) == [help, nil])
    #expect(saved.map(\.message) == ["paste fails", "paste fails"])
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

  // MARK: - Usage-link id (#3382)

  /// Two different ids, so every expectation names which source won.
  static let fileID = FeedbackDiagnosticsSnapshotTests.joinKey
  static let savedID = "11111111-2222-4333-8444-aabbccddeeff"

  static func file(id: String?) throws -> FeedbackDiagnosticsSnapshot {
    try #require(
      FeedbackDiagnosticsSnapshot.make(diarySnapshot: FeedbackDiagnosticsSnapshotTests.diary, joinKey: id))
  }

  @Test("The four rows the founder set (2026-10-02): box and switch at Send decide the id")
  func usageLinkMatrix() throws {
    let ticked = try Self.file(id: Self.fileID)
    // Ticked, metrics on: the file's id.
    #expect(
      FeedbackReporter.usageLinkID(diagnostics: ticked, usageMetrics: true, savedID: Self.savedID)
        == Self.fileID)
    // Ticked, metrics off: still the file's id; the user chose to share the file.
    #expect(
      FeedbackReporter.usageLinkID(diagnostics: ticked, usageMetrics: false, savedID: Self.savedID)
        == Self.fileID)
    // Unticked, metrics on: the saved id.
    #expect(
      FeedbackReporter.usageLinkID(diagnostics: nil, usageMetrics: true, savedID: Self.savedID)
        == Self.savedID)
    // Unticked, metrics off: none.
    #expect(
      FeedbackReporter.usageLinkID(diagnostics: nil, usageMetrics: false, savedID: Self.savedID)
        == nil)
  }

  @Test("Each source stands alone: a file id needs no saved id; the saved id needs metrics on")
  func usageLinkSourcesIndependent() throws {
    let ticked = try Self.file(id: Self.fileID)
    let tickedNoID = try Self.file(id: nil)
    let unreadable = FeedbackDiagnosticsSnapshot(data: Data("not json".utf8))
    // A valid file id survives an absent saved id, in either switch state.
    for metrics in [true, false] {
      #expect(
        FeedbackReporter.usageLinkID(diagnostics: ticked, usageMetrics: metrics, savedID: nil)
          == Self.fileID)
    }
    // A file without a valid id falls back to the saved id only with metrics on.
    for file in [tickedNoID, unreadable] {
      #expect(
        FeedbackReporter.usageLinkID(diagnostics: file, usageMetrics: true, savedID: Self.savedID)
          == Self.savedID)
      #expect(
        FeedbackReporter.usageLinkID(diagnostics: file, usageMetrics: false, savedID: Self.savedID)
          == nil)
    }
    // Neither source has a valid id: none.
    #expect(
      FeedbackReporter.usageLinkID(diagnostics: tickedNoID, usageMetrics: true, savedID: nil) == nil)
    #expect(
      FeedbackReporter.usageLinkID(diagnostics: nil, usageMetrics: true, savedID: "not-a-uuid")
        == nil)
  }

  @Test("Send freezes the decided id into the saved report; an omitted switch is off")
  func sendFreezesTheUsageLinkID() async throws {
    let directory = Self.tempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let outbox = Self.outbox(directory: directory)
    let draft = try #require(FeedbackDraft(message: "paste fails", email: ""))

    _ = await FeedbackReporter.send(
      draft, diagnostics: nil, outbox: outbox, now: Date(), id: UUID(), context: Self.context,
      usageMetrics: true, savedID: Self.savedID)
    _ = await FeedbackReporter.send(
      draft, diagnostics: nil, outbox: outbox, now: Date(), id: UUID(), context: Self.context,
      savedID: Self.savedID)
    _ = await FeedbackReporter.send(
      draft, diagnostics: try Self.file(id: Self.fileID), outbox: outbox, now: Date(), id: UUID(),
      context: Self.context, usageMetrics: false, savedID: Self.savedID)

    let saved = try FeedbackOutboxTests.records(in: directory)
    #expect(saved.map(\.usageLinkID) == [Self.savedID, nil, Self.fileID])
  }
}
