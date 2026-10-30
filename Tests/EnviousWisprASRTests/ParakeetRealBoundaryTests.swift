import EnviousWisprCore
@preconcurrency import FluidAudio
import Foundation
import Testing

@testable import EnviousWisprASR

/// #2714: internal rather than `private` — `ParakeetStreamingGenerationTests` in this same
/// target reuses `shippedModelIsInstalled`/`installDirectory` for its own real-model rows,
/// rather than a second hand-built path to the shipped model directory.
enum ParakeetRealBoundaryFixture {
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
    // Through the same owner production uses (#2695), not a hand-built path: a
    // receipt for "the shipped model transcribes" must read the directory the
    // app actually installs into, or it can pass against bytes nobody ships.
    ParakeetInstallLocation.directory(dataDirectory: StorageRoot.live.dataDirectory)
  }

  static var shippedModelIsInstalled: Bool {
    // #2697: OUR directory. This asked FluidAudio's shared tree whether the
    // shipped model was installed, so the receipt for "the shipped model
    // transcribes" was taken against another app's copy rather than against the
    // bytes EnviousWispr admits.
    return AsrModels.modelsExist(at: installDirectory, version: .v3)
  }

  /// #3546: Parakeet Ultra, the shipped model, in the directory the app installs it into.
  static var ultraInstallDirectory: URL {
    ParakeetInstallLocation.directory(for: .ultra, dataDirectory: StorageRoot.live.dataDirectory)
  }

  static var ultraIsInstalled: Bool {
    AsrModels.modelsExist(at: ultraInstallDirectory, version: .ultra)
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
    .tags(.realBoundary), .realBoundaryRun
  )
  func shippedModelTranscribesCommittedSpeech() async throws {
    let samples = try AudioConverter().resampleAudioFile(
      path: ParakeetRealBoundaryFixture.audioURL.path)
    let result: EnviousWisprCore.ASRResult = try await withParakeetOfflineModeExclusion {
      let backend = ParakeetBackend()
      do {
        try await backend.prepare(
          selection: ParakeetModelSelection(
            model: .v3, revision: nil, directory: ParakeetRealBoundaryFixture.installDirectory, cacheOnly: true,
            displayBytes: ParakeetModel.v3ShippedBytes, repairable: false, generation: 1),
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

  /// #3546: the same receipt on Parakeet Ultra.
  @Test(
    "the shipped Ultra model transcribes committed speech",
    .enabled(if: ParakeetRealBoundaryFixture.ultraIsInstalled),
    .tags(.realBoundary), .realBoundaryRun
  )
  func ultraTranscribesCommittedSpeech() async throws {
    let samples = try AudioConverter().resampleAudioFile(
      path: ParakeetRealBoundaryFixture.audioURL.path)
    let result: EnviousWisprCore.ASRResult = try await withParakeetOfflineModeExclusion {
      let backend = ParakeetBackend()
      do {
        try await backend.prepare(
          selection: ParakeetModelSelection(
            model: .ultra, revision: nil,
            directory: ParakeetRealBoundaryFixture.ultraInstallDirectory, cacheOnly: true,
            displayBytes: ParakeetModel.v3ShippedBytes, repairable: false, generation: 1),
          progressCallback: nil)
        let result = try await backend.transcribe(audioSamples: samples, options: .default)
        await backend.unload()
        return result
      } catch {
        await backend.unload()
        throw error
      }
    }
    #expect(
      ParakeetRealBoundaryFixture.normalizedWords(result.text)
        == ParakeetRealBoundaryFixture.expectedTranscript,
      "Parakeet Ultra returned: \(result.text)")
  }

  /// #3546: the manager's load hooks fire once per PHYSICAL load, on the real
  /// shipped model. Two loads asked for together join one physical load, so
  /// the upgrade policy counts one attempt and hears one success, carrying the
  /// request that load read.
  @Test(
    "a joined load counts one physical load and reports one ready publish",
    .enabled(if: ParakeetRealBoundaryFixture.shippedModelIsInstalled),
    .tags(.realBoundary), .realBoundaryRun
  )
  @MainActor
  func joinedLoadFiresEachHookOnce() async throws {
    try await withParakeetOfflineModeExclusion {
      let selection = ParakeetSelectionProvider()
      var before: [ParakeetModelSelection] = []
      var published: [ParakeetModelSelection] = []
      selection.beforePhysicalLoad = { before.append($0) }
      selection.didPublishLoad = { published.append($0) }
      let request = selection.select(
        model: .v3, revision: nil, directory: ParakeetRealBoundaryFixture.installDirectory,
        cacheOnly: true, displayBytes: ParakeetModel.v3ShippedBytes, repairable: false)
      let manager = ASRManager(
        engineMutationScope: .alwaysAllowedForTesting, parakeetSelection: selection)
      manager.setInitialBackendType(.parakeet)
      async let first: Void = manager.loadModel()
      async let second: Void = manager.loadModel()
      _ = try await (first, second)
      #expect(manager.isModelLoaded)
      #expect(before == [request])
      #expect(published == [request])
      await manager.unloadModel()
    }
  }
}
