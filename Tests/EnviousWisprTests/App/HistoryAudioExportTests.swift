import AVFoundation
import EnviousWisprAppKitTestSupport
import Foundation
import Testing

@testable import EnviousWisprAppKit
@testable import EnviousWisprAudio
@testable import EnviousWisprCore

/// #4799: when these fail, History's Save audio gives the customer a file that is the wrong
/// length, misses one side of a call, overwrites a file they never approved, leaves a
/// half-written file, or ends without telling them why. Real files and the real encoder; the
/// panel, Finder and the alert are replaced (nothing reaches the desktop).
@MainActor
@Suite("History Save audio", .tags(.productOutcome), .timeLimit(.minutes(1)))
struct HistoryAudioExportTests {
  /// Records what a save did outside the app.
  @MainActor final class Recorder {
    var destination: URL?
    var revealed: [URL] = []
    var notices: [HistoryAudioExport.Notice] = []
    var stagingDirectories: [URL] = []
    let root: URL

    init(root: URL) { self.root = root }

    /// Replaces the real replacement, to make it fail like Foundation can.
    var replace: (@MainActor (URL, URL) throws -> URL)?

    func effects() -> HistoryAudioExport.Effects {
      let staging = root.appendingPathComponent("staging", isDirectory: true)
      return HistoryAudioExport.Effects(
        chooseURL: { [self] _ in destination },
        reveal: { [self] in revealed.append($0) },
        notify: { [self] notice, _ in notices.append(notice) },
        makeStagingDirectory: { _ in
          let url = staging.appendingPathComponent(UUID().uuidString, isDirectory: true)
          try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
          return url
        },
        replace: { [self] destination, staged in
          if let replace { return try replace(destination, staged) }
          return try HistoryAudioExport.Effects.replaceFile(destination, staged)
        })
    }

    /// The production staging folder, recorded so a test can see it was removed.
    func liveStagingEffects(_ made: StagingLog) -> HistoryAudioExport.Effects {
      var effects = effects()
      effects.makeStagingDirectory = { destination in
        let url = try HistoryAudioExport.Effects.stagingDirectory(destination)
        made.append(url)
        return url
      }
      return effects
    }

    /// Every staging folder a save made; empty once each save finished.
    var leftoverStaging: [String] {
      let staging = root.appendingPathComponent("staging", isDirectory: true)
      return (try? FileManager.default.contentsOfDirectory(atPath: staging.path)) ?? []
    }
  }

  /// Staging folders made off the main actor.
  final class StagingLog: @unchecked Sendable {
    private let lock = NSLock()
    private var urls: [URL] = []
    func append(_ url: URL) { lock.withLock { urls.append(url) } }
    var all: [URL] { lock.withLock { urls } }
  }

  private func folder() throws -> URL {
    let url = TestTemporaryDirectory.url
      .appendingPathComponent("HistoryAudioExportTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  private static func mode(_ url: URL) throws -> Int? {
    (try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?
      .intValue
  }

  /// A finished "recording" file with private permissions, as the archive keeps it.
  private static func privateFile(_ bytes: String, at url: URL) throws {
    try Data(bytes.utf8).write(to: url)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
  }

  private static func dictationRequest(
    _ source: URL?,
    check: @escaping @MainActor () -> HistoryAudioExport.SourceCheck = {
      .deliverable
    }, admitted: @escaping @MainActor () -> Void = {}
  ) -> HistoryAudioExport.Request {
    HistoryAudioExport.Request(
      key: .dictation(UUID()), defaultName: "Dictation",
      admit: {
        admitted()
        return source.map { .file($0) }
      }, check: check)
  }

  // MARK: - Dictation copy

  @Test("a dictation is saved byte for byte as a normal user file and shown in Finder")
  func savesDictationCopy() async throws {
    let dir = try folder()
    let recorder = Recorder(root: dir)
    let made = StagingLog()
    // The real replacement folder, on the destination's own volume.
    let export = HistoryAudioExport(effects: recorder.liveStagingEffects(made))
    let source = dir.appendingPathComponent("archive.m4a")
    try Self.privateFile("dictation audio bytes", at: source)
    recorder.destination = dir.appendingPathComponent("Dictation.m4a")

    let outcome = await export.save(Self.dictationRequest(source))?.value

    let destination = try #require(recorder.destination)
    #expect(outcome == .saved(destination))
    #expect(try Data(contentsOf: destination) == Data("dictation audio bytes".utf8))
    #expect(try Self.mode(destination) == 0o644)
    #expect(recorder.revealed == [destination])
    #expect(recorder.notices.isEmpty)
    let staging = try #require(made.all.first)
    #expect(made.all.count == 1)
    #expect(FileManager.default.fileExists(atPath: staging.path) == false, "staging removed")
    #expect(try Data(contentsOf: source) == Data("dictation audio bytes".utf8), "source untouched")
  }

  @Test("Replace overwrites only the file the user approved, with normal permissions")
  func replacesApprovedFile() async throws {
    let dir = try folder()
    let recorder = Recorder(root: dir)
    let export = HistoryAudioExport(effects: recorder.effects())
    let source = dir.appendingPathComponent("archive.m4a")
    try Self.privateFile("new audio", at: source)
    let destination = dir.appendingPathComponent("Dictation.m4a")
    try Self.privateFile("old file the user agreed to replace", at: destination)
    recorder.destination = destination

    let outcome = await export.save(Self.dictationRequest(source))?.value

    #expect(outcome == .saved(destination))
    #expect(try Data(contentsOf: destination) == Data("new audio".utf8))
    #expect(try Self.mode(destination) == 0o644)
    #expect(recorder.leftoverStaging.isEmpty)
  }

  @Test("a file swapped in after the user approved Replace is never overwritten")
  func refusesSwappedTarget() async throws {
    let dir = try folder()
    let recorder = Recorder(root: dir)
    let export = HistoryAudioExport(effects: recorder.effects())
    let source = dir.appendingPathComponent("archive.m4a")
    try Self.privateFile("new audio", at: source)
    let destination = dir.appendingPathComponent("Dictation.m4a")
    try Self.privateFile("approved", at: destination)
    recorder.destination = destination

    let outcome = await export.save(
      Self.dictationRequest(
        source,
        admitted: {
          // Another app puts a different file at that path after the panel closed.
          try? FileManager.default.removeItem(at: destination)
          try? Data("someone else's file".utf8).write(to: destination)
        }))?.value

    #expect(outcome == .notSaved(.targetChanged))
    #expect(recorder.notices == [.targetChanged])
    #expect(try Data(contentsOf: destination) == Data("someone else's file".utf8))
    #expect(recorder.revealed.isEmpty)
    #expect(recorder.leftoverStaging.isEmpty)
  }

  @Test("a file that appears at an empty destination meanwhile is never overwritten")
  func refusesNewlyOccupiedPath() async throws {
    let dir = try folder()
    let recorder = Recorder(root: dir)
    let export = HistoryAudioExport(effects: recorder.effects())
    let source = dir.appendingPathComponent("archive.m4a")
    try Self.privateFile("new audio", at: source)
    let destination = dir.appendingPathComponent("Dictation.m4a")
    recorder.destination = destination

    let outcome = await export.save(
      Self.dictationRequest(
        source, admitted: { try? Data("arrived meanwhile".utf8).write(to: destination) }))?.value

    guard case .notSaved(.failed) = outcome else {
      Issue.record("expected a failed save, got \(String(describing: outcome))")
      return
    }
    #expect(try Data(contentsOf: destination) == Data("arrived meanwhile".utf8))
    #expect(recorder.notices.count == 1)
    #expect(recorder.leftoverStaging.isEmpty)
  }

  @Test("a recording deleted before the save finished saves nothing and says so")
  func deletedBeforeCommit() async throws {
    let dir = try folder()
    let recorder = Recorder(root: dir)
    let export = HistoryAudioExport(effects: recorder.effects())
    let source = dir.appendingPathComponent("archive.m4a")
    try Self.privateFile("audio", at: source)
    let destination = dir.appendingPathComponent("Dictation.m4a")
    recorder.destination = destination

    let deleted = await export.save(Self.dictationRequest(source, check: { .deleted }))?.value
    let changed = await export.save(Self.dictationRequest(source, check: { .changed }))?.value

    #expect(deleted == .notSaved(.deleted))
    #expect(changed == .notSaved(.changed))
    #expect(recorder.notices == [.deleted, .changed])
    #expect(FileManager.default.fileExists(atPath: destination.path) == false)
    #expect(recorder.leftoverStaging.isEmpty)
  }

  @Test("no audio to save after the panel: told, nothing written; a cancelled panel says nothing")
  func unavailableAndCancelled() async throws {
    let dir = try folder()
    let recorder = Recorder(root: dir)
    let export = HistoryAudioExport(effects: recorder.effects())
    recorder.destination = dir.appendingPathComponent("Dictation.m4a")

    #expect(await export.save(Self.dictationRequest(nil))?.value == .notSaved(.unavailable))
    #expect(recorder.notices == [.unavailable], "told even with no view left to show it")

    recorder.destination = nil
    #expect(await export.save(Self.dictationRequest(nil))?.value == .cancelled)
    #expect(recorder.notices == [.unavailable], "cancelling is silent")

    recorder.destination = dir.appendingPathComponent("Dictation.txt")
    guard case .notSaved(.failed) = await export.save(Self.dictationRequest(nil))?.value else {
      Issue.record("a destination that is not M4A is refused")
      return
    }
  }

  @Test("a second press while the item is saving starts nothing; the claim ends with the save")
  func duplicatePress() async throws {
    let dir = try folder()
    let recorder = Recorder(root: dir)
    let export = HistoryAudioExport(effects: recorder.effects())
    let source = dir.appendingPathComponent("archive.m4a")
    try Self.privateFile("audio", at: source)
    recorder.destination = dir.appendingPathComponent("Dictation.m4a")
    let id = UUID()
    let request = HistoryAudioExport.Request(
      key: .dictation(id), defaultName: "Dictation", admit: { .file(source) },
      check: { .deliverable })

    let first = try #require(export.save(request))
    #expect(export.isExporting(.dictation(id)))
    #expect(export.save(request) == nil, "the claim is taken before the panel")
    #expect(export.isExporting(.dictation(UUID())) == false)
    _ = await first.value
    #expect(export.isExporting(.dictation(id)) == false)
  }

  /// A replacement that fails the way Foundation can: it moved the user's file into the staging
  /// folder, then threw naming where it left it.
  private static func failingReplace(occupyDestination: Bool) -> @MainActor (URL, URL) throws
    -> URL
  {
    { destination, staged in
      let aside = staged.deletingLastPathComponent().appendingPathComponent("original-aside.m4a")
      try FileManager.default.moveItem(at: destination, to: aside)
      if occupyDestination { try Data("arrived meanwhile".utf8).write(to: destination) }
      throw NSError(
        domain: NSCocoaErrorDomain, code: NSFileWriteUnknownError,
        userInfo: ["NSFileOriginalItemLocationKey": aside])
    }
  }

  @Test("a failed Replace that moved the user's file aside puts it back and says it failed")
  func failedReplaceRestoresOriginal() async throws {
    let dir = try folder()
    let recorder = Recorder(root: dir)
    let export = HistoryAudioExport(effects: recorder.effects())
    let source = dir.appendingPathComponent("archive.m4a")
    try Self.privateFile("new audio", at: source)
    let destination = dir.appendingPathComponent("Dictation.m4a")
    try Self.privateFile("the user's file", at: destination)
    recorder.destination = destination
    recorder.replace = Self.failingReplace(occupyDestination: false)

    let outcome = await export.save(Self.dictationRequest(source))?.value

    guard case .notSaved(.failed) = outcome else {
      Issue.record("expected a failed save, got \(String(describing: outcome))")
      return
    }
    #expect(try Data(contentsOf: destination) == Data("the user's file".utf8))
    #expect(recorder.leftoverStaging.isEmpty)
    #expect(recorder.revealed.isEmpty)
  }

  @Test("a moved-aside original that cannot be put back is kept, never deleted with staging")
  func failedReplaceKeepsUnrestorableOriginal() async throws {
    let dir = try folder()
    let recorder = Recorder(root: dir)
    let export = HistoryAudioExport(effects: recorder.effects())
    let source = dir.appendingPathComponent("archive.m4a")
    try Self.privateFile("new audio", at: source)
    let destination = dir.appendingPathComponent("Dictation.m4a")
    try Self.privateFile("the user's file", at: destination)
    recorder.destination = destination
    recorder.replace = Self.failingReplace(occupyDestination: true)

    let outcome = await export.save(Self.dictationRequest(source))?.value

    guard case .notSaved(.failed) = outcome else {
      Issue.record("expected a failed save, got \(String(describing: outcome))")
      return
    }
    // The file that took the destination is not overwritten; the user's file is put beside
    // it where they can find it, and nothing is left in staging.
    #expect(try Data(contentsOf: destination) == Data("arrived meanwhile".utf8))
    let beside = dir.appendingPathComponent("Dictation (original).m4a")
    #expect(try Data(contentsOf: beside) == Data("the user's file".utf8))
    // Shown in Finder so the user can find it; nothing is left in staging.
    #expect(recorder.revealed.map(\.lastPathComponent) == ["Dictation (original).m4a"])
    #expect(recorder.leftoverStaging.isEmpty)
  }

  @Test("a meeting deleted while its audio is being mixed is reported deleted (#4799)")
  func deletedWhileMixing() async throws {
    let dir = try folder()
    let recorder = Recorder(root: dir)
    let export = HistoryAudioExport(effects: recorder.effects())
    let broken = dir.appendingPathComponent("mic-00001-s000000000.caf")
    try Data("not audio".utf8).write(to: broken)
    recorder.destination = dir.appendingPathComponent("Meeting.m4a")

    // Staging fails (no readable audio, as when the files were deleted mid-mix) and the owner
    // reports the meeting deleted: the user hears why, not a generic failure.
    let outcome = await export.save(
      HistoryAudioExport.Request(
        key: .meeting(UUID()), defaultName: "Meeting",
        admit: { .meeting(files: [.microphone: [(broken, 0)]], durationMs: 1_000) },
        check: { .deleted }))?.value

    #expect(outcome == .notSaved(.deleted))
    #expect(recorder.notices == [.deleted])
  }

  @Test("a quit stops a save in flight: nothing published, nothing said, no new save starts")
  func quitCancelsSave() async throws {
    let dir = try folder()
    let recorder = Recorder(root: dir)
    let export = HistoryAudioExport(effects: recorder.effects())
    let meeting = dir.appendingPathComponent("meeting", isDirectory: true)
    try FileManager.default.createDirectory(at: meeting, withIntermediateDirectories: true)
    let mic = try Self.writeTone(440, seconds: 1, in: meeting, track: .microphone, startMs: 0)
    let destination = dir.appendingPathComponent("Meeting.m4a")
    recorder.destination = destination
    // The quit lands while the save is admitted, before staging starts.
    var request: HistoryAudioExport.Request!
    request = HistoryAudioExport.Request(
      key: .meeting(UUID()), defaultName: "Meeting",
      admit: { [export] in
        export.cancelAll()
        return .meeting(files: [.microphone: [(mic, 0)]], durationMs: 60_000)
      }, check: { .deliverable })

    let outcome = await export.save(request)?.value

    #expect(outcome == .abandoned)
    #expect(FileManager.default.fileExists(atPath: destination.path) == false)
    #expect(recorder.notices.isEmpty)
    #expect(recorder.revealed.isEmpty)
    #expect(recorder.leftoverStaging.isEmpty)
    #expect(export.save(request) == nil, "no new save after the quit")
  }

  @Test("a quit before the panel opens, or during an admission that finds nothing, stays silent")
  func quitBeforePanelAndDuringEmptyAdmission() async throws {
    let dir = try folder()
    let recorder = Recorder(root: dir)
    let destination = dir.appendingPathComponent("Dictation.m4a")
    recorder.destination = destination
    var panels = 0
    var effects = recorder.effects()
    effects.chooseURL = { _ in
      panels += 1
      return destination
    }

    // Started, then the quit lands before the task first runs: no panel.
    let queued = HistoryAudioExport(effects: effects)
    let task = try #require(queued.save(Self.dictationRequest(nil)))
    queued.cancelAll()
    #expect(await task.value == .abandoned)
    #expect(panels == 0)

    // The quit lands while admission runs and admission then finds no audio: no alert.
    let admitting = HistoryAudioExport(effects: effects)
    let outcome = await admitting.save(
      HistoryAudioExport.Request(
        key: .dictation(UUID()), defaultName: "Dictation",
        admit: { [admitting] in
          admitting.cancelAll()
          return nil
        }, check: { .deliverable }))?.value
    #expect(outcome == .abandoned)
    #expect(recorder.notices.isEmpty)
    #expect(FileManager.default.fileExists(atPath: destination.path) == false)
  }

  // MARK: - Meeting mix

  /// A 16 kHz mono 16-bit segment holding a sine of `hertz`.
  private static func writeTone(
    _ hertz: Double, seconds: Double, in folder: URL, track: MeetingTrackKind, startMs: Int
  ) throws -> URL {
    let url = folder.appendingPathComponent(
      MeetingSegmentNaming.fileName(
        track: track, variant: .raw, index: 1, startMs: startMs, partial: false))
    let frames = Int(seconds * 16_000)
    let file = try AVAudioFile(
      forWriting: url,
      settings: [
        AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16_000.0, AVNumberOfChannelsKey: 1,
        AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
      ],
      commonFormat: .pcmFormatFloat32, interleaved: false)
    let buffer = try #require(
      AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(frames)))
    buffer.frameLength = AVAudioFrameCount(frames)
    for i in 0..<frames {
      buffer.floatChannelData![0][i] = Float(sin(Double(i) * 2 * .pi * hertz / 16_000)) * 0.3
    }
    try file.write(from: buffer)
    return url
  }

  /// The whole decoded file.
  private static func decode(_ url: URL) throws -> [Float] {
    let file = try AVAudioFile(forReading: url)
    let buffer = try #require(
      AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 65_536))
    var samples: [Float] = []
    while file.framePosition < file.length {
      try file.read(into: buffer, frameCount: 65_536)
      if buffer.frameLength == 0 { break }
      samples.append(
        contentsOf: UnsafeBufferPointer(
          start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
    }
    return samples
  }

  /// Goertzel power of `hertz` over `samples[range]`, normalised by length.
  private static func power(_ samples: [Float], _ range: Range<Int>, hertz: Double) -> Double {
    let k = 2 * cos(2 * .pi * hertz / 16_000)
    var s1 = 0.0
    var s2 = 0.0
    for i in range {
      let s0 = Double(samples[i]) + k * s1 - s2
      s2 = s1
      s1 = s0
    }
    return (s1 * s1 + s2 * s2 - k * s1 * s2) / Double(range.count * range.count)
  }

  @Test("a meeting is saved as one file of its full length with each side where it spoke")
  func savesMeetingMix() async throws {
    let dir = try folder()
    let recorder = Recorder(root: dir)
    let export = HistoryAudioExport(effects: recorder.effects())
    let meeting = dir.appendingPathComponent("meeting", isDirectory: true)
    try FileManager.default.createDirectory(at: meeting, withIntermediateDirectories: true)
    // Microphone 440 Hz from 0 to 1.5 s; call sound 1000 Hz from 0.5 to 4.5 s; the meeting
    // lasts 5 s, so its last half second is silence. 5 s crosses one encoder window
    // (65,536 samples = 4.096 s).
    let mic = try Self.writeTone(440, seconds: 1.5, in: meeting, track: .microphone, startMs: 0)
    let call = try Self.writeTone(
      1_000, seconds: 4, in: meeting, track: .callSound, startMs: 500)
    recorder.destination = dir.appendingPathComponent("Customer call.m4a")

    let outcome = await export.save(
      HistoryAudioExport.Request(
        key: .meeting(UUID()), defaultName: "Customer call",
        admit: {
          .meeting(files: [.microphone: [(mic, 0)], .callSound: [(call, 500)]], durationMs: 5_000)
        }, check: { .deliverable }))?.value

    let destination = try #require(recorder.destination)
    #expect(outcome == .saved(destination))
    #expect(recorder.notices.isEmpty)
    let samples = try Self.decode(destination)
    #expect(abs(samples.count - 80_000) <= 800, "5 s at 16 kHz, within 50 ms")
    // 0.1-0.4 s: only the microphone.
    let early = 1_600..<6_400
    #expect(Self.power(samples, early, hertz: 440) > 100 * Self.power(samples, early, hertz: 1_000))
    // 1.7-2.4 s: only the call sound.
    let late = 27_200..<38_400
    #expect(Self.power(samples, late, hertz: 1_000) > 100 * Self.power(samples, late, hertz: 440))
    // 0.6-1.4 s: both.
    let both = 9_600..<22_400
    #expect(Self.power(samples, both, hertz: 440) > 0.001)
    #expect(Self.power(samples, both, hertz: 1_000) > 0.001)
    // 4.2-4.4 s, after the first encoder window: still only the call sound.
    let afterWindow = 67_200..<70_400
    #expect(
      Self.power(samples, afterWindow, hertz: 1_000)
        > 100 * Self.power(samples, afterWindow, hertz: 440))
    // 4.6-4.95 s: the short tail is silence.
    let tail = samples[73_600..<min(79_200, samples.count)]
    #expect(tail.allSatisfy { abs($0) < 0.01 })
    #expect(try Self.mode(destination) == 0o644)
    #expect(recorder.leftoverStaging.isEmpty)
  }

  @Test(
    "a listed meeting file that cannot be read is silent in the saved file, and the user is told")
  func meetingWithUnreadablePart() async throws {
    let dir = try folder()
    let recorder = Recorder(root: dir)
    let export = HistoryAudioExport(effects: recorder.effects())
    let meeting = dir.appendingPathComponent("meeting", isDirectory: true)
    try FileManager.default.createDirectory(at: meeting, withIntermediateDirectories: true)
    let mic = try Self.writeTone(440, seconds: 1, in: meeting, track: .microphone, startMs: 0)
    let broken = meeting.appendingPathComponent(
      MeetingSegmentNaming.fileName(
        track: .callSound, variant: .raw, index: 1, startMs: 0, partial: false))
    try Data("not audio".utf8).write(to: broken)
    recorder.destination = dir.appendingPathComponent("Meeting.m4a")

    let outcome = await export.save(
      HistoryAudioExport.Request(
        key: .meeting(UUID()), defaultName: "Meeting",
        admit: {
          .meeting(files: [.microphone: [(mic, 0)], .callSound: [(broken, 0)]], durationMs: 1_000)
        }, check: { .deliverable }))?.value

    let destination = try #require(recorder.destination)
    #expect(outcome == .saved(destination))
    #expect(recorder.revealed == [destination])
    #expect(recorder.notices == [.partlySilent])
  }

  @Test("a meeting with no readable file saves nothing and says so")
  func meetingWithNothingReadable() async throws {
    let dir = try folder()
    let recorder = Recorder(root: dir)
    let export = HistoryAudioExport(effects: recorder.effects())
    let broken = dir.appendingPathComponent("mic-00001-s000000000.caf")
    try Data("not audio".utf8).write(to: broken)
    let destination = dir.appendingPathComponent("Meeting.m4a")
    recorder.destination = destination

    let outcome = await export.save(
      HistoryAudioExport.Request(
        key: .meeting(UUID()), defaultName: "Meeting",
        admit: { .meeting(files: [.microphone: [(broken, 0)]], durationMs: 1_000) },
        check: { .deliverable }))?.value

    guard case .notSaved(.failed) = outcome else {
      Issue.record("expected a failed save, got \(String(describing: outcome))")
      return
    }
    #expect(FileManager.default.fileExists(atPath: destination.path) == false)
    #expect(recorder.leftoverStaging.isEmpty)
  }
}
