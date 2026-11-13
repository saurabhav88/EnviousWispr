@preconcurrency import AVFoundation
import EnviousWisprASR
import EnviousWisprCore
import Foundation

/// An imported file's ORIGINAL, read for History's player in fixed windows (#3147 PR3, plan
/// §3.5): mono 16 kHz `Float32`, converted by the same reader settings and track choice as
/// `AudioFileDecoder` (`engineOutputSettings`, `mainProgramTrack`), so the audio a person replays
/// is the audio that was transcribed.
///
/// **Never the whole file.** A multi-hour recording is read window by window: one
/// `AVAssetReader` reads forward while playback is sequential; a seek backwards, or further
/// ahead than `forwardSkipSamples`, starts a new reader at that time (with a short pre-roll so
/// the decoder and resampler are warm at the requested sample). Only the samples not yet played
/// are held. The source is only ever opened for reading.
///
/// Sample positions come from each buffer's presentation time, so a reader started part-way in
/// still places its samples on the file's own timeline; a gap plays as silence and an overlap
/// is dropped.
///
/// `@unchecked Sendable`: every mutable field is touched only inside `lock`, and the player
/// never runs two reads at once (`PlaybackWindowAudio`).
final class ImportedFilePlaybackAudio: PlaybackWindowAudio, @unchecked Sendable {
  enum Failure: Error, Equatable {
    /// The file opened and has no audio track.
    case noAudioTrack
    /// The file could not be opened, or reading it failed part-way.
    case unreadable
  }

  /// Samples per second of every window (the engines' and the player's rate).
  static let sampleRate = Int(AudioConstants.sampleRate)
  /// A forward jump up to this far is read through rather than reopened (2 s).
  static let forwardSkipSamples = 2 * sampleRate
  /// How far before a seek target a new reader starts, so the decoder is warm there (100 ms).
  static let seekPreRollSamples = sampleRate / 10

  private let asset: AVURLAsset
  private let track: AVAssetTrack
  /// The audio track's length in whole milliseconds.
  let durationMs: Int

  private let lock = NSLock()
  private var reader: AVAssetReader?
  private var output: AVAssetReaderAudioMixOutput?
  /// Decoded samples not yet handed out, starting at file sample `pendingStart`.
  private var pending: [Float] = []
  private var pendingStart = 0
  /// Whether `pending` has been anchored by a buffer of the current reader.
  private var anchored = false
  /// The current reader has handed out its last buffer.
  private var exhausted = false
  /// `close()` ran: nothing more is read.
  private var closed = false
  /// How many readers this audio has started (the first one, then one per far seek).
  private var readersStarted = 0
  var readerStarts: Int { lock.withLock { readersStarted } }

  private init(asset: AVURLAsset, track: AVAssetTrack, durationMs: Int) {
    self.asset = asset
    self.track = track
    self.durationMs = durationMs
  }

  deinit { reader?.cancelReading() }

  /// Opens `url` for windowed reading. Off the main actor; cooperative cancellation.
  @concurrent
  static func open(url: URL) async throws -> ImportedFilePlaybackAudio {
    let asset = AVURLAsset(url: url)
    let tracks: [AVAssetTrack]
    do {
      tracks = try await asset.loadTracks(withMediaType: .audio)
    } catch {
      try Task.checkCancellation()
      throw Failure.unreadable
    }
    try Task.checkCancellation()
    guard !tracks.isEmpty else { throw Failure.noAudioTrack }
    let track = AudioFileDecoder.mainProgramTrack(in: tracks)
    let range: CMTimeRange
    do {
      range = try await track.load(.timeRange)
    } catch {
      try Task.checkCancellation()
      throw Failure.unreadable
    }
    try Task.checkCancellation()
    let end = CMTimeRangeGetEnd(range)
    guard end.isNumeric, end.seconds.isFinite, end.seconds >= 0 else { throw Failure.unreadable }
    let audio = ImportedFilePlaybackAudio(
      asset: asset, track: track, durationMs: Int((end.seconds * 1_000).rounded(.down)))
    // Proves now, not at the first Play, that a reader can start on this file.
    try audio.lock.withLock { try audio.startReader(at: 0) }
    return audio
  }

  /// Stops reading; later windows throw. Never touches the file.
  func close() {
    lock.withLock {
      reader?.cancelReading()
      reader = nil
      output = nil
      pending = []
      closed = true
    }
  }

  func window(startMs: Int, count: Int) throws -> [Float] {
    let perMs = Self.sampleRate / 1_000
    let start = max(0, startMs) * perMs
    let wanted = max(0, count) * perMs
    return try lock.withLock { try samples(from: start, count: wanted) }
  }

  // MARK: - Reading (inside `lock`)

  private func samples(from start: Int, count: Int) throws -> [Float] {
    guard !closed else { throw Failure.unreadable }
    var out = [Float](repeating: 0, count: count)
    guard count > 0 else { return out }
    let end = start + count
    if needsReopen(for: start) {
      try startReader(at: start)
    }
    try fill(through: end)
    // Copy what overlaps [start, end); anything else stays silence.
    let pendingEnd = pendingStart + pending.count
    let from = max(start, pendingStart)
    let to = min(end, pendingEnd)
    if from < to {
      for i in from..<to { out[i - start] = pending[i - pendingStart] }
    }
    // Keep only what a later sequential window can still use.
    let keepFrom = min(end, pendingEnd)
    if keepFrom > pendingStart {
      pending.removeFirst(keepFrom - pendingStart)
      pendingStart = keepFrom
    }
    return out
  }

  /// A new reader is needed for a jump backwards, or one too far ahead to read through.
  private func needsReopen(for start: Int) -> Bool {
    guard reader != nil else { return true }
    guard anchored else {
      return start < pendingStart || start - pendingStart > Self.forwardSkipSamples
    }
    let pendingEnd = pendingStart + pending.count
    if start < pendingStart { return true }
    if start <= pendingEnd { return false }
    return exhausted ? false : start - pendingEnd > Self.forwardSkipSamples
  }

  private func startReader(at sample: Int) throws {
    reader?.cancelReading()
    reader = nil
    output = nil
    let from = max(0, sample - Self.seekPreRollSamples)
    let next: AVAssetReader
    do {
      next = try AVAssetReader(asset: asset)
    } catch {
      throw Failure.unreadable
    }
    let mix = AVAssetReaderAudioMixOutput(
      audioTracks: [track], audioSettings: AudioFileDecoder.engineOutputSettings())
    guard next.canAdd(mix) else { throw Failure.unreadable }
    next.add(mix)
    if from > 0 {
      next.timeRange = CMTimeRange(
        start: CMTime(value: CMTimeValue(from), timescale: CMTimeScale(Self.sampleRate)),
        duration: .positiveInfinity)
    }
    guard next.startReading() else { throw Failure.unreadable }
    reader = next
    output = mix
    pending = []
    pendingStart = sample
    anchored = false
    exhausted = false
    readersStarted += 1
  }

  /// Reads buffers until `pending` reaches file sample `end` or the reader ends.
  private func fill(through end: Int) throws {
    while !exhausted, !anchored || pendingStart + pending.count < end {
      guard let output, let reader else { throw Failure.unreadable }
      guard let buffer = output.copyNextSampleBuffer() else {
        exhausted = true
        switch reader.status {
        case .completed: return
        default: throw Failure.unreadable
        }
      }
      let pts = CMSampleBufferGetPresentationTimeStamp(buffer)
      var decoded: [Float] = []
      AudioFileDecoder.appendSamples(from: buffer, into: &decoded)
      CMSampleBufferInvalidate(buffer)
      guard !decoded.isEmpty else { continue }
      let bufferStart =
        pts.isNumeric
        ? Int((pts.seconds * Double(Self.sampleRate)).rounded())
        : (anchored ? pendingStart + pending.count : pendingStart)
      append(decoded, at: bufferStart)
    }
  }

  /// Places `decoded` (starting at file sample `bufferStart`) after `pending`: silence fills a
  /// gap, an overlap is dropped, and samples before the requested start are never kept.
  private func append(_ decoded: [Float], at bufferStart: Int) {
    let wantedFrom = anchored ? pendingStart + pending.count : pendingStart
    var chunk = decoded[...]
    var chunkStart = bufferStart
    if chunkStart < wantedFrom {
      let drop = min(chunk.count, wantedFrom - chunkStart)
      chunk = chunk.dropFirst(drop)
      chunkStart += drop
    }
    guard !chunk.isEmpty else { return }
    if !anchored {
      // The first kept sample: everything from the requested start up to it is silence.
      pending = [Float](repeating: 0, count: chunkStart - pendingStart)
      anchored = true
    } else if chunkStart > pendingStart + pending.count {
      pending.append(
        contentsOf: [Float](repeating: 0, count: chunkStart - (pendingStart + pending.count)))
    }
    pending.append(contentsOf: chunk)
  }
}
