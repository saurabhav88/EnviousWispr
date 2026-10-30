import EnviousWisprAppKitTestSupport
import Foundation
import Testing

@testable import EnviousWisprAppKit
@testable import EnviousWisprCore
@testable import EnviousWisprPipeline
@testable import EnviousWisprStorage

/// #4013 chunk 12B (r3 F4): when these fail, `meeting.ended` reports names History never kept,
/// counts a name the user replaced, arrives before the transcript is saved or twice for one
/// attempt, or a deletion after the meeting was ready reports it as deleted before ready.
///
/// The summaries come from the real durable History command (`TranscriptCoordinator`) over
/// SYNTHETIC rows and the SYNTHETIC evidence of `CallSpeakerTestLog`. The rows sent are what the
/// test hook received, not proof of vendor delivery.
@MainActor
@Suite(
  "meeting.ended reports the names History kept", .tags(.productOutcome), .timeLimit(.minutes(1)))
struct MeetingEndedNamingTests {
  typealias Harness = MeetingCoordinatorTests.Harness

  private func eventually(_ label: String, _ condition: @escaping @MainActor () -> Bool) async {
    await MeetingCoordinatorTests.eventually(label, condition)
  }

  private static func historyDirectory() -> URL {
    let url = TestTemporaryDirectory.url
      .appendingPathComponent("ended-naming-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  // MARK: - The durable History command's summary

  private let rowID = UUID()
  private let meetingID = UUID()

  private func row(names: [String: String], sources: [String: SpeakerNameSource]?) -> Transcript {
    let turns = names.keys.sorted().enumerated().map { index, speaker in
      Turn(
        id: "\(speaker)-\(index)", speakerId: speaker, startMs: index * 5_000,
        endMs: index * 5_000 + 4_000, originalTextRange: 0..<1, wasPolished: true,
        granularity: .word)
    }
    return Transcript(
      id: rowID, text: "x", backendType: .parakeet, speakerAnalysis: .labeled(count: names.count),
      speakerNames: names, turns: turns, speakerNameSources: sources, meetingID: meetingID)
  }

  @Test("the summary counts the automatic names History kept after the user's names")
  func mixedManualAndAutomatic() async throws {
    let history = TranscriptCoordinator(store: TranscriptStore(directory: Self.historyDirectory()))
    try await history.saveAndShowDurably(
      row(names: ["sys:1": "Speaker 1", "sys:2": "Speaker 2"], sources: nil))
    _ = await history.renameSpeaker(id: rowID, speakerId: "sys:1", name: "Ana", isMeeting: true)

    let proposed = row(
      names: ["sys:1": "Alex Rivera", "sys:2": "Priya Shah"],
      sources: ["sys:1": .auto, "sys:2": .auto])
    let summary = try await history.saveAndShowDurably(
      proposed, naming: .proposed(surface: .meet, count: 2))
    #expect(summary == SpeakerNamingSummary(surface: .meet, outcome: .named, autoNamedCount: 1))
    #expect(history.currentRow(id: rowID)?.speakerNames == ["sys:1": "Ana", "sys:2": "Priya Shah"])
  }

  @Test("every proposal replaced by the user's names is manual only, with a known zero")
  func everyProposalDisplaced() async throws {
    let history = TranscriptCoordinator(store: TranscriptStore(directory: Self.historyDirectory()))
    try await history.saveAndShowDurably(row(names: ["sys:1": "Speaker 1"], sources: nil))
    _ = await history.renameSpeaker(id: rowID, speakerId: "sys:1", name: "Ana", isMeeting: true)
    let summary = try await history.saveAndShowDurably(
      row(names: ["sys:1": "Alex Rivera"], sources: ["sys:1": .auto]),
      naming: .proposed(surface: .meet, count: 1))
    #expect(
      summary == SpeakerNamingSummary(surface: .meet, outcome: .manualOnly, autoNamedCount: 0))
  }

  @Test("no naming pass, no summary; a write that fails returns none")
  func noPassOrFailedWriteGivesNoSummary() async throws {
    let dir = Self.historyDirectory()
    let history = TranscriptCoordinator(store: TranscriptStore(directory: dir))
    #expect(
      try await history.saveAndShowDurably(row(names: ["sys:1": "Speaker 1"], sources: nil)) == nil)

    let broken = Self.historyDirectory()
    try Data("{ not a transcript".utf8).write(
      to: broken.appendingPathComponent("\(rowID.uuidString).json"))
    let launched = TranscriptCoordinator(store: TranscriptStore(directory: broken))
    await #expect(throws: (any Error).self) {
      try await launched.saveAndShowDurably(
        row(names: ["sys:1": "Alex Rivera"], sources: ["sys:1": .auto]),
        naming: .proposed(surface: .meet, count: 1))
    }
  }

  // MARK: - When meeting.ended is sent

  /// A harness whose History is the real durable command and whose pass names from the saved
  /// SYNTHETIC evidence.
  private func namingHarness() throws -> Harness {
    let harness = try Harness()
    harness.history = TranscriptCoordinator(
      store: TranscriptStore(directory: Self.historyDirectory()))
    harness.jobBehavior = MeetingSpeakerNamingProcessingTests.namingPass(harness)
    return harness
  }

  /// Starts a meeting with evidence and stops it; the History save is held at `save`.
  private func meetingParkedAtSave(_ harness: Harness, _ save: MeetingCoordinatorTests.Gate)
    async throws -> UUID
  {
    harness.saveGate = save
    let coordinator = harness.coordinator
    await coordinator.start(from: .history)
    let meetingID = try #require(harness.recorders.first).configuration.meetingID
    try harness.store.saveCallSpeakers(try CallSpeakerTestLog.meet(), meeting: meetingID)
    await coordinator.stop()
    await eventually("History save parked") { save.parked }
    return meetingID
  }

  @Test("the row waits for History: none while the save is held, then one with what was kept")
  func sentAfterHistoryWithNames() async throws {
    let harness = try namingHarness()
    let save = MeetingCoordinatorTests.Gate()
    let meetingID = try await meetingParkedAtSave(harness, save)
    // #4218: deliberate window: ready is persisted while History's save is held; no row yet.
    #expect(harness.coordinator.record(id: meetingID)?.state == .ready, "the barrier is passed")
    #expect(harness.ended.isEmpty, "nothing is sent before History answers")
    #expect(harness.namingPasses.last == .some(.proposed(surface: .meet, count: 1)))

    save.open()
    await eventually("sent") { harness.ended.count == 1 }
    let row = try #require(harness.ended.first)
    #expect(row.outcome == .ready)
    #expect(row.speakerNamesSurface == .meet)
    #expect(row.speakerNamesOutcome == .named)
    #expect(row.autoNamedCount == 1)
    #expect(row.speakerCount == 2, "the other facts are the attempt's own")
  }

  @Test("a receipt that cannot be cleared after History saved the row keeps the names in the row")
  func receiptClearFailureKeepsSummary() async throws {
    let harness = try namingHarness()
    let save = MeetingCoordinatorTests.Gate()
    let meetingID = try await meetingParkedAtSave(harness, save)
    // Only the meeting's folder turns read-only: the receipt cannot be removed. History's own
    // folder is elsewhere, so the row is still written.
    let folder = harness.store.folder(for: meetingID)
    let manager = FileManager.default
    let original = try manager.attributesOfItem(atPath: folder.path)[.posixPermissions]
    try manager.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
    defer {
      if let original {
        try? manager.setAttributes([.posixPermissions: original], ofItemAtPath: folder.path)
      }
    }
    save.open()
    await eventually("sent") { harness.ended.count == 1 && harness.coordinator.processing == nil }
    let row = try #require(harness.ended.first)
    #expect(row.speakerNamesSurface == .meet)
    #expect(row.speakerNamesOutcome == .named)
    #expect(row.autoNamedCount == 1)
    #expect(harness.coordinator.isCommitReceiptPending(meetingID), "the receipt stayed")
    #expect(harness.ended.count == 1)
  }

  @Test("a History save that fails sends one ready row with no naming facts")
  func failedPublicationSendsNoNaming() async throws {
    let harness = try namingHarness()
    harness.saveError = CocoaError(.fileWriteNoPermission)
    let coordinator = harness.coordinator
    await coordinator.start(from: .history)
    let meetingID = try #require(harness.recorders.first).configuration.meetingID
    try harness.store.saveCallSpeakers(try CallSpeakerTestLog.meet(), meeting: meetingID)
    await coordinator.stop()
    await eventually("sent") { harness.ended.count == 1 && coordinator.processing == nil }
    let row = try #require(harness.ended.first)
    #expect(row.outcome == .ready)
    #expect(row.speakerNamesSurface == nil)
    #expect(row.speakerNamesOutcome == nil)
    #expect(row.autoNamedCount == nil, "unknown, not zero")
  }

  @Test(
    "deleting the meeting while History is saved sends one ready row, never deleted before ready")
  func deletionAfterBarrier() async throws {
    let harness = try namingHarness()
    let save = MeetingCoordinatorTests.Gate()
    let meetingID = try await meetingParkedAtSave(harness, save)
    let deletion = Task { await harness.coordinator.delete(meetingID: meetingID) }
    save.open()
    _ = await deletion.value
    await eventually("sent") { harness.ended.count >= 1 && harness.coordinator.processing == nil }
    #expect(harness.ended.map(\.outcome) == [.ready])
  }

  @Test(
    "quit while History is saved sends the row then, without naming; the late answer sends nothing")
  func quitSettlesOnce() async throws {
    let harness = try namingHarness()
    let save = MeetingCoordinatorTests.Gate()
    _ = try await meetingParkedAtSave(harness, save)
    harness.coordinator.prepareForTermination()
    #expect(harness.ended.count == 1)
    #expect(harness.ended.first?.outcome == .ready)
    #expect(harness.ended.first?.autoNamedCount == nil)
    save.open()
    await eventually("History answered and pass over") {
      !harness.saved.isEmpty && harness.coordinator.processing == nil
    }
    #expect(harness.ended.count == 1, "no second row for the same attempt")
  }

  @Test("Transcribe again sends its own row with its own facts")
  func retrySendsItsOwnRow() async throws {
    let harness = try namingHarness()
    let coordinator = harness.coordinator
    await coordinator.start(from: .history)
    let meetingID = try #require(harness.recorders.first).configuration.meetingID
    await coordinator.stop()
    await eventually("first row") { harness.ended.count == 1 && coordinator.processing == nil }
    #expect(harness.ended.first?.autoNamedCount == 0, "no evidence: a known zero")
    #expect(harness.ended.first?.speakerNamesOutcome == nil)

    try harness.store.saveCallSpeakers(try CallSpeakerTestLog.meet(), meeting: meetingID)
    #expect(await coordinator.transcribeAgain(meetingID: meetingID, engine: .parakeet))
    await eventually("second row") { harness.ended.count == 2 && coordinator.processing == nil }
    #expect(harness.ended.last?.speakerNamesOutcome == .named)
    #expect(harness.ended.last?.autoNamedCount == 1)
  }
}
