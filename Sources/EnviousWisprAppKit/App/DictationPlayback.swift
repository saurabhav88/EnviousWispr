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

  func didStartPlaying(_ player: MeetingPlaybackController) {
    if let previous = nowPlaying, previous !== player { previous.pause() }
    nowPlaying = player
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
}

/// History's view of one dictation's recording (#3147 §3.4).
enum DictationRecordingStatus: Equatable, Sendable {
  case available(url: URL, durationMs: Int, pinned: Bool)
  /// No recording, with the reason recorded when it happened (nil: legacy or unexplained).
  case absent(RecordingAbsence?)
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

  func changed(_ rowID: UUID) { revisions[rowID, default: 0] += 1 }
  func changedAll() { allRevision += 1 }

  /// One number that moves whenever `rowID`'s recording may have changed.
  func revision(for rowID: UUID) -> Int { revisions[rowID, default: 0] &+ allRevision &* 1_000_003 }
}
