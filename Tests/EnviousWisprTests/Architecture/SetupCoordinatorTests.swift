@preconcurrency import AVFoundation
import EnviousWisprASR
import EnviousWisprCore
import Testing

@testable import EnviousWisprAppKit

/// Unit tests for SetupCoordinator's preload observation behavior.
///
/// SetupCoordinator owns the WhisperKit preload observer that previously lived
/// on the former root state. The observer is gated by two signals: `asrManager.activeBackendType`
/// (must be `.whisperKit`) and `whisperKitSetup.setupState` (must reach `.ready`).
/// When both are satisfied, the injected `preloadAction` closure fires once.
///
/// These tests exercise the gating without touching any real WhisperKit / Ollama
/// state — the closure-based seam is the whole point of moving this code off
/// the former root state.
@Suite @MainActor
struct SetupCoordinatorTests {

  /// With setup forced `.ready`, the parakeet backend guard is the sole preload
  /// suppressor: an active parakeet backend must skip preload even when WhisperKit
  /// setup is ready. Deleting or inverting the backend guard makes preload fire
  /// for parakeet → this test goes red. (Before #898 both tests used a parakeet
  /// backend whose setup could never reach `.ready`, so the readiness gate alone
  /// guaranteed count == 0 and the backend guard was never exercised.)
  @Test(
    .bug(
      "https://github.com/saurabhav88/EnviousWispr/issues/898", "parakeet backend guard untested"))
  func parakeetBackendSkipsPreloadWhenReady() async throws {
    let fakeASR = FakeASRManager(backend: .parakeet)
    let counter = InvocationCounter()
    let coord = SetupCoordinator(
      asrManager: fakeASR,
      setupStateReader: { .ready },
      preloadAction: { @MainActor in counter.increment() }
    )

    coord.startPreloadObservation()
    await drainMainActorTasks()

    #expect(
      counter.count == 0,
      "preloadAction must not fire for a parakeet backend even when setup is .ready"
    )
  }

  /// With setup forced `.ready` and WhisperKit the active backend, rapid repeated
  /// starts coalesce to a single preload: each `startPreloadObservation()` cancels
  /// the prior observation Task before it runs, so only the last survives and fires
  /// preload exactly once. Deleting `whisperKitPreloadTask?.cancel()` leaks all
  /// three observers → count == 3 → this test goes red.
  @Test(
    .bug(
      "https://github.com/saurabhav88/EnviousWispr/issues/898",
      "repeated-start cancellation untested"))
  func repeatedStartCoalescesToSinglePreload() async throws {
    let fakeASR = FakeASRManager(backend: .whisperKit)
    let counter = InvocationCounter()
    let coord = SetupCoordinator(
      asrManager: fakeASR,
      setupStateReader: { .ready },
      preloadAction: { @MainActor in counter.increment() }
    )

    coord.startPreloadObservation()
    coord.startPreloadObservation()
    coord.startPreloadObservation()
    await drainMainActorTasks()

    #expect(
      counter.count == 1,
      "rapid repeated starts must cancel prior observers and preload exactly once"
    )
  }

  /// Drain the main-actor task queue so the observation Task runs to completion
  /// (firing preload) or bails at a guard, without a wall-clock sleep. The
  /// observation Task is main-actor-isolated, so repeatedly yielding the test
  /// task lets it make full progress (`tests-no-real-time-scheduling-precision`).
  private func drainMainActorTasks(_ iterations: Int = 20) async {
    for _ in 0..<iterations { await Task.yield() }
  }
}

@MainActor
private final class InvocationCounter {
  var count: Int = 0
  func increment() { count += 1 }
}

/// Minimal ASRManagerInterface fake. SetupCoordinator only reads
/// `activeBackendType`; everything else traps to make accidental use loud.
@MainActor
private final class FakeASRManager: ASRManagerInterface {
  let activeBackendType: ASRBackendType
  init(backend: ASRBackendType) { self.activeBackendType = backend }

  var isModelLoaded: Bool { false }
  var isStreaming: Bool { false }
  var downloadProgress: Double { 0 }
  var downloadPhase: String { "" }
  var downloadDetail: String { "" }
  var activeBackendSupportsStreaming: Bool { false }
  var onServiceInterrupted: (() -> Void)?
  var loadProgressTickReporter: (@MainActor @Sendable (Date?, String) -> Void)?

  func loadModel() async throws { fatalError("not used in SetupCoordinatorTests") }
  func unloadModel() async { fatalError("not used in SetupCoordinatorTests") }
  func setInitialBackendType(_: ASRBackendType) { fatalError("not used in SetupCoordinatorTests") }
  func switchBackend(to _: ASRBackendType) async { fatalError("not used in SetupCoordinatorTests") }
  func transcribe(audioSamples _: [Float], options _: TranscriptionOptions) async throws
    -> ASRResult
  {
    fatalError("not used in SetupCoordinatorTests")
  }
  func startStreaming(options _: TranscriptionOptions) async throws {
    fatalError("not used in SetupCoordinatorTests")
  }
  func feedAudio(_: AVAudioPCMBuffer) async throws {
    fatalError("not used in SetupCoordinatorTests")
  }
  func finalizeStreaming() async throws -> ASRResult {
    fatalError("not used in SetupCoordinatorTests")
  }
  func cancelStreaming() async { fatalError("not used in SetupCoordinatorTests") }
  func noteTranscriptionComplete(policy _: ModelUnloadPolicy) {
    fatalError("not used in SetupCoordinatorTests")
  }
  func cancelIdleTimer() { fatalError("not used in SetupCoordinatorTests") }
  func cancelInFlightLoad() { fatalError("not used in SetupCoordinatorTests") }
}
