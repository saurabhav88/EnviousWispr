import EnviousWisprAppKitTestSupport
import Foundation
import Testing

@testable import EnviousWisprAppKit
@testable import EnviousWisprCore
@testable import EnviousWisprStorage

/// #4013 r2 item 4: when these fail, Transcribe again of a meeting erases a name the user typed
/// (also one typed while the meeting was processing), shows one name and saves another, or a
/// failed save changes the names on screen.
///
/// The replacement rows are synthetic, written here to stand in for a meeting's processing
/// pass; they go through the real durable History command.
@MainActor
@Suite("Meeting rows keep the user's speaker names", .tags(.productOutcome))
struct TranscriptCoordinatorSpeakerNameTests {

  private static func makeTempDir() -> URL {
    let url = TestTemporaryDirectory.url
      .appendingPathComponent("speaker-names-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  private let id = UUID()
  private let meetingID = UUID()

  private func row(
    _ text: String, _ speakers: [(String, Int, Int)], attempt: UUID? = nil
  ) -> Transcript {
    let turns = speakers.map {
      Turn(
        id: "\($0.0)-\($0.1)", speakerId: $0.0, startMs: $0.1, endMs: $0.2,
        originalTextRange: 0..<1, wasPolished: true, granularity: .word)
    }
    let names = Dictionary(
      uniqueKeysWithValues: speakers.enumerated().map { ($0.element.0, "Speaker \($0.offset + 1)") }
    )
    return Transcript(
      id: id, text: text, backendType: .parakeet, speakerAnalysis: .labeled(count: speakers.count),
      speakerNames: names, turns: turns, meetingID: meetingID,
      meetingTranscriptAttemptID: attempt)
  }

  private func onDisk(_ dir: URL) throws -> Transcript {
    try JSONDecoder().decode(
      Transcript.self, from: Data(contentsOf: dir.appendingPathComponent("\(id.uuidString).json")))
  }

  @Test(
    "a name typed before Transcribe again, even after the new pass started, moves to its speaker")
  func renameSurvivesRetranscription() async throws {
    let dir = Self.makeTempDir()
    let coordinator = TranscriptCoordinator(store: TranscriptStore(directory: dir))
    try await coordinator.saveAndShowDurably(
      row("first", [("sys:S1", 0, 5_000), ("sys:S2", 5_000, 9_000)]))
    // The new pass's row exists before the rename lands, as a pass that started earlier would.
    let replacement = row("second", [("sys:S8", 200, 4_800), ("sys:S9", 4_800, 9_000)])
    #expect(
      await coordinator.renameSpeaker(id: id, speakerId: "sys:S1", name: "Ana", isMeeting: true)
        == nil)
    try await coordinator.saveAndShowDurably(replacement)

    let listed = try #require(coordinator.currentRow(id: id))
    let saved = try onDisk(dir)
    #expect(listed.text == "second")
    #expect(listed.speakerNames == ["sys:S8": "Ana", "sys:S9": "Speaker 2"])
    #expect(listed.speakerNameSource(for: "sys:S8") == .manual)
    #expect(saved.speakerNames == listed.speakerNames, "the row shown is the row saved")
    #expect(saved.speakerNameSources == listed.speakerNameSources)

    // A relaunch reads the same names back.
    let relaunched = TranscriptCoordinator(store: TranscriptStore(directory: dir))
    relaunched.load()
    await relaunched.diskReconcilerForTesting.waitForLoadForTesting()
    #expect(
      relaunched.currentRow(id: id)?.speakerNames == ["sys:S8": "Ana", "sys:S9": "Speaker 2"])
  }

  @Test("a launch replay publishing a meeting row History has not loaded keeps the saved names")
  func replayBeforeHistoryLoadKeepsNames() async throws {
    // #3973 C2: after a crash between the ready record and publication, the next launch
    // publishes the candidate row, possibly before History has loaded the previous one.
    let dir = Self.makeTempDir()
    let before = TranscriptCoordinator(store: TranscriptStore(directory: dir))
    try await before.saveAndShowDurably(
      row("first", [("sys:S1", 0, 5_000), ("sys:S2", 5_000, 9_000)]))
    _ = await before.renameSpeaker(id: id, speakerId: "sys:S1", name: "Ana", isMeeting: true)
    _ = await before.renameSpeaker(id: id, speakerId: "sys:S2", name: "Cy", isMeeting: true)
    try await before.saveAndShowDurably(row("second", [("sys:S5", 0, 5_000)]))
    #expect(try onDisk(dir).unassignedSpeakerNames == ["Cy"])

    let attempt = UUID()
    let launched = TranscriptCoordinator(store: TranscriptStore(directory: dir))
    #expect(launched.currentRow(id: id) == nil, "History has not loaded the row")
    try await launched.saveAndShowDurably(row("third", [("sys:S7", 0, 5_000)], attempt: attempt))

    let saved = try onDisk(dir)
    #expect(saved.text == "third")
    #expect(saved.speakerNames == ["sys:S7": "Ana"])
    #expect(saved.speakerNameSource(for: "sys:S7") == .manual)
    #expect(saved.unassignedSpeakerNames == ["Cy"])
    #expect(saved.meetingTranscriptAttemptID == attempt)
    #expect(launched.currentRow(id: id)?.speakerNames == saved.speakerNames)
  }

  @Test("a name with no new speaker to go to is kept on the row, also after a relaunch")
  func unmatchedNameKept() async throws {
    let dir = Self.makeTempDir()
    let coordinator = TranscriptCoordinator(store: TranscriptStore(directory: dir))
    try await coordinator.saveAndShowDurably(row("first", [("sys:S1", 0, 1_000)]))
    _ = await coordinator.renameSpeaker(id: id, speakerId: "sys:S1", name: "Ana", isMeeting: true)
    try await coordinator.saveAndShowDurably(row("second", [("sys:S4", 5_000, 6_000)]))
    #expect(coordinator.currentRow(id: id)?.unassignedSpeakerNames == ["Ana"])
    #expect(try onDisk(dir).unassignedSpeakerNames == ["Ana"])
  }

  @Test("a durable save the disk refuses leaves the user's names as they were, shown and saved")
  func failedSaveKeepsNames() async throws {
    let dir = Self.makeTempDir()
    let coordinator = TranscriptCoordinator(store: TranscriptStore(directory: dir))
    try await coordinator.saveAndShowDurably(row("first", [("sys:S1", 0, 5_000)]))
    _ = await coordinator.renameSpeaker(id: id, speakerId: "sys:S1", name: "Ana", isMeeting: true)
    try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: dir.path)
    var failed = false
    do {
      try await coordinator.saveAndShowDurably(row("second", [("sys:S5", 0, 5_000)]))
    } catch {
      failed = true
    }
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
    #expect(failed)
    #expect(coordinator.currentRow(id: id)?.text == "first")
    #expect(coordinator.currentRow(id: id)?.speakerNames == ["sys:S1": "Ana"])
    #expect(try onDisk(dir).speakerNames == ["sys:S1": "Ana"])
  }
}
