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

  /// Active backend = parakeet → preload action must NOT fire even if the user
  /// later flips WhisperKit to .ready (no observation should be running).
  @Test func parakeetBackendSkipsPreload() async throws {
    let fakeASR = FakeASRManager(backend: .parakeet)
    let counter = InvocationCounter()
    let coord = SetupCoordinator(
      asrManager: fakeASR,
      preloadAction: { @MainActor in counter.increment() }
    )

    coord.startPreloadObservation()

    // Yield once so the observation Task gets a chance to run and bail out
    // on the .parakeet guard.
    try await Task.sleep(nanoseconds: 50_000_000)

    #expect(counter.count == 0, "preloadAction must not fire when active backend is parakeet")
  }

  /// startPreloadObservation can be called repeatedly; each call cancels the
  /// prior observation Task. Verify the invocation completes without crashing
  /// (cancellation correctness — the task body uses `[weak self]` and a
  /// while-not-cancelled loop).
  @Test func repeatedStartCancelsPrior() async throws {
    let fakeASR = FakeASRManager(backend: .parakeet)
    let counter = InvocationCounter()
    let coord = SetupCoordinator(
      asrManager: fakeASR,
      preloadAction: { @MainActor in counter.increment() }
    )

    coord.startPreloadObservation()
    coord.startPreloadObservation()
    coord.startPreloadObservation()

    try await Task.sleep(nanoseconds: 50_000_000)

    #expect(counter.count == 0)
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
  func loadModelSilently() async { fatalError("not used in SetupCoordinatorTests") }
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
