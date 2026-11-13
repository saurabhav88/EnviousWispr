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
  /// Plays at `rate` times normal speed with the pitch kept (#3147 PR3); kept across stop and
  /// start. 1 is normal.
  func setRate(_ rate: Float)
}

/// What a player reads (#3147): a meeting's track files on the meeting timeline, or one saved
/// dictation recording (AAC, 16 kHz mono).
enum PlaybackMedia: Sendable {
  case meeting(MeetingPlaybackController.TrackSources)
  case dictation(URL)
  /// #3147 PR3: an imported file's original, already opened by its owner (`ImportedSources`).
  case transcript(any PlaybackWindowAudio)
}

/// Opened audio that answers fixed windows of mono 16 kHz samples. Opened on the first window
/// (off the main actor) and reused; only one read is ever in flight per player.
protocol PlaybackWindowAudio: AnyObject, Sendable {
  /// `count` ms from `startMs`; silence past the end; throws when the audio can no longer be read.
  func window(startMs: Int, count: Int) throws -> [Float]
}

/// Which recording a player plays, so the shared now-playing owner can stop the right one.
enum PlaybackSourceID: Hashable, Sendable {
  case meeting(UUID)
  case dictation(UUID)
  /// #3147 PR3: an imported transcript's original file, by its History row id.
  case transcript(UUID)
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
  /// #3147 PR4B: each track's files as a reader opens them (a compacted file with the
  /// recorder's frame count).
  typealias TrackSources = [MeetingTrackKind: [MeetingTrackAudio.SourceFile]]

  /// The recording this player plays, when it is known to the shared now-playing owner.
  let sourceID: PlaybackSourceID?

  @ObservationIgnored private let media: PlaybackMedia
  @ObservationIgnored private let output: MeetingPlaybackOutput
  @ObservationIgnored private let windowMs: Int
  @ObservationIgnored private let read: Reader
  @ObservationIgnored private weak var arbiter: PlaybackArbiter?
  @ObservationIgnored private var audio: (any PlaybackWindowAudio)?
  @ObservationIgnored private var generation = 0
  @ObservationIgnored private var nextReadMs = 0
  @ObservationIgnored private var queued = 0
  @ObservationIgnored private var reading = false
  nonisolated static let samplesPerMs = Int(MeetingAudioFormat.sampleRate) / 1_000

  /// Reads one window off the main actor: the audio (opened on the first window, then reused)
  /// and the samples. Replaceable so a test can decide which read lands first.
  typealias Reader =
    @Sendable (
      _ media: PlaybackMedia, _ loaded: (any PlaybackWindowAudio)?, _ startMs: Int, _ count: Int
    ) async throws -> (any PlaybackWindowAudio, [Float])

  nonisolated static let readWindow: Reader = { media, loaded, startMs, count in
    let audio = try loaded ?? open(media)
    return (audio, try audio.window(startMs: startMs, count: count))
  }

  init(
    media: PlaybackMedia, durationMs: Int, output: MeetingPlaybackOutput, windowMs: Int = 250,
    read: @escaping Reader = MeetingPlaybackController.readWindow,
    sourceID: PlaybackSourceID? = nil, arbiter: PlaybackArbiter? = nil
  ) {
    self.read = read
    self.media = media
    self.durationMs = max(0, durationMs)
    self.output = output
    self.windowMs = max(10, windowMs)
    self.sourceID = sourceID
    self.arbiter = arbiter
    if let sourceID { arbiter?.register(self, as: sourceID) }
  }

  /// A meeting player for `files` (the original meeting-only entry).
  convenience init(
    files: TrackFiles, durationMs: Int, output: MeetingPlaybackOutput, windowMs: Int = 250,
    read: @escaping Reader = MeetingPlaybackController.readWindow
  ) {
    self.init(
      media: .meeting(
        files.mapValues { list in
          list.map { MeetingTrackAudio.SourceFile(url: $0.url, startMs: $0.startMs, logicalFrames: nil) }
        }), durationMs: durationMs, output: output, windowMs: windowMs, read: read)
  }

  /// A player for `source`'s files and length, known to the shared now-playing owner.
  convenience init(
    source: MeetingPlaybackSource, output: MeetingPlaybackOutput, meetingID: UUID? = nil,
    arbiter: PlaybackArbiter? = nil
  ) {
    self.init(
      media: .meeting(source.trackSources), durationMs: source.durationMs, output: output,
      sourceID: meetingID.map { .meeting($0) }, arbiter: arbiter)
  }

  /// The speeds a transcript's dock offers (#3147 PR3, the mock's menu).
  nonisolated static let playbackRates: [Float] = [0.75, 1, 1.25, 1.5, 2]

  /// The current speed; 1 for every player until a transcript's dock changes it.
  private(set) var playbackRate: Float = 1

  /// Sets the speed (one of `playbackRates`; anything else is ignored), kept across pause,
  /// stop and play. The position stays on the recording's own timeline.
  func setPlaybackRate(_ rate: Float) {
    guard Self.playbackRates.contains(rate) else { return }
    playbackRate = rate
    output.setRate(rate)
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
    // #3147: one recording plays at a time; whatever played before pauses.
    arbiter?.didStartPlaying(self)
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
    audio = nil
    if state != .unavailable { state = .idle }
  }

  /// #3147: the recording is being deleted. Stops at once, lets go of the file, and never plays
  /// again: a window read already running lands in an old generation and is dropped.
  func stopForDeletion() {
    halt()
    audio = nil
    state = .unavailable
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
    let media = media
    let loaded = audio
    let read = read
    Task.detached(priority: .userInitiated) { [weak self] in
      let result: Result<(any PlaybackWindowAudio, [Float]), Error>
      do {
        result = .success(try await read(media, loaded, startMs, count))
      } catch {
        result = .failure(error)
      }
      await self?.queue(result, generation: generation, startMs: startMs, count: count)
    }
  }

  private func queue(
    _ result: Result<(any PlaybackWindowAudio, [Float]), Error>, generation: Int, startMs: Int,
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
    case .success(let (audio, samples)):
      self.audio = audio
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
    audio = nil
    state = .unavailable
  }

  // MARK: - Reading (off the main actor)

  enum PlaybackError: Error, Equatable {
    /// Not one listed file could be read: the audio is gone.
    case noReadableAudio
  }

  /// Opens the audio for the first window: the meeting's tracks, or the dictation's file.
  nonisolated static func open(_ media: PlaybackMedia) throws -> any PlaybackWindowAudio {
    switch media {
    case .meeting(let files): return MeetingMixedAudio(tracks: try load(files))
    case .dictation(let url): return try DictationPlaybackAudio(url: url)
    case .transcript(let audio): return audio
    }
  }

  /// Opens the tracks once, on the first window. A damaged file is left out by
  /// `MeetingTrackAudio` and its stretch plays as silence, as the transcript marks it; only a
  /// meeting with no readable file at all is unavailable.
  nonisolated static func load(_ files: TrackSources) throws -> [MeetingTrackAudio] {
    let tracks = MeetingTrackKind.allCases.compactMap { kind -> MeetingTrackAudio? in
      guard let list = files[kind], !list.isEmpty else { return nil }
      return MeetingTrackAudio(sources: list)
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

/// A meeting's tracks, mixed window by window (`MeetingPlaybackController.mix`).
final class MeetingMixedAudio: PlaybackWindowAudio, @unchecked Sendable {
  private let tracks: [MeetingTrackAudio]
  init(tracks: [MeetingTrackAudio]) { self.tracks = tracks }
  func window(startMs: Int, count: Int) throws -> [Float] {
    try MeetingPlaybackController.mix(tracks, startMs: startMs, count: count)
  }
}

/// What one meeting's playback reads: its kept files and its length, from the saved record
/// (#3972 C5). The detail view keeps a player only while this is unchanged, so a recovery that
/// rewrote the inventory, a deletion or a lost file ends or replaces the player.
///
/// #3147 PR4B: with a committed compacted inventory the files are the ones
/// `MeetingAudioSelection` chooses for the recorder's raw segments (asked with the complete
/// logical set, the inventory's cleaned twins included, then filtered to raw: playback is raw),
/// read at the recorder's frame counts. The inventory's id is part of the source, so committing
/// a compacted copy is a different source and rebuilds the player instead of changing files under
/// an unchanged one. An inventory the selector refuses plays the recorder files as listed, whole,
/// never a mix.
struct MeetingPlaybackSource: Hashable, Sendable {
  struct File: Hashable, Sendable {
    let url: URL
    let startMs: Int
    /// The recorder's frame count for a compacted file; nil for a recorder CAF.
    var logicalFrames: Int? = nil
  }

  let files: [MeetingTrackKind: [File]]
  let durationMs: Int
  /// The committed compacted inventory the files come from; nil for the recorder's files.
  let inventoryID: UUID?

  init(record: MeetingRecord, folder: URL) {
    durationMs = record.recordedDurationMs
    let recorderFiles = record.segments.mapValues { segments in
      segments.map { File(url: folder.appendingPathComponent($0.fileName), startMs: $0.startMs) }
    }
    guard let inventory = record.compressedAudio else {
      files = recorderFiles
      inventoryID = nil
      return
    }
    var logical: [MeetingLogicalSegment] = []
    for track in MeetingTrackKind.allCases {
      for segment in record.segments[track] ?? [] {
        logical.append(MeetingLogicalSegment(track: track, variant: .raw, segment: segment))
      }
    }
    for entry in inventory.segments where entry.variant == .cleaned {
      logical.append(
        MeetingLogicalSegment(track: entry.track, variant: .cleaned, segment: entry.source))
    }
    guard let selected = try? MeetingAudioSelection.select(logical: logical, inventory: inventory)
    else {
      files = recorderFiles
      inventoryID = nil
      return
    }
    var chosen: [MeetingTrackKind: [File]] = [:]
    for item in selected where item.key.variant == .raw {
      chosen[item.key.track, default: []].append(
        File(
          url: folder.appendingPathComponent(item.fileName), startMs: item.logical.startMs,
          logicalFrames: item.encoding == .aacM4A ? item.logical.frameCount : nil))
    }
    files = chosen
    inventoryID = inventory.id
  }

  /// What a reader opens (`MeetingTrackAudio(sources:)`).
  var trackSources: MeetingPlaybackController.TrackSources {
    files.mapValues {
      $0.map { MeetingTrackAudio.SourceFile(url: $0.url, startMs: $0.startMs, logicalFrames: $0.logicalFrames) }
    }
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
  /// Speed with the pitch kept (#3147 PR3), between the player and the mixer.
  private var timePitch: AVAudioUnitTimePitch?
  private var rate: Float = 1
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
    let timePitch = AVAudioUnitTimePitch()
    timePitch.rate = rate
    engine.attach(player)
    engine.attach(timePitch)
    engine.connect(player, to: timePitch, format: format)
    engine.connect(timePitch, to: engine.mainMixerNode, format: format)
    try engine.start()
    player.play()
    self.engine = engine
    self.player = player
    self.timePitch = timePitch
  }

  func setRate(_ rate: Float) {
    self.rate = rate
    timePitch?.rate = rate
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
    if let timePitch { engine?.detach(timePitch) }
    player = nil
    timePitch = nil
    engine = nil
  }
}
