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

  /// A decoded file, plus the facts the Upload step shows about it.
  ///
  /// The metadata is read from the SAME asset the samples came from, in the same
  /// pass, so the line under the file name cannot describe a different file from
  /// the one about to be transcribed.
  public struct Decoded: Sendable {
    public let samples: [Float]
    /// Length of the source recording, for "1 hr 12 min".
    public let seconds: Double
    /// Size on disk, for "68.4 MB".
    public let byteCount: Int64
    /// The source codec as macOS reports it, for "AAC".
    public let codec: String
    /// The source sample rate, for "44.1 kHz".
    public let sampleRate: Double
    /// The source channel count, for "mono" / "stereo".
    public let channelCount: Int

    /// `public` so a test can build one. The decoder is the only production
    /// producer; a fixture that had to run a real file through it could not
    /// exercise the Upload screen's own states.
    public init(
      samples: [Float], seconds: Double, byteCount: Int64, codec: String, sampleRate: Double,
      channelCount: Int
    ) {
      self.samples = samples
      self.seconds = seconds
      self.byteCount = byteCount
      self.codec = codec
      self.sampleRate = sampleRate
      self.channelCount = channelCount
    }
  }

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
  public static func decode(url: URL) async throws -> Decoded {
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

    // **ONE track, not all of them.** `AVAssetReaderAudioMixOutput` MIXES every
    // track it is given into the single mono stream. A film or a recorded call
    // routinely carries several audio programs — an alternate language, a
    // commentary, a descriptive-audio track — and mixing them hands the engine
    // two people talking over each other in different languages, which is not
    // something a transcript can recover from. The first track is what every
    // player treats as the main program, and it is what the user hears when they
    // open the file. Found by cloud review.
    //
    // A user who wants a different track has no way to say so yet, and that is a
    // real limitation rather than a hidden one: the alternative on offer was
    // mixing all of them, which is worse in every case including this one.
    let chosenTrack = tracks.prefix(1)

    // The conversion is the READER's job, not a second pass of ours: these
    // settings make every source format arrive already downmixed to mono and
    // resampled to the rate the engines take.
    let output = AVAssetReaderAudioMixOutput(
      audioTracks: Array(chosenTrack),
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

    // Every field below describes the file for the screen; none of it is used
    // to transcribe. So each one degrades to a true-but-vague value rather than
    // failing the import: a track that reports no format description still gets
    // transcribed, it just describes itself as "audio".
    //
    // `formatDescriptions` is typed `[Any]`, so the cast is unavoidable, and it
    // is `as!` on purpose: the conditional form does not compile here, because
    // Swift rejects `as?` to a CoreFoundation type as a downcast that ALWAYS
    // SUCCEEDS ("conditional downcast to CoreFoundation type
    // 'CMAudioFormatDescription' will always succeed"). The compiler is
    // asserting the cast cannot fail; a defensive `as?` would be dead code the
    // build refuses.
    let format = tracks.first?.formatDescriptions.first as! CMAudioFormatDescription?
    let basic = format.flatMap(CMAudioFormatDescriptionGetStreamBasicDescription)
    let byteCount = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64
    return Decoded(
      samples: samples,
      seconds: Double(samples.count) / AudioConstants.sampleRate,
      byteCount: byteCount ?? 0,
      codec: format.map(Self.codecName(for:)) ?? "audio",
      sampleRate: basic?.pointee.mSampleRate ?? AudioConstants.sampleRate,
      channelCount: Int(basic?.pointee.mChannelsPerFrame ?? 1))
  }

  /// The source codec's four-character type, rendered the way a person names it.
  ///
  /// A short table rather than a general decoder: these are the formats the
  /// Upload step advertises, and an unknown one falls back to a word that is
  /// true of every file that reaches here rather than to a code nobody reads.
  private static func codecName(for description: CMAudioFormatDescription) -> String {
    switch CMFormatDescriptionGetMediaSubType(description) {
    case kAudioFormatMPEG4AAC, kAudioFormatMPEG4AAC_HE, kAudioFormatMPEG4AAC_HE_V2: return "AAC"
    case kAudioFormatMPEGLayer3: return "MP3"
    case kAudioFormatLinearPCM: return "PCM"
    case kAudioFormatAppleLossless: return "ALAC"
    case kAudioFormatFLAC: return "FLAC"
    case kAudioFormatOpus: return "Opus"
    default: return "audio"
    }
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
