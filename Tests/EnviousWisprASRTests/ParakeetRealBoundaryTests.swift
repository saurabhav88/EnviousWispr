import EnviousWisprCore
@preconcurrency import FluidAudio
import Foundation
import Testing

@testable import EnviousWisprASR

private enum ParakeetRealBoundaryFixture {
  static let repoRoot = URL(filePath: #filePath)
    .deletingLastPathComponent()  // EnviousWisprASRTests
    .deletingLastPathComponent()  // Tests
    .deletingLastPathComponent()  // repo root

  static let audioURL = repoRoot.appending(path: "scripts/freeze-suite/clips/normal-speech.wav")
  static let expectedTranscript =
    "the quick brown fox jumps over the lazy dog while the morning sun rises slowly above the quiet hills"

  /// #2697: resolved here rather than by a property on the location type. That
  /// property was deleted because it answered from an assumed root wherever it
  /// was reached; a test naming the root out loud is the honest replacement.
  static var installDirectory: URL {
    ParakeetInstallLocation.directory(
      appSupport: FileManager.default.urls(
        for: .applicationSupportDirectory, in: .userDomainMask)[0])
  }

  static var shippedModelIsInstalled: Bool {
    // #2697: OUR directory. This asked FluidAudio's shared tree whether the
    // shipped model was installed, so the receipt for "the shipped model
    // transcribes" was taken against another app's copy rather than against the
    // bytes EnviousWispr admits.
    return AsrModels.modelsExist(at: installDirectory, version: .v3)
  }

  static func normalizedWords(_ text: String) -> String {
    text.lowercased()
      .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
      .joined(separator: " ")
  }
}

/// #2142 real-boundary receipt for the default shipped transcription engine.
///
/// **What the user sees when this fails:** a normal recording reaches the shipped
/// Parakeet model but does not come back as the words they spoke.
///
/// The resource gate runs this on a developer machine after EnviousWispr has
/// installed the model and reports it skipped on hosted CI. `cacheOnly: true`
/// keeps the test read-only: it cannot download, repair, or replace model bytes.
@Suite("Shipped Parakeet transcription", .serialized, .tags(.productOutcome))
struct ParakeetRealBoundaryTests {

  @Test(
    "the shipped model transcribes committed speech",
    .enabled(if: ParakeetRealBoundaryFixture.shippedModelIsInstalled),
    .tags(.realBoundary)
  )
  func shippedModelTranscribesCommittedSpeech() async throws {
    let samples = try AudioConverter().resampleAudioFile(
      path: ParakeetRealBoundaryFixture.audioURL.path)
    let result: EnviousWisprCore.ASRResult = try await withParakeetOfflineModeExclusion {
      let backend = ParakeetBackend()
      do {
        try await backend.prepare(
          cacheOnly: true, modelDirectory: ParakeetRealBoundaryFixture.installDirectory,
          progressCallback: nil)
        let result = try await backend.transcribe(audioSamples: samples, options: .default)
        await backend.unload()
        return result
      } catch {
        await backend.unload()
        throw error
      }
    }

    #expect(result.backendType == .parakeet)
    #expect(
      ParakeetRealBoundaryFixture.normalizedWords(result.text)
        == ParakeetRealBoundaryFixture.expectedTranscript,
      "Parakeet returned: \(result.text)"
    )
  }
}
