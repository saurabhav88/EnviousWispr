import Foundation
import Testing

@testable import EnviousWisprAppKit
@testable import EnviousWisprAudio
@testable import EnviousWisprCore

/// #3972 C5 (items 29-31): when these fail, meeting playback plays the wrong stretch, plays a
/// gap as noise or skips it, mixes the two tracks out of step, keeps playing a stretch from
/// before a seek or a pause, never finishes, or plays on after the audio was deleted. Real
/// segment files, a fake output: nothing reaches a speaker.
@MainActor
@Suite("Meeting playback", .tags(.productOutcome), .timeLimit(.minutes(1)))
struct MeetingPlaybackControllerTests {
  /// Records what the controller queues and plays a window only when the test says so.
  @MainActor
  @Observable
  final class FakeOutput: MeetingPlaybackOutput {
    private(set) var windows: [[Float]] = []
    @ObservationIgnored private var pending: [@MainActor () -> Void] = []
    /// Completions of windows dropped by `stop()`, which a real player may still deliver.
    @ObservationIgnored private var stale: [@MainActor () -> Void] = []
    private(set) var starts = 0
    private(set) var stops = 0
    var failStart = false

    struct StartFailed: Error {}

    func start() throws {
      if failStart { throw StartFailed() }
      starts += 1
    }

    func enqueue(_ samples: [Float], played: @escaping @MainActor () -> Void) {
      windows.append(samples)
      pending.append(played)
    }

    func stop() {
      stops += 1
      stale += pending
      pending = []
    }

    /// The oldest queued window finishes playing.
    func playNext() {
      guard !pending.isEmpty else { return }
      pending.removeFirst()()
    }

    /// Delivers the completions of windows a stop dropped.
    func playStale() {
      let calls = stale
      stale = []
      calls.forEach { $0() }
    }
  }

  static let rate = 16
  static func value(_ i: Int, seed: Int) -> Float { MeetingAudioFixture.value(i, seed: seed) }

  func eventually(_ label: String, _ condition: @escaping @MainActor () -> Bool) async {
    await MeetingCoordinatorTests.eventually(label, condition)
  }

  @Test("plays a track's audio window by window, in order, and finishes at its end")
  func playsInOrder() async throws {
    let folder = try MeetingAudioFixture.folder("playback")
    let mic = try MeetingAudioFixture.writeSegment(in: folder, index: 1, startMs: 0, frames: 16_000)
    let output = FakeOutput()
    let player = MeetingPlaybackController(
      files: [.microphone: [(mic, 0)]], durationMs: 1_000, output: output, windowMs: 250)
    player.play()
    #expect(player.state == .playing)
    await eventually("two queued") { output.windows.count == 2 }
    // The first window is the file's first 250 ms, sample for sample.
    #expect(output.windows[0].count == 250 * Self.rate)
    #expect(abs(output.windows[0][100] - Self.value(100, seed: 0)) <= MeetingAudioFixture.tolerance)
    #expect(abs(output.windows[1][0] - Self.value(4_000, seed: 0)) <= MeetingAudioFixture.tolerance)
    output.playNext()
    #expect(player.positionMs == 250)
    await eventually("third queued") { output.windows.count == 3 }
    output.playNext()
    #expect(player.positionMs == 500)
    await eventually("fourth queued") { output.windows.count == 4 }
    output.playNext()
    output.playNext()
    #expect(player.positionMs == 1_000)
    #expect(player.state == .finished)
    #expect(output.windows.count == 4, "never more than the meeting")
    // Play after the end starts again from the beginning.
    player.play()
    #expect(player.positionMs == 0)
    #expect(player.state == .playing)
    player.stop()
  }

  @Test("both tracks are mixed on one timeline; a gap plays as silence")
  func twoTracksAndGaps() async throws {
    let folder = try MeetingAudioFixture.folder("playback-mix")
    let mic = try MeetingAudioFixture.writeSegment(in: folder, index: 1, startMs: 0, frames: 8_000)
    let call = try MeetingAudioFixture.writeSegment(
      in: folder, track: .callSound, index: 1, startMs: 0, frames: 16_000, seed: 1)
    let output = FakeOutput()
    let player = MeetingPlaybackController(
      files: [.microphone: [(mic, 0)], .callSound: [(call, 0)]], durationMs: 1_500,
      output: output, windowMs: 500)
    player.play()
    await eventually("two queued") { output.windows.count == 2 }
    let i = 1_234
    #expect(
      abs(output.windows[0][i] - (Self.value(i, seed: 0) + Self.value(i, seed: 1)))
        <= 2 * MeetingAudioFixture.tolerance)
    // 500..1000 ms: the microphone file ended, the call sound goes on.
    #expect(
      abs(output.windows[1][10] - Self.value(8_010, seed: 1)) <= MeetingAudioFixture.tolerance)
    output.playNext()
    await eventually("third queued") { output.windows.count == 3 }
    // 1000..1500 ms: no file covers it on either track.
    #expect(output.windows[2].allSatisfy { $0 == 0 })
    player.stop()
  }

  @Test("a seek or a pause fences every window and completion from before it")
  func seekAndPauseFence() async throws {
    let folder = try MeetingAudioFixture.folder("playback-seek")
    let mic = try MeetingAudioFixture.writeSegment(in: folder, index: 1, startMs: 0, frames: 32_000)
    let output = FakeOutput()
    let player = MeetingPlaybackController(
      files: [.microphone: [(mic, 0)]], durationMs: 2_000, output: output, windowMs: 250)
    player.play()
    await eventually("two queued") { output.windows.count == 2 }
    player.seek(toMs: 1_500)
    #expect(player.positionMs == 1_500)
    output.playStale()
    #expect(player.positionMs == 1_500, "a window from before the seek moves nothing")
    await eventually("queued after seek") { output.windows.count == 4 }
    #expect(
      abs(output.windows[2][0] - Self.value(24_000, seed: 0)) <= MeetingAudioFixture.tolerance)

    player.pause()
    #expect(player.state == .paused)
    output.playStale()
    #expect(player.positionMs == 1_500)
    // Scrubbing while paused moves the position and stays paused.
    player.seek(toMs: 250)
    #expect(player.state == .paused)
    #expect(player.positionMs == 250)
    player.play()
    await eventually("resumed") { output.windows.count == 6 }
    #expect(abs(output.windows[4][0] - Self.value(4_000, seed: 0)) <= MeetingAudioFixture.tolerance)
    // Seeks are clamped to the meeting; a seek to the end while playing finishes.
    player.seek(toMs: 99_999)
    #expect(player.positionMs == 2_000)
    #expect(player.state == .finished)
    player.seek(toMs: -5)
    #expect(player.positionMs == 0)
    #expect(player.state == .paused)
    // A seek while playing restarts the output the stop emptied.
    let startsBefore = output.starts
    player.play()
    player.seek(toMs: 500)
    #expect(output.starts == startsBefore + 2)
    player.stop()
  }

  /// Holds each window read until the test releases it, so the test decides which lands first.
  @MainActor
  @Observable
  final class ReadGates {
    private(set) var parked: Set<Int> = []
    /// Reads that entered and have not finished; 0 after `shutdown` once every read is done.
    private(set) var inFlight = 0
    @ObservationIgnored private var waiting: [Int: CheckedContinuation<Void, Never>] = [:]
    @ObservationIgnored private var closed = false

    func wait(_ startMs: Int) async {
      guard !closed else { return }
      await withCheckedContinuation { continuation in
        waiting[startMs] = continuation
        parked.insert(startMs)
      }
    }

    func release(_ startMs: Int) {
      parked.remove(startMs)
      waiting.removeValue(forKey: startMs)?.resume()
    }

    /// Releases every parked read and lets later ones through, so no read outlives the test.
    func shutdown() {
      closed = true
      for startMs in Array(waiting.keys) { release(startMs) }
    }

    /// The real window reader behind this gate, counted in `inFlight`.
    func reader() -> MeetingPlaybackController.Reader {
      { files, loaded, startMs, count in
        await self.enter()
        await self.wait(startMs)
        do {
          let result = try await MeetingPlaybackController.readWindow(files, loaded, startMs, count)
          await self.leave()
          return result
        } catch {
          await self.leave()
          throw error
        }
      }
    }

    private func enter() { inFlight += 1 }
    private func leave() { inFlight -= 1 }
  }

  /// Ends a gated test: stops the player, lets every parked read finish, and waits until none
  /// is left running.
  func finish(_ player: MeetingPlaybackController, _ gates: ReadGates) async {
    player.stop()
    gates.shutdown()
    await eventually("every read finished") { gates.inFlight == 0 }
  }

  @Test("a window read that lands after a seek is dropped and the new place is read next")
  func lateReadAfterSeek() async throws {
    let folder = try MeetingAudioFixture.folder("playback-late")
    let mic = try MeetingAudioFixture.writeSegment(in: folder, index: 1, startMs: 0, frames: 32_000)
    let output = FakeOutput()
    let gates = ReadGates()
    let player = MeetingPlaybackController(
      files: [.microphone: [(mic, 0)]], durationMs: 2_000, output: output, windowMs: 250,
      read: gates.reader())
    player.play()
    player.seek(toMs: 1_500)
    // One read at a time: the read from before the seek is still the only one running.
    await eventually("old read parked") { gates.parked == [0] }
    gates.release(0)
    // It lands after the seek: dropped, nothing queued, and the new place is read next.
    await eventually("stale read dropped") { player.staleReadsDropped == 1 && gates.parked == [1_500] }
    #expect(output.windows.isEmpty)
    gates.release(1_500)
    await eventually("new window queued") {
      output.windows.count == 1 && gates.parked.contains(1_750)
    }
    #expect(abs(output.windows[0][0] - Self.value(24_000, seed: 0)) <= MeetingAudioFixture.tolerance)
    gates.release(1_750)
    await eventually("second window queued") { output.windows.count == 2 }
    #expect(abs(output.windows[1][0] - Self.value(28_000, seed: 0)) <= MeetingAudioFixture.tolerance)
    output.playNext()
    output.playNext()
    #expect(player.state == .finished)
    #expect(player.positionMs == 2_000)
    #expect(output.windows.count == 2)
    await finish(player, gates)
  }

  @Test("no readable audio is unavailable; one damaged file plays as silence")
  func missingAndDamagedFiles() async throws {
    let folder = try MeetingAudioFixture.folder("playback-missing")
    let gone = folder.appendingPathComponent("mic-00001-s000000000.caf")
    let none = FakeOutput()
    let empty = MeetingPlaybackController(
      files: [.microphone: [(gone, 0)]], durationMs: 1_000, output: none, windowMs: 250)
    empty.play()
    await eventually("unavailable") { empty.state == .unavailable }
    #expect(none.windows.isEmpty)
    empty.play()
    #expect(empty.state == .unavailable, "it never tries again")

    let good = try MeetingAudioFixture.writeSegment(
      in: folder, index: 2, startMs: 500, frames: 8_000)
    let damaged = folder.appendingPathComponent("mic-00003-s000001000.caf")
    try Data(repeating: 7, count: 512).write(to: damaged)
    let output = FakeOutput()
    let player = MeetingPlaybackController(
      files: [.microphone: [(gone, 0), (good, 500), (damaged, 1_000)]], durationMs: 1_500,
      output: output, windowMs: 500)
    player.play()
    await eventually("two queued") { output.windows.count == 2 }
    #expect(player.state == .playing)
    #expect(output.windows[0].allSatisfy { $0 == 0 }, "the missing first file is silence")
    #expect(abs(output.windows[1][0] - Self.value(0, seed: 0)) <= MeetingAudioFixture.tolerance)
    player.stop()
  }

  @Test("audio deleted while playing: the next window fails and playback stops")
  func deletedWhilePlaying() async throws {
    let folder = try MeetingAudioFixture.folder("playback-delete")
    let first = try MeetingAudioFixture.writeSegment(
      in: folder, index: 1, startMs: 0, frames: 16_000)
    let second = try MeetingAudioFixture.writeSegment(
      in: folder, index: 2, startMs: 1_000, frames: 16_000)
    let output = FakeOutput()
    let player = MeetingPlaybackController(
      files: [.microphone: [(first, 0), (second, 1_000)]], durationMs: 2_000, output: output,
      windowMs: 500)
    player.play()
    await eventually("two queued") { output.windows.count == 2 }
    try FileManager.default.removeItem(at: second)
    output.playNext()
    await eventually("unavailable") { player.state == .unavailable }
    #expect(output.stops >= 1)
    #expect(output.windows.count == 2)
  }

  @Test("an output that cannot start leaves playback unavailable; an empty meeting plays nothing")
  func outputStartFails() {
    let output = FakeOutput()
    output.failStart = true
    let player = MeetingPlaybackController(
      files: [:], durationMs: 1_000, output: output, windowMs: 250)
    player.play()
    #expect(player.state == .unavailable)
    let silent = MeetingPlaybackController(
      files: [:], durationMs: 0, output: FakeOutput(), windowMs: 250)
    silent.play()
    #expect(silent.state == .idle)
  }

  @Test("a record's files come from its own segment list and folder")
  func filesFromRecord() {
    var record = MeetingRecord(engine: .parakeet, trackStatus: [.microphone: .captured])
    record.segments = [
      .microphone: [
        MeetingSegmentInfo(
          index: 1, fileName: "mic-00001-s000000000.caf", startMs: 0, frameCount: 16_000)
      ]
    ]
    let source = MeetingPlaybackSource(record: record, folder: URL(fileURLWithPath: "/tmp/meeting"))
    #expect(source.files[.microphone]?.first?.url.lastPathComponent == "mic-00001-s000000000.caf")
    #expect(source.files[.microphone]?.first?.startMs == 0)
    #expect(source.files[.callSound] == nil)
    #expect(source.durationMs == record.recordedDurationMs)
  }

  @Test("the detail keeps its player for the same source, replaces it for a new one, drops it for none")
  func sourceChanges() {
    var record = MeetingRecord(engine: .parakeet, trackStatus: [.microphone: .captured])
    let folder = URL(fileURLWithPath: "/tmp/meeting")
    record.segments = [
      .microphone: [MeetingSegmentInfo(index: 1, fileName: "a.caf", startMs: 0, frameCount: 16_000)]
    ]
    let first = MeetingPlaybackSource(record: record, folder: folder)
    // A recovery that found one more file changes the inventory and the length.
    record.segments[.microphone]?.append(
      MeetingSegmentInfo(index: 2, fileName: "b.caf", startMs: 1_000, frameCount: 16_000))
    let recovered = MeetingPlaybackSource(record: record, folder: folder)
    #expect(MeetingPlaybackSource.change(from: first, to: first) == .keep)
    #expect(MeetingPlaybackSource.change(from: first, to: recovered) == .replace)
    #expect(MeetingPlaybackSource.change(from: nil, to: first) == .replace)
    #expect(MeetingPlaybackSource.change(from: first, to: nil) == .drop)
    #expect(recovered.durationMs > first.durationMs)
  }

  @Test("a seek to the end finishes in every state; the next Play starts over")
  func seekToEndFromEveryState() async throws {
    let folder = try MeetingAudioFixture.folder("playback-end")
    let mic = try MeetingAudioFixture.writeSegment(in: folder, index: 1, startMs: 0, frames: 16_000)
    for pauseFirst in [false, true] {
      let output = FakeOutput()
      let player = MeetingPlaybackController(
        files: [.microphone: [(mic, 0)]], durationMs: 1_000, output: output, windowMs: 250)
      if pauseFirst {
        player.play()
        await eventually("queued") { output.windows.count == 2 }
        player.pause()
      }
      player.seek(toMs: 1_000)
      #expect(player.state == .finished, "paused first: \(pauseFirst)")
      player.play()
      #expect(player.state == .playing)
      #expect(player.positionMs == 0)
      await eventually("plays from the start") { output.windows.count >= (pauseFirst ? 4 : 2) }
      #expect(
        abs(output.windows[pauseFirst ? 2 : 0][0] - Self.value(0, seed: 0))
          <= MeetingAudioFixture.tolerance)
      player.stop()
    }
  }

  @Test("many quick seeks keep one read in flight and play the last place")
  func seeksCoalesce() async throws {
    let folder = try MeetingAudioFixture.folder("playback-coalesce")
    let mic = try MeetingAudioFixture.writeSegment(in: folder, index: 1, startMs: 0, frames: 48_000)
    let output = FakeOutput()
    let gates = ReadGates()
    let player = MeetingPlaybackController(
      files: [.microphone: [(mic, 0)]], durationMs: 3_000, output: output, windowMs: 250,
      read: gates.reader())
    player.play()
    await eventually("first read parked") { gates.parked == [0] }
    for target in stride(from: 100, through: 2_500, by: 100) { player.seek(toMs: target) }
    #expect(gates.parked == [0], "no new read while one is still running")
    gates.release(0)
    await eventually("the latest place is read next") { gates.parked == [2_500] }
    #expect(player.staleReadsDropped == 1)
    gates.release(2_500)
    await eventually("queued") { output.windows.count == 1 }
    #expect(abs(output.windows[0][0] - Self.value(40_000, seed: 0)) <= MeetingAudioFixture.tolerance)
    // The next window's read is under way before the drain, so the drain covers it.
    await eventually("trailing read parked") { gates.parked == [2_750] && gates.inFlight == 1 }
    await finish(player, gates)
  }
}
