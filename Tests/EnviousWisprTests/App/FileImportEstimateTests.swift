import Foundation
import Testing

@testable import EnviousWisprAppKit

/// #2817 — the "Ready in about N minutes" line before a Transcribe a File run.
///
/// **When this fails, the user is promised a time the run does not keep**: a 4-minute clip
/// that takes 13 s reads "about a minute", or a two-hour file reads shorter than it runs.
/// Product coverage. The rows pin the wording for the four file durations measured on
/// 2026-09-13 (Parakeet + EG-1, Start to stored); each comment carries the run's time.
@Suite(.tags(.productOutcome))
struct FileImportEstimateTests {

  @Test("the four measured runs read as they ran")
  func measuredRuns() {
    // Elon, 7,208.7 s of audio: 467 s measured (7.8 min); 7.6 min estimated.
    #expect(FileImportCoordinator.estimateText(audioSeconds: 7_208.7) == "about 8 minutes")
    // Interview, 2,902.7 s: 176 s measured (2.9 min); 3.06 min estimated.
    #expect(FileImportCoordinator.estimateText(audioSeconds: 2_902.7) == "about 3 minutes")
    // Ariana, 2,902.5 s: about 181 s measured (3.0 min).
    #expect(FileImportCoordinator.estimateText(audioSeconds: 2_902.5) == "about 3 minutes")
    // Short, 240.0 s: 13 s measured; the old parts arithmetic promised "about a minute".
    #expect(FileImportCoordinator.estimateText(audioSeconds: 240.0) == "under a minute")
  }

  @Test("the boundaries: the smallest 'about', and nothing chosen")
  func boundaries() {
    // 30 s of run is the rounding boundary: 473.7 s of audio at 3.8 s per minute.
    #expect(FileImportCoordinator.estimateText(audioSeconds: 474) == "about a minute")
    #expect(FileImportCoordinator.estimateText(audioSeconds: 473) == "under a minute")
    #expect(FileImportCoordinator.estimateText(audioSeconds: 0) == "under a minute")
  }

  @Test("one wording for the pre-run line and the live 'left' line")
  func oneWording() {
    #expect(ImportEstimateWording.text(seconds: 29) == "under a minute")
    #expect(ImportEstimateWording.text(seconds: 30) == "about a minute")
    #expect(ImportEstimateWording.text(seconds: 89) == "about a minute")
    #expect(ImportEstimateWording.text(seconds: 90) == "about 2 minutes")
    #expect(ImportEstimateWording.text(seconds: 3_600) == "about 60 minutes")
  }

  /// WhisperKit is the slower engine (30-second windows): the 120-minute file took 741 s from
  /// Start to stored on 2026-09-13 (6.2 s per audio minute) against 467 s on Parakeet.
  @Test("WhisperKit's estimate is longer than Parakeet's on the same file")
  func whisperKitEstimateIsLonger() {
    #expect(FileImportCoordinator.secondsPerAudioMinute(for: .whisperKit) == 6.2)
    #expect(FileImportCoordinator.secondsPerAudioMinute(for: .parakeet) == 3.8)
    #expect(FileImportCoordinator.estimateText(audioSeconds: 7_208.7, backend: .whisperKit) == "about 12 minutes")
    #expect(FileImportCoordinator.estimateText(audioSeconds: 7_208.7, backend: .parakeet) == "about 8 minutes")
    #expect(FileImportCoordinator.estimateText(audioSeconds: 2_902.5, backend: .whisperKit) == "about 5 minutes")
  }
}
