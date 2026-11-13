import AVFoundation
import Foundation

/// Compresses speech audio to AAC-LC in an m4a file and proves the result before reporting
/// success (#3147 §3.1).
///
/// Used for saved dictation recordings (History playback) and, later, for compacting finished
/// meeting tracks. The bitrates are the ones measured in P1-0
/// (`SpeechAudioCodecRealBoundaryTests`): 32 kbps projects to 14.79 MB per hour of dictation and
/// 48 kbps to 22.03 MB per meeting track-hour, both at 16 kHz mono, with no change in what
/// Parakeet or Whisper hear at 48 kbps.
///
/// Calls are synchronous and do real file work: run them off the main actor and never from a
/// capture callback, for example in a `Task.detached(priority: .utility)`. A cancelled task stops
/// between chunks and removes its own output.
///
/// The destination must not exist yet: the encoder never replaces a file, so a failed or
/// unverified encode cannot destroy an earlier good recording. On any failure the encoder
/// removes the destination it created. Source files are only read, never changed or removed.
public enum SpeechAudioEncoder {
  /// What the audio is for, which fixes the bitrate.
  public enum Purpose: Sendable {
    /// One dictation take, kept for playback.
    case dictation
    /// One meeting track, which may be transcribed again later.
    case meeting

    public var bitRate: Int {
      switch self {
      case .dictation: 32_000
      case .meeting: 48_000
      }
    }
  }

  public struct Output: Sendable, Equatable {
    /// Frames the finished file decodes to (the encoder's priming and padding excluded).
    public let frames: Int64
    public let bytes: Int64

    public var seconds: Double { Double(frames) / SpeechAudioEncoder.sampleRate }
  }

  public enum Failure: Error, Equatable {
    /// There were no samples to encode.
    case emptyInput
    /// The destination already exists; the encoder never replaces a file.
    case destinationExists
    /// The destination could not be created (POSIX error number).
    case reserveFailed(Int32)
    /// The source is not a readable 16 kHz mono file.
    case unsupportedSource
    /// The system encoder could not be created or refused the audio.
    case encodeFailed
    /// The finished file does not decode to the expected length (in frames).
    case verificationFailed(expectedFrames: Int64, decodedFrames: Int64)
  }

  public static let sampleRate: Double = 16_000
  /// The largest accepted difference between source and decoded length (plan §3.1: 50 ms).
  public static let durationToleranceFrames: Int64 = 800
  /// Frames processed per chunk, so a long meeting track is never loaded whole.
  static let chunkFrames: AVAudioFrameCount = 65_536

  /// Encodes Float32 16 kHz mono samples (a dictation's captured audio).
  public static func encode(samples: [Float], purpose: Purpose, to destination: URL) throws
    -> Output
  {
    guard !samples.isEmpty else { throw Failure.emptyInput }
    let format = try processingFormat()
    return try writeVerified(
      to: destination, purpose: purpose, expectedFrames: Int64(samples.count)
    ) {
      writer in
      var offset = 0
      while offset < samples.count {
        try Task.checkCancellation()
        let count = min(Int(chunkFrames), samples.count - offset)
        guard
          let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count))
        else { throw Failure.encodeFailed }
        buffer.frameLength = AVAudioFrameCount(count)
        samples.withUnsafeBufferPointer { source in
          buffer.floatChannelData![0].update(from: source.baseAddress! + offset, count: count)
        }
        try writer.write(from: buffer)
        offset += count
      }
    }
  }

  /// Encodes a 16 kHz mono audio file (a meeting track segment) chunk by chunk.
  public static func encode(fileAt source: URL, purpose: Purpose, to destination: URL) throws
    -> Output
  {
    let reader: AVAudioFile
    do {
      reader = try AVAudioFile(
        forReading: source, commonFormat: .pcmFormatFloat32, interleaved: false)
    } catch {
      throw Failure.unsupportedSource
    }
    guard reader.processingFormat.sampleRate == sampleRate,
      reader.processingFormat.channelCount == 1
    else { throw Failure.unsupportedSource }
    guard reader.length > 0 else { throw Failure.emptyInput }
    let format = try processingFormat()
    return try writeVerified(to: destination, purpose: purpose, expectedFrames: reader.length) {
      writer in
      guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkFrames) else {
        throw Failure.encodeFailed
      }
      while reader.framePosition < reader.length {
        try Task.checkCancellation()
        try reader.read(into: buffer, frameCount: chunkFrames)
        guard buffer.frameLength > 0 else { break }
        try writer.write(from: buffer)
      }
    }
  }

  // MARK: - Shared

  private static func processingFormat() throws -> AVAudioFormat {
    guard
      let format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)
    else { throw Failure.encodeFailed }
    return format
  }

  /// Creates the destination, lets `fill` write into it, closes the writer, then decodes the
  /// whole file and compares its frame count with `expectedFrames`. Removes the destination on
  /// every failure, including cancellation.
  private static func writeVerified(
    to destination: URL, purpose: Purpose, expectedFrames: Int64,
    fill: (AVAudioFile) throws -> Void
  ) throws -> Output {
    let fm = FileManager.default
    // Exclusive reservation (as `MeetingTrackWriter` reserves segments): only the call that
    // creates the empty 0600 file owns it, writes into it and may remove it on failure. Another
    // call aimed at the same path gets `destinationExists` and touches nothing.
    let fd = Darwin.open(destination.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
    guard fd >= 0 else {
      let code = errno
      if code == EEXIST { throw Failure.destinationExists }
      throw Failure.reserveFailed(code)
    }
    Darwin.close(fd)
    do {
      // The writer lives only inside this scope: releasing it finalizes the file before the
      // verification below reopens it.
      do {
        let writer: AVAudioFile
        do {
          writer = try AVAudioFile(
            forWriting: destination,
            settings: [
              // Stated, not inferred: the archive encodes into `<id>.<uuid>.m4a.partial`.
              AVAudioFileTypeKey: kAudioFileM4AType,
              AVFormatIDKey: kAudioFormatMPEG4AAC,
              AVSampleRateKey: sampleRate,
              AVNumberOfChannelsKey: 1,
              AVEncoderBitRateKey: purpose.bitRate,
            ],
            commonFormat: .pcmFormatFloat32, interleaved: false)
        } catch {
          throw Failure.encodeFailed
        }
        try fill(writer)
      }
      let decoded = try decodedFrames(at: destination)
      guard abs(decoded - expectedFrames) <= durationToleranceFrames else {
        throw Failure.verificationFailed(expectedFrames: expectedFrames, decodedFrames: decoded)
      }
      let bytes = try (fm.attributesOfItem(atPath: destination.path)[.size] as? NSNumber)?
        .int64Value
      return Output(frames: decoded, bytes: bytes ?? 0)
    } catch {
      try? fm.removeItem(at: destination)
      throw error
    }
  }

  /// Frames actually read from the file, not the container's stated length.
  private static func decodedFrames(at url: URL) throws -> Int64 {
    let reader: AVAudioFile
    do {
      reader = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
    } catch {
      throw Failure.verificationFailed(expectedFrames: 0, decodedFrames: 0)
    }
    guard
      let buffer = AVAudioPCMBuffer(pcmFormat: reader.processingFormat, frameCapacity: chunkFrames)
    else { throw Failure.encodeFailed }
    var total: Int64 = 0
    while reader.framePosition < reader.length {
      try Task.checkCancellation()
      try reader.read(into: buffer, frameCount: chunkFrames)
      guard buffer.frameLength > 0 else { break }
      total += Int64(buffer.frameLength)
    }
    return total
  }
}
