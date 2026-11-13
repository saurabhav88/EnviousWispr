@preconcurrency import AVFoundation
import EnviousWisprCore
import EnviousWisprStorage
import Foundation
import Observation

/// One saved dictation recording read in fixed windows (#3147 §3.1): AAC decoded by Apple's
/// reader into mono 16 kHz Float32, the format the shared playback output plays. The file's own
/// frame count (the encoder's priming and padding already removed) is its length. Opened off the
/// main actor by the player's first window; the player never runs two reads at once.
final class DictationPlaybackAudio: PlaybackWindowAudio, @unchecked Sendable {
  enum Failure: Error, Equatable {
    /// The file is not 16 kHz mono audio this player can read.
    case unsupportedFormat
  }

  private let file: AVAudioFile
  private let lock = NSLock()
  let frames: Int64

  init(url: URL) throws {
    let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
    guard file.processingFormat.sampleRate == MeetingAudioFormat.sampleRate,
      file.processingFormat.channelCount == 1
    else { throw Failure.unsupportedFormat }
    self.file = file
    self.frames = file.length
  }

  /// The recording's length in whole milliseconds, read from the file itself.
  var durationMs: Int { Int(frames / Int64(MeetingPlaybackController.samplesPerMs)) }

  func window(startMs: Int, count: Int) throws -> [Float] {
    let perMs = MeetingPlaybackController.samplesPerMs
    let wanted = count * perMs
    var out = [Float](repeating: 0, count: wanted)
    let start = Int64(startMs * perMs)
    guard start < frames else { return out }
    let available = Int(min(Int64(wanted), frames - start))
    try lock.withLock {
      guard
        let buffer = AVAudioPCMBuffer(
          pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(available))
      else { throw Failure.unsupportedFormat }
      file.framePosition = start
      try file.read(into: buffer, frameCount: AVAudioFrameCount(available))
      let read = Int(buffer.frameLength)
      if read > 0 {
        out.withUnsafeMutableBufferPointer { target in
          target.baseAddress!.update(from: buffer.floatChannelData![0], count: read)
        }
      }
    }
    return out
  }
}

/// The one now-playing owner across History's windows (#3147 §3.1, §3.8): starting any meeting
/// or dictation recording pauses the one that was playing, and a deletion stops every player of
/// that recording before its files go. Players register when they are made; the owner holds them
/// weakly, so a closed view's player simply disappears.
@MainActor
final class PlaybackArbiter {
  private final class Entry {
    weak var player: MeetingPlaybackController?
    init(_ player: MeetingPlaybackController) { self.player = player }
  }

  private var players: [PlaybackSourceID: [Entry]] = [:]
  private weak var nowPlaying: MeetingPlaybackController?
  /// Bumped for a recording whenever its audio is being deleted, so a view that began looking up
  /// that recording earlier never builds a player from the stale answer.
  private var deletions: [PlaybackSourceID: Int] = [:]

  func register(_ player: MeetingPlaybackController, as id: PlaybackSourceID) {
    var entries = players[id, default: []].filter { $0.player != nil }
    entries.append(Entry(player))
    players[id] = entries
  }

  /// #3147 PR4B: recordings whose files are being switched (a meeting's compacted copy being
  /// committed): their players may not start until the switch ends.
  private var heldStarts: Set<PlaybackSourceID> = []

  func holdStarts(_ id: PlaybackSourceID) { heldStarts.insert(id) }
  func releaseStarts(_ id: PlaybackSourceID) { heldStarts.remove(id) }
  /// Whether a player of `id` may start playing now.
  func mayStart(_ id: PlaybackSourceID) -> Bool { !heldStarts.contains(id) }

  func didStartPlaying(_ player: MeetingPlaybackController) {
    if let previous = nowPlaying, previous !== player { previous.pause() }
    nowPlaying = player
  }

  /// Whether a player of `id` is the one playing now. Retention never removes a recording
  /// someone is listening to; the next sweep takes it.
  /// #3147 PR4B: whether any player of `id` is open (playing, paused or idle), so background
  /// compaction never changes a recording under a page that is showing it.
  func hasPlayer(_ id: PlaybackSourceID) -> Bool {
    players[id]?.contains { $0.player != nil } ?? false
  }

  func isPlaying(_ id: PlaybackSourceID) -> Bool {
    guard let nowPlaying, nowPlaying.state == .playing else { return false }
    return players[id]?.contains { $0.player === nowPlaying } ?? false
  }

  /// The deletion count for `id`; a lookup that began under an older count is stale.
  func deletionCount(for id: PlaybackSourceID) -> Int { deletions[id, default: 0] }

  /// Stops every player of `id` for good, before its audio is deleted.
  func stopForDeletion(_ id: PlaybackSourceID) {
    deletions[id, default: 0] += 1
    for entry in players.removeValue(forKey: id) ?? [] { entry.player?.stopForDeletion() }
  }

  /// Delete All: stops every dictation player for good.
  func stopAllDictationsForDeletion() {
    dictationEpoch += 1
    for id in Array(players.keys) {
      if case .dictation = id { stopForDeletion(id) }
    }
  }

  /// Bumped by Delete All, so a dictation lookup that began before it is stale even for a row
  /// whose id the owner had never seen.
  private(set) var dictationEpoch = 0

  /// #3147 PR3: Delete All stops every imported transcript's player for good, too.
  func stopAllTranscriptsForDeletion() {
    transcriptEpoch += 1
    for id in Array(players.keys) {
      if case .transcript = id { stopForDeletion(id) }
    }
  }

  /// Bumped by `stopAllTranscriptsForDeletion`, so a transcript source lookup that began before
  /// it is stale even for a row the owner had never seen.
  private(set) var transcriptEpoch = 0
}

/// History's view of one dictation's recording (#3147 §3.4).
enum DictationRecordingStatus: Equatable, Sendable {
  case available(url: URL, durationMs: Int, pinned: Bool)
  /// No recording, with the reason (and an expiry's keep period) recorded when it happened
  /// (nil: legacy or unexplained).
  case absent(RecordedAbsence?)
  /// The recording or its metadata could not be read just now; nothing is concluded.
  case unreadable
}

/// Tells History views which dictation recordings changed, so a detail refreshes after a
/// publication, deletion or Keep change without polling the disk.
@MainActor
@Observable
final class DictationRecordingChanges {
  private(set) var revisions: [UUID: Int] = [:]
  private(set) var allRevision = 0
  /// Told after every change, so recording storage use is measured again (`RecordingRetention`).
  @ObservationIgnored var onChange: (@MainActor () -> Void)?

  func changed(_ rowID: UUID) {
    revisions[rowID, default: 0] += 1
    onChange?()
  }

  func changedAll() {
    allRevision += 1
    onChange?()
  }

  /// One number that moves whenever `rowID`'s recording may have changed.
  func revision(for rowID: UUID) -> Int { revisions[rowID, default: 0] &+ allRevision &* 1_000_003 }
}
