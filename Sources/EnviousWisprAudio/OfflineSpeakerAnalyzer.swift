import EnviousWisprCore
import FluidAudio
import Foundation

/// Runs the bundled offline diarizer over one file import's PCM and returns EnviousWispr's
/// own `SpeakerSegment` type — no FluidAudio type crosses this boundary (#1525 isolation).
///
/// Owns nothing about deadline, cancellation forwarding, or outcome shape: `SpeakerLabeler`
/// (Pipeline) is the one owner of that lifecycle (#2809 addendum §3 B3). This type's only
/// job is to run the vendor manager and translate its result.
package struct OfflineSpeakerAnalyzer {
  private let manager: OfflineDiarizerManager

  package init(config: OfflineDiarizerConfig = .default) {
    manager = OfflineDiarizerManager(config: config)
  }

  /// `models` must come from `BundledSpeakerModelLoader.load(in:)` — never
  /// `OfflineDiarizerManager.prepareModels()`, which would download.
  package func initialize(models: OfflineDiarizerModels) {
    manager.initialize(models: models)
  }

  /// `onWindow` is progress-only observation; cancellation reaches the vendor's workers
  /// through Swift's own structured-concurrency propagation (#2809 addendum §2.5 item 4;
  /// no fork edit required at the pinned revision). `sampleRate` is asserted rather than
  /// used to resample: every caller in this app already resamples to the pipeline's own
  /// rate before this point, so a mismatch here is a caller defect, not a runtime path.
  package func analyze(
    samples: [Float], sampleRate: Int, onWindow: @escaping @Sendable (Int, Int) -> Void
  ) async throws -> [SpeakerSegment] {
    precondition(
      sampleRate == 16000, "OfflineSpeakerAnalyzer expects 16kHz PCM, got \(sampleRate)Hz")
    let result = try await manager.process(audio: samples, progressCallback: onWindow)
    return Self.segments(result)
  }

  /// #3972 R22: the same analysis over a lazily read source (an EnviousMeet track read from its
  /// segment files, gaps as silence), so a multi-hour track never becomes one array here. The
  /// vendor still keeps its own segmentation and embeddings for the whole track (memory NOT
  /// bounded by this; measured in the bake-off).
  package func analyze(
    meetingTrack audio: MeetingTrackAudio, onWindow: @escaping @Sendable (Int, Int) -> Void
  ) async throws -> [SpeakerSegment] {
    let result = try await manager.process(
      audioSource: CachedMeetingSource(audio: audio), audioLoadingSeconds: 0,
      progressCallback: onWindow)
    return Self.segments(result)
  }

  /// The meeting track as the diarizer's input, decoding one segment file at a time and keeping
  /// the last one decoded (#3972 C3b). The diarizer asks for many small overlapping windows;
  /// reopening a 60 s file for each one made a 5-hour track miss its deadline (measured: 214 s
  /// against 155 s). Memory: one segment, 960,000 floats (3.8 MB). Gaps read as zeros; a failed
  /// read throws, as `MeetingTrackAudio.read` does.
  final class CachedMeetingSource: AudioSampleSource, @unchecked Sendable {
    private let audio: MeetingTrackAudio
    private let lock = NSLock()
    private var cachedIndex: Int?
    private var cached: [Float] = []

    init(audio: MeetingTrackAudio) { self.audio = audio }

    var sampleCount: Int { audio.endSample }

    func copySamples(into destination: UnsafeMutablePointer<Float>, offset: Int, count: Int) throws {
      guard count > 0 else { return }
      destination.initialize(repeating: 0, count: count)
      let end = offset + count
      lock.lock()
      defer { lock.unlock() }
      for (index, segment) in audio.segments.enumerated()
      where segment.endSample > offset && segment.readStartSample < end {
        let from = max(offset, segment.readStartSample)
        let to = min(end, segment.endSample)
        guard to > from else { continue }
        if cachedIndex != index {
          cached = try audio.read(from: segment.startSample, count: segment.frameCount)
          cachedIndex = index
        }
        cached.withUnsafeBufferPointer { all in
          (destination + (from - offset)).update(
            from: all.baseAddress! + (from - segment.startSample), count: to - from)
        }
      }
    }
  }

  private static func segments(_ result: DiarizationResult) -> [SpeakerSegment] {
    result.segments.map {
      SpeakerSegment(
        speakerId: $0.speakerId,
        startMs: Int(($0.startTimeSeconds * 1000).rounded()),
        endMs: Int(($0.endTimeSeconds * 1000).rounded()),
        quality: $0.qualityScore
      )
    }
  }
}
