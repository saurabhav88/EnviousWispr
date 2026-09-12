import EnviousWisprCore
import FluidAudio
import Foundation

/// Runs the bundled offline diarizer over one file import's PCM and returns EnviousWispr's
/// own `SpeakerSegment` type — no FluidAudio type crosses this boundary (#1525 isolation).
///
/// Owns nothing about deadline, cancellation forwarding, or outcome shape: `SpeakerLabeler`
/// (Pipeline) is the one owner of that lifecycle (#2809 addendum §3 B3). This type's only
/// job is to run the vendor manager and translate its result.
struct OfflineSpeakerAnalyzer {
  private let manager: OfflineDiarizerManager

  init(config: OfflineDiarizerConfig = .default) {
    manager = OfflineDiarizerManager(config: config)
  }

  /// `models` must come from `BundledSpeakerModelLoader.load(in:)` — never
  /// `OfflineDiarizerManager.prepareModels()`, which would download.
  func initialize(models: OfflineDiarizerModels) {
    manager.initialize(models: models)
  }

  /// `onWindow` is progress-only observation; cancellation reaches the vendor's workers
  /// through Swift's own structured-concurrency propagation (#2809 addendum §2.5 item 4;
  /// no fork edit required at the pinned revision). `sampleRate` is asserted rather than
  /// used to resample: every caller in this app already resamples to the pipeline's own
  /// rate before this point, so a mismatch here is a caller defect, not a runtime path.
  func analyze(
    samples: [Float], sampleRate: Int, onWindow: @escaping @Sendable (Int, Int) -> Void
  ) async throws -> [SpeakerSegment] {
    precondition(
      sampleRate == 16000, "OfflineSpeakerAnalyzer expects 16kHz PCM, got \(sampleRate)Hz")
    let result = try await manager.process(audio: samples, progressCallback: onWindow)
    return result.segments.map {
      SpeakerSegment(
        speakerId: $0.speakerId,
        startMs: Int(($0.startTimeSeconds * 1000).rounded()),
        endMs: Int(($0.endTimeSeconds * 1000).rounded()),
        quality: $0.qualityScore
      )
    }
  }
}
