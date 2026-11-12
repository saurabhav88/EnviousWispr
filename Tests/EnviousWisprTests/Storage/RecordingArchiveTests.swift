import AVFoundation
import EnviousWisprAppKitTestSupport
import Foundation
import Testing

@testable import EnviousWisprAudio
@testable import EnviousWisprStorage

/// #3147 §3.1: when these fail, a user plays a dictation and hears nothing, a recording they
/// chose to keep loses its Keep mark, History shows the wrong reason for a missing recording,
/// or Settings reports less disk use than the recordings really take.
/// Real files in a temporary folder; nothing is stood in for.
@Suite("Recording archive", .tags(.productOutcome))
struct RecordingArchiveTests {

  private func folder() -> URL {
    TestTemporaryDirectory.url
      .appendingPathComponent("RecordingArchiveTests-\(UUID().uuidString)", isDirectory: true)
      .appendingPathComponent("dictations", isDirectory: true)
  }

  /// A finished encode waiting in the archive's own partial path.
  private func finishedEncode(_ archive: RecordingArchive, rowID: UUID, bytes: Int = 1_000)
    async throws
    -> URL
  {
    let url = try await archive.partialURL(for: rowID)
    #expect(FileManager.default.createFile(atPath: url.path, contents: Data(count: bytes)))
    return url
  }

  private func permissions(_ url: URL) throws -> Int {
    try #require(
      (FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?
        .intValue)
  }

  private let timing = RecordingTiming(
    exactASRText: "hello world", textVersion: "v1",
    anchors: [.init(utf16Start: 0, utf16End: 11, startSeconds: 0.2, endSeconds: 1.1)])

  @Test("a stored recording survives reopening, with its timings, privately")
  func storeAndReopen() async throws {
    let dir = folder()
    let row = UUID()
    let archive = RecordingArchive(directory: dir)
    try await archive.store(
      rowID: row, fileURL: try await finishedEncode(archive, rowID: row), timing: timing)

    let reopened = RecordingArchive(directory: dir)
    let audio = try #require(await reopened.url(for: row))
    #expect(try await reopened.timing(for: row) == timing)
    #expect(try await reopened.index() == [row])
    #expect(try permissions(dir) == 0o700)
    #expect(try permissions(audio) == 0o600)
    #expect(
      FileManager.default.fileExists(
        atPath: dir.appendingPathComponent(".metadata_never_index").path))
    // The partial file was moved into place, not copied.
    #expect(
      try FileManager.default.contentsOfDirectory(atPath: dir.path).allSatisfy {
        !$0.hasSuffix(".partial")
      })
  }

  @Test("storing again replaces the recording, drops stale timings and clears a recorded absence")
  func storeReplaces() async throws {
    let archive = RecordingArchive(directory: folder())
    let row = UUID()
    try await archive.store(
      rowID: row, fileURL: try await finishedEncode(archive, rowID: row), timing: timing)
    try await archive.recordAbsence(.saveFailed, for: row)
    try await archive.store(
      rowID: row, fileURL: try await finishedEncode(archive, rowID: row, bytes: 2_000), timing: nil)

    #expect(try await archive.timing(for: row) == nil)
    #expect(try await archive.absence(for: row) == nil)
    let audio = try #require(await archive.url(for: row))
    #expect(
      (try FileManager.default.attributesOfItem(atPath: audio.path)[.size] as? NSNumber) == 2_000)
  }

  @Test("deleting a recording records why, drops its Keep mark and survives reopening")
  func deleteRecordsReason() async throws {
    let dir = folder()
    let archive = RecordingArchive(directory: dir)
    let row = UUID()
    let other = UUID()
    for id in [row, other] {
      try await archive.store(
        rowID: id, fileURL: try await finishedEncode(archive, rowID: id), timing: timing)
      try await archive.pin(rowID: id)
    }

    try await archive.delete(rowID: row, reason: .deleted)

    let reopened = RecordingArchive(directory: dir)
    #expect(await reopened.url(for: row) == nil)
    #expect(try await reopened.timing(for: row) == nil)
    #expect(try await reopened.absence(for: row) == .deleted)
    #expect(try await reopened.pinnedRowIDs() == [other])
    #expect(try await reopened.index() == [other])
  }

  @Test("a deletion that fails leaves the recording, its Keep mark and no recorded reason")
  func failedDeleteChangesNothing() async throws {
    let dir = folder()
    let archive = RecordingArchive(directory: dir)
    let row = UUID()
    try await archive.store(
      rowID: row, fileURL: try await finishedEncode(archive, rowID: row), timing: nil)
    try await archive.pin(rowID: row)
    // A read-only folder: the file cannot be removed.
    try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: dir.path)
    defer {
      try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
    }

    await #expect(throws: (any Error).self) {
      try await archive.delete(rowID: row, reason: .deleted)
    }

    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
    #expect(await archive.url(for: row) != nil)
    #expect(try await archive.isPinned(row))
    #expect(try await archive.absence(for: row) == nil)
  }

  @Test("a replacement that cannot be published keeps the earlier recording, never with new timings")
  func failedStoreKeepsEarlierRecording() async throws {
    let archive = RecordingArchive(directory: folder())
    let row = UUID()
    try await archive.store(
      rowID: row, fileURL: try await finishedEncode(archive, rowID: row, bytes: 1_000), timing: timing)
    try await archive.recordAbsence(.saveFailed, for: row)
    // A locked file cannot be replaced.
    let earlier = try #require(await archive.url(for: row))
    try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: earlier.path)
    defer { try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: earlier.path) }
    let newer = RecordingTiming(exactASRText: nil, textVersion: "v2", anchors: [])

    await #expect(throws: (any Error).self) {
      try await archive.store(
        rowID: row, fileURL: try await finishedEncode(archive, rowID: row, bytes: 2_000), timing: newer)
    }

    #expect((try FileManager.default.attributesOfItem(atPath: earlier.path)[.size] as? NSNumber) == 1_000)
    #expect(try await archive.timing(for: row) == nil)
    #expect(try await archive.absence(for: row) == .saveFailed)
  }

  @Test("damaged metadata stops a deletion before the recording is removed")
  func damagedMetadataStopsDeletion() async throws {
    let dir = folder()
    let archive = RecordingArchive(directory: dir)
    let row = UUID()
    try await archive.store(rowID: row, fileURL: try await finishedEncode(archive, rowID: row), timing: timing)
    try Data("not json".utf8).write(to: dir.appendingPathComponent("pins.json"))

    await #expect(throws: RecordingArchive.ArchiveError.unreadableMetadata("pins.json")) {
      try await archive.delete(rowID: row, reason: .deleted)
    }
    await #expect(throws: RecordingArchive.ArchiveError.unreadableMetadata("pins.json")) {
      try await archive.forget(rowID: row)
    }
    #expect(await archive.url(for: row) != nil)
    #expect(try await archive.timing(for: row) == timing)
  }

  @Test("a timing file that cannot be removed leaves the recording playable and kept")
  func lockedTimingKeepsRecording() async throws {
    let dir = folder()
    let archive = RecordingArchive(directory: dir)
    let row = UUID()
    try await archive.store(rowID: row, fileURL: try await finishedEncode(archive, rowID: row), timing: timing)
    try await archive.pin(rowID: row)
    let timingFile = dir.appendingPathComponent("\(row.uuidString).timing.json")
    try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: timingFile.path)
    defer { try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: timingFile.path) }

    await #expect(throws: (any Error).self) { try await archive.delete(rowID: row, reason: .deleted) }

    #expect(await archive.url(for: row) != nil)
    #expect(try await archive.isPinned(row))
    #expect(try await archive.absence(for: row) == nil)
  }

  @Test("a dictation encoded into the archive's own partial path plays back after reopening")
  func encoderIntoArchiveRoundTrip() async throws {
    let dir = folder()
    let archive = RecordingArchive(directory: dir)
    let row = UUID()
    let samples = (0..<32_000).map { Float(sin(Double($0) * 2 * .pi * 440 / 16_000)) * 0.3 }
    // The real archive-generated name (`<id>.<uuid>.m4a.partial`), not renamed before encoding.
    let partial = try await archive.partialURL(for: row)
    let output = try SpeechAudioEncoder.encode(samples: samples, purpose: .dictation, to: partial)
    try await archive.store(rowID: row, fileURL: partial, timing: nil)

    let audio = try #require(await RecordingArchive(directory: dir).url(for: row))
    let file = try AVAudioFile(forReading: audio)
    #expect(file.fileFormat.streamDescription.pointee.mFormatID == kAudioFormatMPEG4AAC)
    #expect(file.fileFormat.sampleRate == 16_000)
    #expect(abs(file.length - Int64(samples.count)) <= SpeechAudioEncoder.durationToleranceFrames)
    #expect(file.length == output.frames)
  }

  @Test("Delete all removes every recording and records the reason for each")
  func deleteAll() async throws {
    let archive = RecordingArchive(directory: folder())
    let rows = [UUID(), UUID(), UUID()]
    for id in rows {
      try await archive.store(
        rowID: id, fileURL: try await finishedEncode(archive, rowID: id), timing: nil)
    }
    try await archive.pin(rowID: rows[0])

    #expect(try await archive.deleteAll(reason: .deleted) == 3)

    #expect(try await archive.index().isEmpty)
    #expect(try await archive.pinnedRowIDs().isEmpty)
    for id in rows { #expect(try await archive.absence(for: id) == .deleted) }
  }

  @Test("forgetting a deleted row removes its recording, Keep mark and recorded reason")
  func forget() async throws {
    let archive = RecordingArchive(directory: folder())
    let kept = UUID()
    let absent = UUID()
    try await archive.store(
      rowID: kept, fileURL: try await finishedEncode(archive, rowID: kept), timing: timing)
    try await archive.pin(rowID: kept)
    try await archive.recordAbsence(.recordingsOff, for: absent)

    try await archive.forget(rowID: kept)
    try await archive.forget(rowID: absent)

    #expect(await archive.url(for: kept) == nil)
    #expect(try await archive.pinnedRowIDs().isEmpty)
    #expect(try await archive.absence(for: absent) == nil)
  }

  @Test("a damaged Keep list is reported and never silently emptied")
  func damagedPinsAreNotOverwritten() async throws {
    let dir = folder()
    let archive = RecordingArchive(directory: dir)
    let row = UUID()
    try await archive.pin(rowID: row)
    let pins = dir.appendingPathComponent("pins.json")
    try Data("not json".utf8).write(to: pins)

    await #expect(throws: RecordingArchive.ArchiveError.unreadableMetadata("pins.json")) {
      try await archive.pin(rowID: UUID())
    }
    #expect(try Data(contentsOf: pins) == Data("not json".utf8))
  }

  @Test("disk use counts finished recordings and encodes in progress separately")
  func usageCountsPartials() async throws {
    let archive = RecordingArchive(directory: folder())
    #expect(try await archive.usage() == .init(committedBytes: 0, temporaryBytes: 0))
    let row = UUID()
    try await archive.store(
      rowID: row, fileURL: try await finishedEncode(archive, rowID: row, bytes: 1_000), timing: nil)
    _ = try await finishedEncode(archive, rowID: UUID(), bytes: 500)

    let usage = try await archive.usage()
    #expect(usage.committedBytes == 1_000)
    #expect(usage.temporaryBytes == 500)
  }

  @Test("an unlistable archive is a failure, never an empty archive")
  func unlistableIsNotEmpty() async throws {
    let dir = folder()
    try FileManager.default.createDirectory(
      at: dir.deletingLastPathComponent(), withIntermediateDirectories: true)
    #expect(FileManager.default.createFile(atPath: dir.path, contents: Data("file".utf8)))
    let archive = RecordingArchive(directory: dir)

    await #expect(throws: RecordingArchive.ArchiveError.unmeasurable) { try await archive.index() }
    await #expect(throws: RecordingArchive.ArchiveError.unmeasurable) { try await archive.usage() }
  }

  @Test("discarding an encode removes only that partial file inside the archive")
  func discardPartialIsNarrow() async throws {
    let dir = folder()
    let archive = RecordingArchive(directory: dir)
    let row = UUID()
    try await archive.store(rowID: row, fileURL: try await finishedEncode(archive, rowID: row), timing: nil)
    let partial = try await finishedEncode(archive, rowID: row)
    let outside = TestTemporaryDirectory.url.appendingPathComponent("\(UUID().uuidString).m4a.partial")
    #expect(FileManager.default.createFile(atPath: outside.path, contents: Data()))
    defer { try? FileManager.default.removeItem(at: outside) }

    try await archive.discardPartial(partial)
    try await archive.discardPartial(outside)
    try await archive.discardPartial(try #require(await archive.url(for: row)))

    #expect(!FileManager.default.fileExists(atPath: partial.path))
    #expect(FileManager.default.fileExists(atPath: outside.path))
    #expect(await archive.url(for: row) != nil)
  }

  @Test("launch cleanup removes interrupted encodes and keeps finished recordings")
  func removesInterruptedPartials() async throws {
    let archive = RecordingArchive(directory: folder())
    let row = UUID()
    try await archive.store(
      rowID: row, fileURL: try await finishedEncode(archive, rowID: row), timing: timing)
    _ = try await finishedEncode(archive, rowID: UUID())
    _ = try await finishedEncode(archive, rowID: row)

    #expect(try await archive.removeInterruptedPartials() == 2)

    #expect(try await archive.usage().temporaryBytes == 0)
    #expect(await archive.url(for: row) != nil)
    #expect(try await archive.timing(for: row) == timing)
  }
}
