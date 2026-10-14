import CryptoKit
@preconcurrency import FluidAudio
import Foundation
import Testing

@testable import EnviousWisprTranscribeCpp

/// #3735 chunk 0: the transcribe.cpp dependency proof through the real Xcode test target.
/// Decodes committed speech with the exact whisper-large-v3-turbo Q8_0 candidate on Metal,
/// and exercises both fork APIs (language log-probability, seek progress) on real audio.
///
/// The model is the #3705 evaluation copy until chunk 2 delivers it to the app's install
/// directory. Override from the shell with `TEST_RUNNER_EW_TRANSCRIBECPP_TURBO_GGUF` (Xcode strips
/// the forwarding prefix, so the test reads `EW_TRANSCRIBECPP_TURBO_GGUF`). Pinned by size, then
/// by sha256 inside each test.
private enum TranscribeCppRealBoundaryFixture {
  static let repoRoot = URL(filePath: #filePath)
    .deletingLastPathComponent()  // EnviousWisprASRTests
    .deletingLastPathComponent()  // Tests
    .deletingLastPathComponent()  // repo root

  static let audioURL = repoRoot.appending(path: "scripts/freeze-suite/clips/normal-speech.wav")

  /// sha256 b2e30cc286bc9f3aba4db9099fc7403543497c05ce7100d0d83091ddfd25a183 (#3705).
  static let expectedModelBytes: UInt64 = 886_381_760

  /// The #3705 evaluation copy (gitignored `artifacts/`), looked up in this checkout and
  /// then in the main checkout beside it (worktrees live next to it).
  static var modelPath: String {
    if let override = ProcessInfo.processInfo.environment["EW_TRANSCRIBECPP_TURBO_GGUF"] {
      return override
    }
    let relative = "artifacts/issue-3705-transcribecpp-eval/models/whisper-large-v3-turbo-Q8_0.gguf"
    let candidates = [
      repoRoot.appending(path: relative),
      repoRoot.deletingLastPathComponent().appending(path: "EnviousWispr").appending(path: relative),
    ]
    return (candidates.first { FileManager.default.fileExists(atPath: $0.path) } ?? candidates[0]).path
  }

  /// Binds the run to the approved #3705 turbo Q8_0 candidate, not merely a same-size file.
  static func requireExpectedModel() throws {
    let data = try Data(contentsOf: URL(filePath: modelPath), options: .mappedIfSafe)
    let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    try #require(
      digest == "b2e30cc286bc9f3aba4db9099fc7403543497c05ce7100d0d83091ddfd25a183",
      "requires the approved turbo Q8_0 model")
  }

  static var modelIsPresent: Bool {
    let size = (try? FileManager.default.attributesOfItem(atPath: modelPath)[.size]) as? NSNumber
    return size?.uint64Value == expectedModelBytes
  }
}

/// **What the user sees when this fails:** dictation in a language Parakeet does not cover
/// produces no text, because the transcribe.cpp engine cannot load or decode in the app.
@Suite("transcribe.cpp native boundary (real model, Metal)", .serialized, .tags(.productOutcome))
struct TranscribeCppRealBoundaryTests {

  @Test(
    "the turbo Q8_0 model decodes committed English speech, detects English, and reports bounded monotonic progress",
    .enabled(if: TranscribeCppRealBoundaryFixture.modelIsPresent),
    .tags(.realBoundary)
  )
  func decodesDetectsAndReportsProgress() throws {
    let samples = try AudioConverter().resampleAudioFile(
      path: TranscribeCppRealBoundaryFixture.audioURL.path)
    #expect(samples.count > 16_000)

    try TranscribeCppRealBoundaryFixture.requireExpectedModel()
    let session = try TranscribeCppSession(modelPath: TranscribeCppRealBoundaryFixture.modelPath)
    defer { session.close() }

    // Fork API 1: language log-probability on real audio.
    let observation = try session.detectLanguage(samples: samples)
    #expect(observation.code == "en")
    #expect(observation.logProb.isFinite)
    #expect(observation.logProb <= 0)
    #expect(exp(observation.logProb) > 0.5)

    // Fork API 2: seek progress, observed on a real auto-detect run.
    let recorder = ProgressRecorder()
    let result = try session.run(samples: samples, language: nil) { advanced, total in
      recorder.record(advanced: advanced, total: total)
    }
    let calls = recorder.snapshot()
    #expect(!calls.isEmpty, "no native progress callback was observed")
    var previous: Int64 = -1
    for call in calls {
      #expect(call.advanced >= previous, "progress went backwards")
      #expect(call.advanced <= call.total, "progress exceeded its total")
      previous = call.advanced
    }
    #expect(calls.last.map { $0.advanced == $0.total } == true)
    // The denominator is the clip's REAL mel frames (100,224 samples -> 626), not the
    // 3,000-frame padded window.
    for call in calls {
      #expect(call.total == 626)
      #expect(call.advanced >= 0)
    }

    // Real transcript content, native detection reported, segments timed.
    let words = result.text.lowercased()
      .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
      .joined(separator: " ")
    #expect(
      words
        == "the quick brown fox jumps over the lazy dog while the morning sun rises slowly above the quiet hills"
    )
    #expect(result.detectedLanguage == "en")
    #expect(!result.segments.isEmpty)
    #expect(result.segments.allSatisfy { $0.endMs >= $0.startMs })
  }

  @Test(
    "a forced language returns no native detected language and still decodes",
    .enabled(if: TranscribeCppRealBoundaryFixture.modelIsPresent),
    .tags(.realBoundary)
  )
  func forcedLanguageReportsNoDetection() throws {
    let samples = try AudioConverter().resampleAudioFile(
      path: TranscribeCppRealBoundaryFixture.audioURL.path)
    try TranscribeCppRealBoundaryFixture.requireExpectedModel()
    let session = try TranscribeCppSession(modelPath: TranscribeCppRealBoundaryFixture.modelPath)
    defer { session.close() }

    let result = try session.run(samples: samples, language: "en")
    #expect(result.detectedLanguage == nil)
    #expect(!result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
  }

  @Test(
    "an abort requested before the run stops it with the aborted status",
    .enabled(if: TranscribeCppRealBoundaryFixture.modelIsPresent),
    .tags(.realBoundary)
  )
  func abortStopsTheRun() throws {
    let samples = try AudioConverter().resampleAudioFile(
      path: TranscribeCppRealBoundaryFixture.audioURL.path)
    try TranscribeCppRealBoundaryFixture.requireExpectedModel()
    let session = try TranscribeCppSession(modelPath: TranscribeCppRealBoundaryFixture.modelPath)
    defer { session.close() }

    session.requestAbort()
    #expect {
      _ = try session.run(samples: samples, language: "en")
    } throws: { error in
      (error as? TranscribeCppError)?.isAborted == true
    }
    session.clearAbort()
    let result = try session.run(samples: samples, language: "en")
    #expect(!result.text.isEmpty)
  }
}

/// Progress arrives on the native running thread; record under a lock.
private final class ProgressRecorder: @unchecked Sendable {
  struct Call {
    let advanced: Int64
    let total: Int64
  }
  private let lock = NSLock()
  private var calls: [Call] = []
  func record(advanced: Int64, total: Int64) {
    lock.lock()
    calls.append(Call(advanced: advanced, total: total))
    lock.unlock()
  }
  func snapshot() -> [Call] {
    lock.lock()
    defer { lock.unlock() }
    return calls
  }
}
