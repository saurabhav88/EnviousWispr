import EnviousWisprCore
@preconcurrency import FluidAudio
import Foundation
import Testing

@testable import EnviousWisprASR
@testable import EnviousWisprModelDelivery

private enum ShippedBackendLatencyFixture {
  static let runCount = 5
  static let budgetSeconds = 1.0

  static let repoRoot = URL(filePath: #filePath)
    .deletingLastPathComponent()  // ASR
    .deletingLastPathComponent()  // EnviousWisprTests
    .deletingLastPathComponent()  // Tests
    .deletingLastPathComponent()  // repo root

  static let audioURL = repoRoot.appending(path: "scripts/freeze-suite/clips/normal-speech.wav")
  static let tokenizerFolder = repoRoot.appending(
    path: "Sources/EnviousWisprASR/Resources/WhisperTokenizer")
  static let expectedTranscript =
    "the quick brown fox jumps over the lazy dog while the morning sun rises slowly above the quiet hills"

  static var parakeetIsInstalled: Bool {
    AsrModels.modelsExist(at: AsrModels.defaultCacheDirectory(for: .v3), version: .v3)
  }

  static func whisperKitRegistration() throws -> DeliveryRegistration {
    let manifestURL = repoRoot.appending(
      path: "Sources/EnviousWispr/Resources/whisperkit-delivery-manifest.json")
    let manifest = try DeliveryManifest.load(from: Data(contentsOf: manifestURL))
    let appSupport = FileManager.default.urls(
      for: .applicationSupportDirectory, in: .userDomainMask)[0]
    return DeliveryRegistration(
      manifest: manifest,
      installDirectory: appSupport.appending(
        path: "EnviousWispr/Models/whisper", directoryHint: .isDirectory),
      metadataDirectory: appSupport.appending(
        path: "EnviousWispr/ModelDelivery", directoryHint: .isDirectory))
  }

  static func whisperKitIsAdmitted() async -> Bool {
    guard let registration = try? whisperKitRegistration() else { return false }
    return await ModelDeliveryController().isAdmitted(registration)
  }

  static func normalizedWords(_ text: String) -> String {
    text.lowercased()
      .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
      .joined(separator: " ")
  }

  static func requireExpectedTranscript(
    _ result: EnviousWisprCore.ASRResult, backend: String
  ) {
    #expect(
      normalizedWords(result.text) == expectedTranscript,
      "\(backend) returned: \(result.text)")
  }

  static func requireBudget(_ timings: [TimeInterval], backend: String) {
    #expect(timings.count == runCount)
    let sorted = timings.sorted()
    // Nearest-rank p95. With five samples this deliberately selects the maximum,
    // so one slow measured decode cannot hide behind interpolation.
    let index = min(sorted.count - 1, Int(ceil(0.95 * Double(sorted.count))) - 1)
    let p95 = sorted[index]
    let formattedRuns = timings.map { String(format: "%.3f", $0) }
    let formattedP95 = String(format: "%.3f", p95)
    let formattedBudget = String(format: "%.3f", budgetSeconds)
    print(
      "TRANSCRIPTION BUDGET \(backend): runs=\(formattedRuns) "
        + "p95=\(formattedP95)s budget=\(formattedBudget)s")
    #expect(
      p95 < budgetSeconds,
      "\(backend) transcription p95 was \(formattedP95)s; budget is under 1.000s")
  }
}

/// #2142 real-boundary receipts for the product's sub-second transcription claim.
///
/// Model preparation and one warm-up decode happen before measurement. Each
/// receipt then checks five real production-backend decodes and uses the
/// backend's own `processingTime`, which surrounds model inference only. A
/// missing model skips on hosted CI; a skipped receipt is not release evidence.
@Suite("Shipped backend transcription budget", .serialized, .tags(.productOutcome))
struct ShippedBackendLatencyTests {

  @Test(
    "Parakeet p95 stays under one second after warm-up",
    .enabled(if: ShippedBackendLatencyFixture.parakeetIsInstalled),
    .tags(.realBoundary)
  )
  func parakeetP95StaysUnderOneSecond() async throws {
    let originalOfflineMode = ModelHub.offlineMode
    ModelHub.offlineMode = true
    defer { ModelHub.offlineMode = originalOfflineMode }

    let samples = try AudioConverter().resampleAudioFile(
      path: ShippedBackendLatencyFixture.audioURL.path)
    let backend = ParakeetBackend()
    do {
      try await backend.prepare(cacheOnly: true, progressCallback: nil)
      let warmup = try await backend.transcribe(audioSamples: samples, options: .default)
      ShippedBackendLatencyFixture.requireExpectedTranscript(warmup, backend: "Parakeet warm-up")

      var timings: [TimeInterval] = []
      for _ in 0..<ShippedBackendLatencyFixture.runCount {
        let result = try await backend.transcribe(audioSamples: samples, options: .default)
        ShippedBackendLatencyFixture.requireExpectedTranscript(result, backend: "Parakeet")
        #expect(result.backendType == .parakeet)
        timings.append(result.processingTime)
      }
      ShippedBackendLatencyFixture.requireBudget(timings, backend: "Parakeet")
      await backend.unload()
    } catch {
      await backend.unload()
      throw error
    }
  }

  @Test(
    "WhisperKit p95 stays under one second after warm-up",
    .enabled("requires the shipped model to be admitted") {
      await ShippedBackendLatencyFixture.whisperKitIsAdmitted()
    },
    .tags(.realBoundary)
  )
  func whisperKitP95StaysUnderOneSecond() async throws {
    let samples = try AudioConverter().resampleAudioFile(
      path: ShippedBackendLatencyFixture.audioURL.path)
    let registration = try ShippedBackendLatencyFixture.whisperKitRegistration()
    let controller = ModelDeliveryController()
    let backend = WhisperKitBackend(
      admittedModelFolder: {
        guard await controller.isAdmitted(registration) else { return nil }
        return registration.installDirectory.path
      },
      tokenizerFolderURL: ShippedBackendLatencyFixture.tokenizerFolder)

    do {
      try await backend.prepare()
      let warmup = try await backend.transcribe(audioSamples: samples, options: .default)
      ShippedBackendLatencyFixture.requireExpectedTranscript(warmup, backend: "WhisperKit warm-up")

      var timings: [TimeInterval] = []
      for _ in 0..<ShippedBackendLatencyFixture.runCount {
        let result = try await backend.transcribe(audioSamples: samples, options: .default)
        ShippedBackendLatencyFixture.requireExpectedTranscript(result, backend: "WhisperKit")
        #expect(result.backendType == .whisperKit)
        timings.append(result.processingTime)
      }
      ShippedBackendLatencyFixture.requireBudget(timings, backend: "WhisperKit")
      await backend.unload()
    } catch {
      await backend.unload()
      throw error
    }
  }
}
