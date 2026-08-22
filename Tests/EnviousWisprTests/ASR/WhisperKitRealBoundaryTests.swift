import EnviousWisprCore
@preconcurrency import FluidAudio
import Foundation
import Testing

@testable import EnviousWisprASR
@testable import EnviousWisprModelDelivery

private enum WhisperKitRealBoundaryFixture {
  static let repoRoot = URL(filePath: #filePath)
    .deletingLastPathComponent()  // ASR
    .deletingLastPathComponent()  // EnviousWisprTests
    .deletingLastPathComponent()  // Tests
    .deletingLastPathComponent()  // repo root

  static let audioURL = repoRoot.appending(path: "scripts/freeze-suite/clips/normal-speech.wav")
  static let tokenizerFolder = repoRoot.appending(
    path: "Sources/EnviousWisprASR/Resources/WhisperTokenizer")
  static let appSupportRoot = FileManager.default.urls(
    for: .applicationSupportDirectory, in: .userDomainMask
  )[0]
  static let expectedTranscript =
    "the quick brown fox jumps over the lazy dog while the morning sun rises slowly above the quiet hills"

  static func productionRegistration() throws -> DeliveryRegistration {
    let manifestURL = repoRoot.appending(
      path: "Sources/EnviousWispr/Resources/whisperkit-delivery-manifest.json")
    let manifest = try DeliveryManifest.load(from: Data(contentsOf: manifestURL))
    return DeliveryRegistration(
      manifest: manifest,
      installDirectory: appSupportRoot.appending(
        path: "EnviousWispr/Models/whisper", directoryHint: .isDirectory),
      metadataDirectory: appSupportRoot.appending(
        path: "EnviousWispr/ModelDelivery", directoryHint: .isDirectory))
  }

  static func shippedModelIsAdmitted() async -> Bool {
    guard let registration = try? productionRegistration() else { return false }
    return await ModelDeliveryController().isAdmitted(registration)
  }

  static func normalizedWords(_ text: String) -> String {
    text.lowercased()
      .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
      .joined(separator: " ")
  }
}

/// #2142 real-boundary receipt for the shipped multilingual transcription engine.
///
/// **What the user sees when this fails:** a normal recording reaches the shipped
/// WhisperKit model but does not come back as the words they spoke.
///
/// The async resource gate uses the same manifest-backed admission authority as
/// the shipped app and reports this skipped when the model is not admitted.
/// Production's `WhisperKitConfig(download: false)` keeps the test read-only: it
/// cannot fetch or repair model bytes.
@Suite("Shipped WhisperKit transcription", .serialized, .tags(.productOutcome))
struct WhisperKitRealBoundaryTests {

  @Test(
    "the shipped multilingual model transcribes committed speech",
    .enabled("requires the shipped model to be admitted") {
      await WhisperKitRealBoundaryFixture.shippedModelIsAdmitted()
    },
    .tags(.realBoundary)
  )
  func shippedModelTranscribesCommittedSpeech() async throws {
    let samples = try AudioConverter().resampleAudioFile(
      path: WhisperKitRealBoundaryFixture.audioURL.path)
    let registration = try WhisperKitRealBoundaryFixture.productionRegistration()
    let controller = ModelDeliveryController()
    let backend = WhisperKitBackend(
      admittedModelFolder: {
        guard await controller.isAdmitted(registration) else { return nil }
        return registration.installDirectory.path
      },
      tokenizerFolderURL: WhisperKitRealBoundaryFixture.tokenizerFolder)

    let result: EnviousWisprCore.ASRResult
    do {
      try await backend.prepare()
      result = try await backend.transcribe(audioSamples: samples, options: .default)
      await backend.unload()
    } catch {
      await backend.unload()
      throw error
    }

    #expect(result.backendType == .whisperKit)
    #expect(
      WhisperKitRealBoundaryFixture.normalizedWords(result.text)
        == WhisperKitRealBoundaryFixture.expectedTranscript,
      "WhisperKit returned: \(result.text)"
    )
  }
}
