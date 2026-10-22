import Foundation
import Testing

@testable import EnviousWisprAudio
@testable import EnviousWisprCore

/// #3972 R3, R15: when these fail, a meeting recorded before a crash, force quit or power cut
/// loses audio that reached the disk, or recovery overwrites a file it should have kept.
@Suite("MeetingTrackRecovery", .tags(.productOutcome, .realBoundary))
struct MeetingTrackRecoveryTests {
  private typealias F = MeetingAudioFixture

  private func names(_ dir: URL) throws -> Set<String> {
    Set(try FileManager.default.contentsOfDirectory(atPath: dir.path))
  }

  @Test(
    "recovery promotes readable partials, lists orphan finals and keeps every file it cannot use")
  func recoversFromFiles() throws {
    let dir = try F.folder("MeetingTrackRecoveryTests")
    // A final the metadata never heard of, a readable partial, an unreadable partial, a partial
    // whose final already exists, and a call-sound final.
    try F.writeSegment(in: dir, index: 1, startMs: 0, frames: 16_000)
    let readablePartial = try F.writeSegment(
      in: dir, index: 2, startMs: 1_000, frames: 8_000, partial: true)
    let brokenPartial = dir.appendingPathComponent(
      MeetingSegmentNaming.fileName(track: .microphone, index: 3, startMs: 1_500, partial: true))
    try Data(repeating: 9, count: 64).write(to: brokenPartial)
    let shadowed = try F.writeSegment(
      in: dir, index: 1, startMs: 0, frames: 100, seed: 5, partial: true)
    let finalBytes = try Data(
      contentsOf: dir.appendingPathComponent(
        MeetingSegmentNaming.fileName(track: .microphone, index: 1, startMs: 0, partial: false)))
    try F.writeSegment(in: dir, track: .callSound, index: 4, startMs: 0, frames: 1_600)

    let report = MeetingTrackRecovery.recover(folder: dir)
    let promotedName = MeetingSegmentNaming.fileName(
      track: .microphone, index: 2, startMs: 1_000, partial: false)
    #expect(report.promoted == [promotedName])
    #expect(
      report.segments[.microphone]?.map(\.fileName) == [
        MeetingSegmentNaming.fileName(track: .microphone, index: 1, startMs: 0, partial: false),
        promotedName,
      ])
    #expect(report.segments[.microphone]?.map(\.frameCount) == [16_000, 8_000])
    #expect(report.segments[.callSound]?.map(\.frameCount) == [1_600])
    #expect(report.highestIndex == [.microphone: 3, .callSound: 4])
    #expect(
      Set(report.problems) == [
        .unreadablePartial(fileName: brokenPartial.lastPathComponent),
        .partialBesideFinal(fileName: shadowed.lastPathComponent),
      ])
    // Nothing overwritten: the shadowed final's bytes are unchanged and both kept files remain.
    #expect(
      try Data(
        contentsOf: dir.appendingPathComponent(
          MeetingSegmentNaming.fileName(track: .microphone, index: 1, startMs: 0, partial: false)))
        == finalBytes)
    #expect(FileManager.default.fileExists(atPath: brokenPartial.path))
    #expect(FileManager.default.fileExists(atPath: shadowed.path))
    #expect(!FileManager.default.fileExists(atPath: readablePartial.path))

    // Repeatable: a second run promotes nothing and lists the same audio.
    let again = MeetingTrackRecovery.recover(folder: dir)
    #expect(again.promoted.isEmpty)
    #expect(again.segments == report.segments)
    #expect(again.highestIndex == report.highestIndex)
  }

  @Test("two files sharing one index are both kept and reported")
  func duplicateIndexIsReported() throws {
    let dir = try F.folder("MeetingTrackRecoveryTests")
    try F.writeSegment(in: dir, index: 2, startMs: 0, frames: 1_600)
    try F.writeSegment(in: dir, index: 2, startMs: 5_000, frames: 1_600)
    let report = MeetingTrackRecovery.recover(folder: dir)
    #expect(report.problems == [.duplicateIndex(track: .microphone, index: 2)])
    #expect(report.segments[.microphone]?.map(\.startMs) == [0, 5_000])
  }

  @Test("a folder that cannot be listed is a reported problem, never an empty meeting")
  func unreadableFolderIsReported() {
    let missing = FileManager.default.temporaryDirectory
      .appendingPathComponent("MeetingTrackRecoveryTests-missing-\(UUID().uuidString)")
    let report = MeetingTrackRecovery.recover(folder: missing)
    #expect(report.segments.isEmpty)
    #expect(report.problems.count == 1)
    if case .folderUnreadable = report.problems.first {
    } else {
      Issue.record("expected folderUnreadable, got \(report.problems)")
    }
  }

  @Test("a promotion that cannot be made durable is reported, and the files are kept")
  func failedDirectorySyncIsReported() throws {
    let dir = try F.folder("MeetingTrackRecoveryTests")
    try F.writeSegment(in: dir, index: 1, startMs: 0, frames: 1_600, partial: true)
    let report = MeetingTrackRecovery.recover(folder: dir, syncDirectory: { _ in EIO })
    #expect(report.problems == [.directorySyncFailed(errno: EIO)])
    #expect(report.promoted.count == 1)
    #expect(report.segments[.microphone]?.map(\.frameCount) == [1_600])
  }

  // DEBUG only: the child stops at the writer's DEBUG phase hook.
  #if DEBUG
  // MARK: - Real process death

  /// Kills a child process running the production writer at `phase` and checks recovery finds
  /// every sample the child wrote, exactly once, and changes nothing on a second run.
  private func killAndRecover(_ phase: String) async throws {
    let dir = try F.folder("MeetingTrackRecoveryTests-kill")
    let child = try await MeetingWriterCrash.runAndKill(phase: phase, folder: dir)
    #expect(child.reachedPhase, "child never announced \(phase): \(child.output.suffix(400))")
    #expect(child.killedBySIGKILL)
    print("MEETING_KILL phase=\(phase) files=\(try names(dir).sorted())")

    let report = MeetingTrackRecovery.recover(folder: dir)
    #expect(report.problems.isEmpty, "\(report.problems)")
    let segments = try #require(report.segments[.microphone])
    #expect(segments.count == 1)
    #expect(segments.first?.frameCount == MeetingWriterCrash.frames)
    #expect(segments.first?.startMs == 0)
    let url = dir.appendingPathComponent(try #require(segments.first?.fileName))
    let decoded = try F.decode(url)
    #expect(
      F.matches(decoded[...], (0..<MeetingWriterCrash.frames).map(MeetingWriterCrash.sample)))
    let before = try names(dir)
    let again = MeetingTrackRecovery.recover(folder: dir)
    #expect(again.promoted.isEmpty)
    #expect(again.segments == report.segments)
    #expect(try names(dir) == before)
  }

  @Test("killed while the segment is still open: every written sample is recovered")
  func killAfterAppend() async throws {
    try await killAndRecover(MeetingWriterCrash.appended)
  }

  @Test("killed after the file closed but before its rename: recovery promotes it")
  func killBeforeRename() async throws {
    try await killAndRecover(MeetingTrackWriter.Phase.disposed.rawValue)
  }

  @Test("killed after the rename but before the owner was told: the orphan final is recovered")
  func killBeforeAcknowledgment() async throws {
    try await killAndRecover(MeetingTrackWriter.Phase.published.rawValue)
  }
  #endif

}
