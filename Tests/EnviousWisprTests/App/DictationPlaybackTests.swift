import AVFoundation
import EnviousWisprAppKitTestSupport
import Foundation
import Testing

@testable import EnviousWisprAppKit
@testable import EnviousWisprAudio
@testable import EnviousWisprCore
@testable import EnviousWisprStorage

/// #3147 PR1 playback: when these fail, playing a saved dictation plays the wrong stretch, cuts
/// off its end, plays past it, two recordings play over each other, or History shows the wrong
/// reason for a missing recording. Real Apple AAC files made by the production encoder; a fake
/// output, so nothing reaches a speaker.
@MainActor
@Suite("Dictation recording playback", .tags(.productOutcome), .timeLimit(.minutes(1)))
struct DictationPlaybackTests {
  typealias FakeOutput = MeetingPlaybackControllerTests.FakeOutput

  /// A recognisable ramp, so a window read from the wrong place shows.
  static func ramp(_ count: Int) -> [Float] {
    (0..<count).map { Float(sin(Double($0) * 2 * .pi * 300 / 16_000)) * 0.4 }
  }

  private func encoded(seconds: Double) throws -> (url: URL, samples: [Float]) {
    let dir = TestTemporaryDirectory.url
      .appendingPathComponent("DictationPlaybackTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let samples = Self.ramp(Int(seconds * 16_000))
    let url = dir.appendingPathComponent("take.m4a")
    _ = try SpeechAudioEncoder.encode(samples: samples, purpose: .dictation, to: url)
    return (url, samples)
  }

  /// The whole file decoded in one read: the independent reference windows are compared with.
  private func decodedWhole(_ url: URL) throws -> [Float] {
    let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
    let buffer = try #require(
      AVAudioPCMBuffer(
        pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
    try file.read(into: buffer)
    return Array(
      UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
  }

  @Test(
    "a saved recording's windows match the decoded file at any position, with silence past the end")
  func aacWindowsMatchTheFile() throws {
    let (url, samples) = try encoded(seconds: 2)
    let audio = try DictationPlaybackAudio(url: url)
    let whole = try decodedWhole(url)

    #expect(abs(Int(audio.frames) - samples.count) <= 800, "length within 50 ms of the take")
    #expect(audio.durationMs == Int(audio.frames) / 16)
    // A window in the middle, read after the start (a seek), equals the same stretch of a whole read.
    let middle = try audio.window(startMs: 700, count: 250)
    #expect(middle.count == 250 * 16)
    for i in stride(from: 0, to: middle.count, by: 97) {
      #expect(abs(middle[i] - whole[700 * 16 + i]) < 1e-4, "sample \(i) of the 700 ms window")
    }
    // The first window, read after a later one, is still right (positions are absolute).
    let first = try audio.window(startMs: 0, count: 100)
    #expect(abs(first[50] - whole[50]) < 1e-4)
    // A window running past the end is the file's last samples, then silence.
    let endMs = audio.durationMs - 100
    let tail = try audio.window(startMs: endMs, count: 250)
    #expect(tail.count == 250 * 16)
    #expect(tail[(100 * 16 + 10)...].allSatisfy { $0 == 0 })
  }

  @Test("a dictation player plays its recording window by window and finishes at the file's end")
  func playerPlaysADictation() async throws {
    let (url, _) = try encoded(seconds: 1)
    let durationMs = try DictationPlaybackAudio(url: url).durationMs
    let output = FakeOutput()
    let player = MeetingPlaybackController(
      media: .dictation(url), durationMs: durationMs, output: output, windowMs: 250)

    player.play()
    let windows = (durationMs + 249) / 250
    for n in 0..<windows {
      await MeetingCoordinatorTests.eventually("window \(n + 1) queued") { output.windows.count > n }
      output.playNext()
    }
    #expect(player.state == .finished)
    #expect(player.positionMs == durationMs)
    player.play()
    #expect(player.positionMs == 0, "Play at the end starts over")
    player.stop()
  }

  @Test("starting one recording pauses the one that was playing")
  func oneRecordingPlaysAtATime() async throws {
    let arbiter = PlaybackArbiter()
    let silent: MeetingPlaybackController.Reader = { _, loaded, _, count in
      (loaded ?? (SilentAudio() as any PlaybackWindowAudio), [Float](repeating: 0, count: count * 16))
    }
    let first = MeetingPlaybackController(
      media: .dictation(URL(filePath: "/dev/null")), durationMs: 5_000, output: FakeOutput(),
      read: silent, sourceID: .dictation(UUID()), arbiter: arbiter)
    let second = MeetingPlaybackController(
      media: .meeting([:]), durationMs: 5_000, output: FakeOutput(), read: silent,
      sourceID: .meeting(UUID()), arbiter: arbiter)

    first.play()
    #expect(first.state == .playing)
    second.play()
    #expect(first.state == .paused)
    #expect(second.state == .playing)
    first.play()
    #expect(second.state == .paused)
    first.stop()
    second.stop()
  }

  @Test("a deletion stops every player of that recording for good, and only that recording")
  func deletionStopsOnlyThatRecording() async throws {
    let arbiter = PlaybackArbiter()
    let silent: MeetingPlaybackController.Reader = { _, loaded, _, count in
      (loaded ?? (SilentAudio() as any PlaybackWindowAudio), [Float](repeating: 0, count: count * 16))
    }
    let row = UUID()
    let other = UUID()
    let output = FakeOutput()
    let deleted = MeetingPlaybackController(
      media: .dictation(URL(filePath: "/dev/null")), durationMs: 5_000, output: output,
      read: silent, sourceID: .dictation(row), arbiter: arbiter)
    let kept = MeetingPlaybackController(
      media: .dictation(URL(filePath: "/dev/null")), durationMs: 5_000, output: FakeOutput(),
      read: silent, sourceID: .dictation(other), arbiter: arbiter)
    deleted.play()
    let before = arbiter.deletionCount(for: .dictation(row))

    arbiter.stopForDeletion(.dictation(row))

    #expect(deleted.state == .unavailable)
    #expect(output.stops >= 1, "the output stopped before any file could go")
    deleted.play()
    #expect(deleted.state == .unavailable, "a deleted recording never plays again")
    #expect(kept.state == .idle)
    #expect(arbiter.deletionCount(for: .dictation(row)) == before + 1, "earlier lookups are stale")
    // Delete All: every dictation player stops and every earlier dictation lookup is stale.
    let epoch = arbiter.dictationEpoch
    arbiter.stopAllDictationsForDeletion()
    #expect(kept.state == .unavailable)
    #expect(arbiter.dictationEpoch == epoch + 1)
  }

  @Test("every recorded reason has its own line; an unexplained absence never guesses")
  func absenceLines() {
    var seen: Set<String> = []
    for reason in RecordingAbsence.allCases {
      seen.insert(String(localized: DictationRecordingSection.absenceLine(reason)))
    }
    let unexplained = String(localized: DictationRecordingSection.absenceLine(nil))
    #expect(seen.count == RecordingAbsence.allCases.count, "one distinct line per reason")
    #expect(unexplained == "Recording unavailable.")
    #expect(!seen.contains(unexplained))
    #expect(
      String(localized: DictationRecordingSection.absenceLine(.saveFailed))
        == "Recording couldn't be saved.", "an encoder failure is never described as recordings off"
    )
  }

  /// Answers silence for any window, for players whose audio this test does not read.
  final class SilentAudio: PlaybackWindowAudio, @unchecked Sendable {
    func window(startMs: Int, count: Int) throws -> [Float] {
      [Float](repeating: 0, count: count * 16)
    }
  }
}
