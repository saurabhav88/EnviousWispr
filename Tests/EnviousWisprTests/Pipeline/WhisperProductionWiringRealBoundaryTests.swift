import EnviousWisprCore
@preconcurrency import FluidAudio
import Foundation
import Testing

@testable import EnviousWisprASR
@testable import EnviousWisprAppKit
@testable import EnviousWisprPipeline
@testable import EnviousWisprServices

/// #3735 chunk 7: the Whisper engine exactly as the app composes it — delivery registration,
/// `WhisperDeliveryWiring`, the factory's adapter with its memory-pressure binding — decoding
/// real speech with the real turbo Q8_0 model on Metal.
///
/// **What the user sees when this fails:** a Whisper dictation produces no text, a cancelled
/// dictation leaves the engine unusable for the next one, or the engine cannot load again
/// after it was unloaded while idle.
///
/// The model is admitted into a private temporary root (a clone of the #3705 evaluation copy,
/// verified by the delivery controller's own hash check), never the app's data. Skipped when
/// that copy is absent; a skip is not a pass.
@MainActor
@Suite("Whisper production wiring on the real model (#3735)", .serialized, .tags(.productOutcome))
struct WhisperProductionWiringRealBoundaryTests {

  nonisolated static let repoRoot = URL(filePath: #filePath)
    .deletingLastPathComponent()  // Pipeline
    .deletingLastPathComponent()  // EnviousWisprTests
    .deletingLastPathComponent()  // Tests
    .deletingLastPathComponent()  // repo root

  /// The #3705 evaluation copy, looked up in this checkout and then in the main checkout.
  nonisolated static var evaluationModel: URL {
    let relative = "artifacts/issue-3705-transcribecpp-eval/models/whisper-large-v3-turbo-Q8_0.gguf"
    let candidates = [
      repoRoot.appending(path: relative),
      repoRoot.deletingLastPathComponent().appending(path: "EnviousWispr").appending(
        path: relative),
    ]
    return candidates.first { FileManager.default.fileExists(atPath: $0.path) } ?? candidates[0]
  }

  nonisolated static var modelIsPresent: Bool {
    let size =
      (try? FileManager.default.attributesOfItem(atPath: evaluationModel.path)[.size])
      as? NSNumber
    return size?.int64Value == 886_381_760
  }

  /// Literal oracle: what the committed clip says (#3705 receipt, `WhisperGGUFRealDeliveryTests`).
  nonisolated static let expectedWords =
    "the quick brown fox jumps over the lazy dog while the morning sun rises slowly above the quiet hills"

  nonisolated static func words(_ text: String) -> String {
    text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).joined(separator: " ")
  }

  @Test(
    "an admitted model decodes real speech through the adapter; a cancelled decode leaves it reusable; an idle unload reloads",
    .enabled(if: Self.modelIsPresent),
    .tags(.realBoundary)
  )
  func admittedDecodeCancelReuseAndReload() async throws {
    let samples = try AudioConverter().resampleAudioFile(
      path: Self.repoRoot.appending(path: "scripts/freeze-suite/clips/normal-speech.wav").path)
    #expect(samples.count > 16_000)

    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("ew-3735-wiring-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let flags = try #require(TestDefaults.suite("ew-3735-wiring-flags-\(UUID().uuidString)"))
    let home = ModelDeliveryHome(
      engineMutationScope: .alwaysAllowedForTesting,
      manifestBundle: try #require(
        Bundle(url: Self.repoRoot.appendingPathComponent("Sources/EnviousWispr/Resources"))),
      appSupportOverride: root,
      deliveryFlagDefaults: flags)
    let registration = try #require(home.whisperRegistration)
    let entrypoint = try #require(registration.manifest.resolvedEntrypointPath)
    try FileManager.default.createDirectory(
      at: registration.installDirectory, withIntermediateDirectories: true)
    try FileManager.default.copyItem(
      at: Self.evaluationModel,
      to: registration.installDirectory.appendingPathComponent(entrypoint))

    let settings = SettingsManager(
      defaults: try #require(TestDefaults.suite("ew-3735-wiring-\(UUID().uuidString)")))
    settings.selectedBackend = .whisper
    let wired = WhisperDeliveryWiring.make(
      modelDelivery: home, settings: settings, engineMutationScope: .alwaysAllowedForTesting)
    // The controller's own admission: size and sha256 against the shipped manifest.
    #expect(await home.whisperHandle?.adoptIfPresent() == true)

    let occupancy = VendorDecodeOccupancy()
    let adapter = try #require(
      KernelAdapterFactory.makeWhisperAdapter(
        backend: wired.backend,
        languageDetector: LanguageDetector(),
        audioCaptureSessionIDSource: { 0 },
        engineMutationScope: .alwaysAllowedForTesting,
        vendorDecodeOccupancy: occupancy,
        deliveredModelIdentity: registration.manifest.identity.asrModelIdentity)
        as? WhisperEngineAdapter)
    #expect(adapter.memoryPressureBinding != nil, "the factory starts the pressure binding")

    // 1. Warm-up and a real decode through the adapter's batch path, automatic language.
    try await adapter.warmUp(modelReceipt: nil)
    #expect(adapter.readiness == .ready)
    #expect(Self.words(try await decode(adapter, samples)) == Self.expectedWords)

    // 2. Cancel a decode inside the native call, then decode again on the same engine.
    let long = Array(repeating: samples, count: 8).flatMap { $0 }
    let entered = BoundedWait.Signal()
    let take = Task {
      try await wired.backend.transcribe(
        audioSamples: long, options: TranscriptionOptions(language: "en"),
        onInferenceEntered: { entered.fire() })
    }
    // Every exit, including an expired wait below, requests cancellation; the executor aborts
    // the native run and frees nothing under it.
    defer { take.cancel() }
    // Bounded: a native call that never starts, or a cancel that never returns, fails the test.
    // On expiry the task is cancelled (the executor aborts the native run); nothing is freed
    // under it.
    try await BoundedWait.until(entered, deadline: .seconds(30))
    take.cancel()
    let cancelled = try await BoundedWait.result(of: take, deadline: .seconds(30))
    #expect(throws: CancellationError.self) { try cancelled.get() }
    // Occupancy through a cancel is the adapter test's subject
    // (`cancelledTakeHoldsOccupancyUntilNativeReturn`); this direct backend call is untracked.
    #expect(Self.words(try await decode(adapter, samples)) == Self.expectedWords)

    // 3. The idle unload, under the mutation claim, then a reload and another decode.
    adapter.applyUnloadPolicy(.immediately)
    let unloadTask = try #require(adapter.modelUnloadTaskForUnitTests)
    _ = try await BoundedWait.result(of: unloadTask, deadline: .seconds(30))
    #expect(adapter.readiness == .notReady)
    #expect(await wired.backend.isReady == false)
    try await adapter.warmUp(modelReceipt: nil)
    #expect(adapter.readiness == .ready)
    #expect(Self.words(try await decode(adapter, samples)) == Self.expectedWords)
    await wired.backend.unload()
  }

  @Test(
    "Faster Transcription on the real model: a rolling session decodes during the take and its flush is the transcript; a cancelled session leaves the engine reusable",
    .enabled(if: Self.modelIsPresent),
    .tags(.realBoundary)
  )
  func rollingSessionOnTheRealModel() async throws {
    let samples = try AudioConverter().resampleAudioFile(
      path: Self.repoRoot.appending(path: "scripts/freeze-suite/clips/normal-speech.wav").path)
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("ew-3735-rolling-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let home = ModelDeliveryHome(
      engineMutationScope: .alwaysAllowedForTesting,
      manifestBundle: try #require(
        Bundle(url: Self.repoRoot.appendingPathComponent("Sources/EnviousWispr/Resources"))),
      appSupportOverride: root,
      deliveryFlagDefaults: try #require(TestDefaults.suite("ew-3735-rolling-\(UUID().uuidString)")))
    let registration = try #require(home.whisperRegistration)
    let entrypoint = try #require(registration.manifest.resolvedEntrypointPath)
    try FileManager.default.createDirectory(
      at: registration.installDirectory, withIntermediateDirectories: true)
    try FileManager.default.copyItem(
      at: Self.evaluationModel, to: registration.installDirectory.appendingPathComponent(entrypoint))
    let settings = SettingsManager(
      defaults: try #require(TestDefaults.suite("ew-3735-rolling-s-\(UUID().uuidString)")))
    let wired = WhisperDeliveryWiring.make(
      modelDelivery: home, settings: settings, engineMutationScope: .alwaysAllowedForTesting)
    #expect(await home.whisperHandle?.adoptIfPresent() == true)
    let adapter = try #require(
      KernelAdapterFactory.makeWhisperAdapter(
        backend: wired.backend, languageDetector: LanguageDetector(),
        audioCaptureSessionIDSource: { 0 }, engineMutationScope: .alwaysAllowedForTesting,
        vendorDecodeOccupancy: VendorDecodeOccupancy(),
        deliveredModelIdentity: registration.manifest.identity.asrModelIdentity)
        as? WhisperEngineAdapter)
    try await adapter.warmUp(modelReceipt: nil)
    defer { Task { await wired.backend.unload() } }

    final class Entries: @unchecked Sendable {
      let lock = NSLock()
      var count = 0
      let first = BoundedWait.Signal()
      func hit() {
        lock.withLock { count += 1 }
        first.fire()
      }
    }
    let occupancy = VendorDecodeOccupancy()
    let audio = samples

    // 1. A session decodes during the take, then flushes.
    let entries = Entries()
    let session = try #require(
      await wired.backend.makeStreamingSession(
        options: TranscriptionOptions(language: "en"), vendorDecodeOccupancy: occupancy,
        onDecode: { entries.hit() }))
    await session.start(audioSamplesProvider: { (audio, audio.count) })
    try await BoundedWait.until(entries.first, deadline: .seconds(30))
    let result = try await BoundedWait.result(
      of: Task { await session.finalize(finalSamples: [], speechSegments: []) },
      deadline: .seconds(60)
    ).get()
    #expect(result.accepted)
    #expect(Self.words(result.text ?? "") == Self.expectedWords)
    #expect(entries.lock.withLock { entries.count } >= 1, "native entry observed")
    #expect(occupancy.isIdle)

    // 2. Cancel a session while its loop decode runs natively; the next session works.
    let cancelled = Entries()
    let doomed = try #require(
      await wired.backend.makeStreamingSession(
        options: TranscriptionOptions(language: "en"), vendorDecodeOccupancy: occupancy,
        onDecode: { cancelled.hit() }))
    await doomed.start(audioSamplesProvider: { (audio, audio.count) })
    try await BoundedWait.until(cancelled.first, deadline: .seconds(30))
    _ = try await BoundedWait.result(of: Task { await doomed.cancel() }, deadline: .seconds(60))
    #expect(occupancy.isIdle, "cancel returns only after the aborted native run ends")
    let reuse = try #require(
      await wired.backend.makeStreamingSession(
        options: TranscriptionOptions(language: "en"), vendorDecodeOccupancy: occupancy,
        onDecode: nil))
    await reuse.start(audioSamplesProvider: { (audio, audio.count) })
    let again = try await BoundedWait.result(
      of: Task { await reuse.finalize(finalSamples: [], speechSegments: []) },
      deadline: .seconds(60)
    ).get()
    #expect(Self.words(again.text ?? "") == Self.expectedWords)
  }

  /// One dictation through the adapter's batch path: begin, feed, speech range, finalize.
  private func decode(_ adapter: WhisperEngineAdapter, _ samples: [Float]) async throws -> String {
    let session = SessionID()
    try await adapter.beginSession(session, options: TranscriptionOptions(), streaming: false)
    let buffer = try #require(FakeAudioCapture.makeBuffer(samples: samples))
    adapter.acceptAudio(
      AudioBufferHandoff(
        buffer: buffer, frameCount: samples.count, sequence: 1, sessionID: session))
    adapter.observeSpeechSegments([SpeechSegment(startSample: 0, endSample: samples.count)])
    let outcome = await adapter.finalize(batchSamples: nil)
    guard case .transcript(let result) = outcome else {
      Issue.record("expected a transcript, got \(outcome)")
      return ""
    }
    return result.text
  }
}
