@preconcurrency import AVFoundation
import EnviousWisprAudio
import EnviousWisprCore
import Foundation

/// Where meeting playback sends its audio (#3972 §3.8). One output per open meeting, separate
/// from capture and transcription: it never takes the engine lease or the microphone.
@MainActor
protocol MeetingPlaybackOutput: AnyObject {
  /// Prepares the output to play; throws when it cannot.
  func start() throws
  /// Plays `samples` (mono, `MeetingAudioFormat.sampleRate`) after everything already queued,
  /// and calls `played` once they have played. A call that arrives after `stop()` is ignored by
  /// the controller, which fences every completion by generation.
  func enqueue(_ samples: [Float], played: @escaping @MainActor () -> Void)
  /// Stops at once and drops anything queued.
  func stop()
}

/// Plays one meeting's kept audio on the meeting timeline (#3972 §3.8, C5 items 29-31): play,
/// pause, scrub and jump to a turn's time. Both tracks are mixed; a gap between segments plays
/// as silence. Audio is read in short windows through `MeetingTrackAudio` (only the files a
/// window touches are opened), never as one multi-hour array, and at most two windows are
/// queued ahead. Every seek, pause and stop starts a new generation, so a window or a completion
/// that belongs to an earlier one can never move the position or play stale audio.
@MainActor
@Observable
final class MeetingPlaybackController {
  enum State: Equatable {
    case idle
    case playing
    case paused
    case finished
    /// The audio could not be read (deleted, moved or damaged); nothing more plays.
    case unavailable
  }

  private(set) var state: State = .idle
  /// Where playback is on the meeting timeline: the end of the last window that has played.
  private(set) var positionMs = 0
  /// Window reads that came back after a seek, pause or stop and were dropped unplayed.
  private(set) var staleReadsDropped = 0
  let durationMs: Int

  /// Each track's segment files and their start times on the meeting timeline.
  typealias TrackFiles = [MeetingTrackKind: [(url: URL, startMs: Int)]]

  @ObservationIgnored private let files: TrackFiles
  @ObservationIgnored private let output: MeetingPlaybackOutput
  @ObservationIgnored private let windowMs: Int
  @ObservationIgnored private let read: Reader
  @ObservationIgnored private var tracks: [MeetingTrackAudio]?
  @ObservationIgnored private var generation = 0
  @ObservationIgnored private var nextReadMs = 0
  @ObservationIgnored private var queued = 0
  @ObservationIgnored private var reading = false
  nonisolated static let samplesPerMs = Int(MeetingAudioFormat.sampleRate) / 1_000

  /// Reads one window off the main actor: the tracks (opened on the first window, then
  /// reused) and the mixed samples. Replaceable so a test can decide which read lands first.
  typealias Reader =
    @Sendable (_ files: TrackFiles, _ loaded: [MeetingTrackAudio]?, _ startMs: Int, _ count: Int)
      async throws -> ([MeetingTrackAudio], [Float])

  nonisolated static let readWindow: Reader = { files, loaded, startMs, count in
    let tracks = try loaded ?? load(files)
    return (tracks, try mix(tracks, startMs: startMs, count: count))
  }

  init(
    files: TrackFiles, durationMs: Int, output: MeetingPlaybackOutput, windowMs: Int = 250,
    read: @escaping Reader = MeetingPlaybackController.readWindow
  ) {
    self.read = read
    self.files = files
    self.durationMs = max(0, durationMs)
    self.output = output
    self.windowMs = max(10, windowMs)
  }

  /// A player for `source`'s files and length.
  convenience init(source: MeetingPlaybackSource, output: MeetingPlaybackOutput) {
    self.init(files: source.trackFiles, durationMs: source.durationMs, output: output)
  }

  func play() {
    guard state != .playing, state != .unavailable, durationMs > 0 else { return }
    if state == .finished { positionMs = 0 }
    do {
      try output.start()
    } catch {
      becomeUnavailable()
      return
    }
    generation += 1
    nextReadMs = positionMs
    queued = 0
    state = .playing
    fill()
  }

  func pause() {
    guard state == .playing else { return }
    halt()
    state = .paused
  }

  /// Moves to `ms` (clamped to the meeting); playing goes on from there, paused stays paused.
  /// The end of the meeting is `.finished` in every state, so the next Play starts over.
  func seek(toMs ms: Int) {
    guard state != .unavailable else { return }
    let wasPlaying = state == .playing
    halt()
    positionMs = min(max(0, ms), durationMs)
    guard positionMs < durationMs else {
      state = .finished
      return
    }
    if wasPlaying {
      // Play on from the new place, in a new generation; the stop above emptied the output.
      do {
        try output.start()
      } catch {
        becomeUnavailable()
        return
      }
      nextReadMs = positionMs
      fill()
    } else if state == .finished, positionMs < durationMs {
      state = .paused
    }
  }

  /// Ends playback and lets go of every file: the meeting closed, changed or lost its audio.
  func stop() {
    halt()
    tracks = nil
    if state != .unavailable { state = .idle }
  }

  // MARK: - Windows

  /// Ends the current generation. A read already running is left to finish (`reading` stays
  /// set), so no more than one read is ever in flight; when it lands it is dropped and the
  /// next read starts from wherever playback is now, however many seeks came in between.
  private func halt() {
    generation += 1
    output.stop()
    queued = 0
  }

  /// Reads and queues windows until two are waiting or the meeting ends.
  private func fill() {
    guard state == .playing, !reading, queued < 2, nextReadMs < durationMs else { return }
    reading = true
    let generation = generation
    let startMs = nextReadMs
    let count = min(windowMs, durationMs - startMs)
    let files = files
    let loaded = tracks
    let read = read
    Task.detached(priority: .userInitiated) { [weak self] in
      let result: Result<([MeetingTrackAudio], [Float]), Error>
      do {
        result = .success(try await read(files, loaded, startMs, count))
      } catch {
        result = .failure(error)
      }
      await self?.queue(result, generation: generation, startMs: startMs, count: count)
    }
  }

  private func queue(
    _ result: Result<([MeetingTrackAudio], [Float]), Error>, generation: Int, startMs: Int,
    count: Int
  ) {
    reading = false
    guard generation == self.generation, state == .playing else {
      staleReadsDropped += 1
      fill()
      return
    }
    switch result {
    case .failure:
      becomeUnavailable()
    case .success(let (tracks, samples)):
      self.tracks = tracks
      let endMs = startMs + count
      nextReadMs = endMs
      queued += 1
      output.enqueue(samples) { [weak self] in
        self?.played(generation: generation, endMs: endMs)
      }
      fill()
    }
  }

  private func played(generation: Int, endMs: Int) {
    guard generation == self.generation, state == .playing else { return }
    queued -= 1
    positionMs = endMs
    if queued == 0, nextReadMs >= durationMs {
      halt()
      state = .finished
      return
    }
    fill()
  }

  private func becomeUnavailable() {
    halt()
    tracks = nil
    state = .unavailable
  }

  // MARK: - Reading (off the main actor)

  enum PlaybackError: Error, Equatable {
    /// Not one listed file could be read: the audio is gone.
    case noReadableAudio
  }

  /// Opens the tracks once, on the first window. A damaged file is left out by
  /// `MeetingTrackAudio` and its stretch plays as silence, as the transcript marks it; only a
  /// meeting with no readable file at all is unavailable.
  nonisolated static func load(_ files: TrackFiles) throws -> [MeetingTrackAudio] {
    let tracks = MeetingTrackKind.allCases.compactMap { kind -> MeetingTrackAudio? in
      guard let list = files[kind], !list.isEmpty else { return nil }
      return MeetingTrackAudio(files: list)
    }
    guard tracks.contains(where: { !$0.isEmpty }) else { throw PlaybackError.noReadableAudio }
    return tracks
  }

  /// `count` ms from `startMs`, every track summed and clipped to the sample range. A gap is
  /// silence; a file the window needs that can no longer be read (deleted while playing)
  /// throws.
  nonisolated static func mix(_ tracks: [MeetingTrackAudio], startMs: Int, count: Int) throws
    -> [Float]
  {
    let start = startMs * samplesPerMs
    let samples = count * samplesPerMs
    var out = [Float](repeating: 0, count: samples)
    for track in tracks {
      let part = try track.read(from: start, count: samples)
      for i in 0..<samples { out[i] += part[i] }
    }
    for i in 0..<samples { out[i] = min(1, max(-1, out[i])) }
    return out
  }
}

/// What one meeting's playback reads: its kept files and its length, from the saved record
/// (#3972 C5). The detail view keeps a player only while this is unchanged, so a recovery that
/// rewrote the inventory, a deletion or a lost file ends or replaces the player.
struct MeetingPlaybackSource: Hashable, Sendable {
  struct File: Hashable, Sendable {
    let url: URL
    let startMs: Int
  }

  let files: [MeetingTrackKind: [File]]
  let durationMs: Int

  init(record: MeetingRecord, folder: URL) {
    files = record.segments.mapValues { segments in
      segments.map { File(url: folder.appendingPathComponent($0.fileName), startMs: $0.startMs) }
    }
    durationMs = record.recordedDurationMs
  }

  var trackFiles: MeetingPlaybackController.TrackFiles {
    files.mapValues { $0.map { (url: $0.url, startMs: $0.startMs) } }
  }

  /// What the detail view does with its player when the source changes.
  enum Change: Equatable {
    case keep
    case replace
    case drop
  }

  static func change(from current: MeetingPlaybackSource?, to new: MeetingPlaybackSource?) -> Change {
    guard let new else { return .drop }
    return current == new ? .keep : .replace
  }
}

/// The real output: its own small `AVAudioEngine` with one player node, never the capture
/// engine. Built only when the user presses Play.
@MainActor
final class MeetingPlaybackEngineOutput: MeetingPlaybackOutput {
  private var engine: AVAudioEngine?
  private var player: AVAudioPlayerNode?
  private let format = AVAudioFormat(
    commonFormat: .pcmFormatFloat32, sampleRate: MeetingAudioFormat.sampleRate, channels: 1,
    interleaved: false)!

  func start() throws {
    if let engine, engine.isRunning, let player {
      player.play()
      return
    }
    let engine = AVAudioEngine()
    let player = AVAudioPlayerNode()
    engine.attach(player)
    engine.connect(player, to: engine.mainMixerNode, format: format)
    try engine.start()
    player.play()
    self.engine = engine
    self.player = player
  }

  func enqueue(_ samples: [Float], played: @escaping @MainActor () -> Void) {
    guard let player,
      let buffer = AVAudioPCMBuffer(
        pcmFormat: format, frameCapacity: AVAudioFrameCount(max(1, samples.count)))
    else { return }
    buffer.frameLength = AVAudioFrameCount(samples.count)
    samples.withUnsafeBufferPointer { source in
      buffer.floatChannelData![0].update(from: source.baseAddress!, count: samples.count)
    }
    player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { _ in
      Task { @MainActor in played() }
    }
  }

  func stop() {
    player?.stop()
    engine?.stop()
    if let player { engine?.detach(player) }
    player = nil
    engine = nil
  }
}
