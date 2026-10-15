import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprASR

/// #3546 §3.7 T1: the inference observation travels with one call and is committed by the
/// backend only when that call reaches the vendor. When this fails, telemetry credits a
/// model with a decode that never ran, or one caller's call fires another caller's
/// observation.
@Suite("ASRManager inference observer (#3546)", .tags(.observabilityContract))
@MainActor
struct ASRManagerInferenceObserverTests {

  final class Count: @unchecked Sendable {
    // Test-only counter; the lock makes it safe to bump from a backend actor.
    private let lock = NSLock()
    private var value = 0
    func bump() { lock.withLock { value += 1 } }
    var fired: Int { lock.withLock { value } }
  }

  private func loadedManager(_ backend: FakeASRBackend) async throws -> ASRManager {
    let manager = ASRManager(
      engineMutationScope: .alwaysAllowedForTesting,
      parakeetSelection: ParakeetSelectionProvider(), parakeetBackendFactory: { backend })
    try await manager.loadModel()
    try #require(manager.isModelLoaded)
    return manager
  }

  @Test("a decode that reaches the backend fires its own observation once")
  func firesOnceAtTheVendorDecode() async throws {
    let manager = try await loadedManager(FakeASRBackend(initiallyReady: false))
    let count = Count()
    _ = try await manager.transcribe(
      audioSamples: [0.1, 0.2], options: .default, onInferenceEntered: { count.bump() })
    #expect(count.fired == 1)
    _ = try await manager.transcribe(audioSamples: [0.1, 0.2], options: .default)
    #expect(count.fired == 1, "a later call without an observation fires nothing")
  }

  @Test("a decode cancelled before the vendor fires nothing")
  func cancelledDecodeFiresNothing() async throws {
    let manager = try await loadedManager(FakeASRBackend(initiallyReady: false))
    let count = Count()
    let task = Task { @MainActor in
      withUnsafeCurrentTask { $0?.cancel() }
      return try await manager.transcribe(
        audioSamples: [0.1], options: .default, onInferenceEntered: { count.bump() })
    }
    await #expect(throws: CancellationError.self) { _ = try await task.value }
    #expect(count.fired == 0)
  }

  /// The real backends refuse an unready call before their commit point. When this fails, a
  /// take whose model was not loaded is reported as having reached inference.
  @Test("a real backend that is not ready never fires the observation")
  func unreadyRealBackendsFireNothing() async throws {
    let count = Count()
    await #expect(throws: ASRError.self) {
      _ = try await ParakeetBackend().transcribe(
        audioSamples: [0.1], options: .default, onInferenceEntered: { count.bump() })
    }
    await #expect(throws: ASRError.self) {
      _ = try await TranscribeCppWhisperBackend(
        driver: LiveWhisperExecutorDriver(), modelVariant: "whisper-large-v3-turbo-Q8_0",
        admittedModelPath: { nil }
      ).transcribe(
        audioSamples: [0.1], options: .default, onInferenceEntered: { count.bump() })
    }
    #expect(count.fired == 0)
  }
}
