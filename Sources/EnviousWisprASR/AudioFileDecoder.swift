import AVFoundation
import EnviousWisprCore
import Foundation

/// #2648 — turns a file the user picked into the samples the ASR engines already
/// take: 16 kHz, mono, `Float32`.
///
/// **The one genuinely new thing this feature needs is an audio input that is
/// not the microphone.** Everything downstream of ASR already exists. A file has
/// failure modes a live microphone does not — an unsupported codec, a corrupt
/// container, a video with no audio track, a zero-byte file — and the founder's
/// audio priority order puts a plain honest sentence on each of them rather than
/// a fallback.
///
/// **`AVAssetReader`, not `AVAudioFile`.** `BenchmarkSuite.loadAudioFile` is the
/// existing decode in this repo and it is the wrong shape here for two reasons.
/// It reads the WHOLE file into memory at the SOURCE format before converting,
/// which for a 3-hour 48 kHz stereo recording is gigabytes; and `AVAudioFile`
/// cannot open a video container at all, while "any audio or video file macOS
/// can decode" is the feature's stated scope. `AVAssetReader` handles both, and
/// its output settings do the downmix and resample as it goes, so the file is
/// read once and converted in the same pass.
///
/// **What it still holds in memory is the RESULT**, at 16 kHz mono float: about
/// 230 MB per hour of audio, so roughly 690 MB for the three-hour case named as a
/// ship criterion on #2648. That number is measured arithmetic, not a measured
/// run; the three-hour run with peak memory recorded is still owed before "any
/// length" is published.
public enum AudioFileDecoder {

  /// Why a file was refused, in the terms a sentence can be written from. Every
  /// case is something the user can act on or at least understand; none of them
  /// is a fallback.
  public enum Rejection: Error, Equatable, Sendable {
    /// Nothing at that path, or the file cannot be opened at all.
    case unreadable
    /// The file opened and carries no audio: a Keynote deck, a video-only clip,
    /// an image. The one case a person is most likely to hit by mistake.
    case noAudioTrack
    /// The file has an audio track that decodes to nothing — a zero-length
    /// recording, or a truncated file whose audio never starts.
    case noAudio
    /// The decoder started and then failed. Carries the underlying reason for
    /// the log, never for the user.
    case decodeFailed(String)
  }

  /// Decodes `url` to 16 kHz mono `Float32`, in one pass.
  ///
  /// Cancellation is cooperative and checked once per read: a user who presses
  /// Stop during a long decode stops paying for it, and the partial result is
  /// discarded rather than returned, because half a recording transcribed as if
  /// it were the whole one is worse than no result.
  ///
  /// **A TRUNCATED FILE IS NOT DETECTABLE HERE, and a guard for it was built and
  /// then removed.** The intuition was that a cut file still declares its
  /// original length, so declared duration and decoded samples would disagree.
  /// Measured on a 3-second 16 kHz WAV cut to a third of its bytes:
  /// `AVAsset.load(.duration)` returned **0.957 s** and the decode returned
  /// **15,317 samples**, which is 0.957 s. AVFoundation derives the duration
  /// from the bytes that are present, so the two agree by construction and no
  /// threshold between them can ever fire.
  ///
  /// What that means for the user is worth stating plainly rather than guarding:
  /// **a truncated recording is indistinguishable from a shorter recording**, to
  /// this decoder and to any other. We transcribe what the file contains. A cut
  /// that destroys the header is refused, because the file will not open at all;
  /// a cut that only removes audio is not, because there is nothing to detect.
  public static func decode(url: URL) async throws -> [Float] {
    let asset = AVURLAsset(url: url)

    let tracks: [AVAssetTrack]
    do {
      tracks = try await asset.loadTracks(withMediaType: .audio)
    } catch {
      // A missing file, an unreadable one and an unsupported container all
      // arrive here. They are one sentence to the user either way: we could not
      // read this file.
      throw Rejection.unreadable
    }
    guard !tracks.isEmpty else { throw Rejection.noAudioTrack }

    let reader: AVAssetReader
    do {
      reader = try AVAssetReader(asset: asset)
    } catch {
      throw Rejection.unreadable
    }

    // The conversion is the READER's job, not a second pass of ours: these
    // settings make every source format arrive already downmixed to mono and
    // resampled to the rate the engines take.
    let output = AVAssetReaderAudioMixOutput(
      audioTracks: tracks,
      audioSettings: [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVSampleRateKey: AudioConstants.sampleRate,
        AVNumberOfChannelsKey: 1,
        AVLinearPCMBitDepthKey: 32,
        AVLinearPCMIsFloatKey: true,
        AVLinearPCMIsBigEndianKey: false,
        AVLinearPCMIsNonInterleaved: false,
      ])
    guard reader.canAdd(output) else { throw Rejection.decodeFailed("reader_rejected_output") }
    reader.add(output)
    guard reader.startReading() else {
      throw Rejection.decodeFailed(reader.error.map(String.init(describing:)) ?? "start_failed")
    }

    var samples: [Float] = []
    while let buffer = output.copyNextSampleBuffer() {
      try Task.checkCancellation()
      appendSamples(from: buffer, into: &samples)
      CMSampleBufferInvalidate(buffer)
    }

    switch reader.status {
    case .completed:
      break
    case .failed, .cancelled, .reading, .unknown:
      // A truncated file ends here rather than at `.completed`. Refuse rather
      // than return what was read: a partial transcript presented as a whole one
      // is the failure this feature must not have.
      throw Rejection.decodeFailed(reader.error.map(String.init(describing:)) ?? "read_incomplete")
    @unknown default:
      throw Rejection.decodeFailed("unknown_reader_status")
    }

    guard !samples.isEmpty else { throw Rejection.noAudio }
    return samples
  }

  /// Copies one sample buffer's audio into `samples`.
  ///
  /// The settings above pin the format to non-interleaved mono `Float32`, so
  /// there is exactly one channel to read and no per-sample conversion to do
  /// here. A buffer with no data block is skipped rather than treated as an
  /// error: it is how a decoder reports a gap, not a failure.
  private static func appendSamples(from buffer: CMSampleBuffer, into samples: inout [Float]) {
    guard let blockBuffer = CMSampleBufferGetDataBuffer(buffer) else { return }
    var lengthAtOffset = 0
    var totalLength = 0
    var dataPointer: UnsafeMutablePointer<CChar>?
    guard
      CMBlockBufferGetDataPointer(
        blockBuffer, atOffset: 0, lengthAtOffsetOut: &lengthAtOffset,
        totalLengthOut: &totalLength, dataPointerOut: &dataPointer) == noErr,
      let dataPointer
    else { return }

    let count = totalLength / MemoryLayout<Float>.size
    guard count > 0 else { return }
    dataPointer.withMemoryRebound(to: Float.self, capacity: count) { floats in
      samples.append(contentsOf: UnsafeBufferPointer(start: floats, count: count))
    }
  }
}
