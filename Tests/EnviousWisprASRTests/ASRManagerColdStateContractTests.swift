import EnviousWisprCore
import Testing

@testable import EnviousWisprASR

@Suite("ASRManager cold-state contract")
@MainActor
struct ASRManagerColdStateContractTests {

  @Test("default manager starts on Parakeet, unloaded, not streaming")
  func defaultState() async {
    let sut = ASRManager(engineMutationScope: .alwaysAllowedForTesting)

    #expect(sut.activeBackendType == .parakeet)
    #expect(sut.isModelLoaded == false)
    #expect(sut.isStreaming == false)
    #expect(await sut.activeBackendSupportsStreaming == true)
  }

  @Test(
    "setInitialBackendType on a cold manager selects WhisperKit and reports no streaming support")
  func setInitialBackendTypeSelectsWhisperKitFromCold() async {
    // Adversarial-review note. Starting from cold means `isModelLoaded` and
    // `isStreaming` are already false, so this test does not prove the reset
    // branch inside `setInitialBackendType`. It only proves backend selection
    // and capability bit on a fresh manager. Proving the reset branch requires
    // a seam to put flags into a non-default state first (see #398 for the
    // proposed refactor).
    let sut = ASRManager(engineMutationScope: .alwaysAllowedForTesting)

    sut.setInitialBackendType(.whisperKit)

    #expect(sut.activeBackendType == .whisperKit)
    #expect(sut.isModelLoaded == false)
    #expect(sut.isStreaming == false)
    #expect(await sut.activeBackendSupportsStreaming == false)
  }

  @Test("sequential switchBackend calls leave the last requested backend active")
  func sequentialSwitchesTrackLastRequest() async {
    let sut = ASRManager(engineMutationScope: .alwaysAllowedForTesting)

    await sut.switchBackend(to: .whisperKit)
    #expect(sut.activeBackendType == .whisperKit)
    #expect(sut.isModelLoaded == false)
    #expect(sut.isStreaming == false)

    await sut.switchBackend(to: .parakeet)
    #expect(sut.activeBackendType == .parakeet)
    #expect(sut.isModelLoaded == false)
    #expect(sut.isStreaming == false)

    await sut.switchBackend(to: .whisperKit)
    #expect(sut.activeBackendType == .whisperKit)
    #expect(sut.isModelLoaded == false)
    #expect(sut.isStreaming == false)
  }

  @Test("transcribe before load throws notReady and preserves manager flags")
  func transcribeBeforeLoadThrowsNotReady() async {
    let sut = ASRManager(engineMutationScope: .alwaysAllowedForTesting)

    do {
      _ = try await sut.transcribe(audioSamples: [], options: .default)
      Issue.record("expected ASRError.notReady, got success")
    } catch let error as ASRError {
      switch error {
      case .notReady:
        break
      default:
        Issue.record("expected ASRError.notReady, got \(error)")
      }
    } catch {
      Issue.record("expected ASRError.notReady, got \(error)")
    }

    #expect(sut.activeBackendType == .parakeet)
    #expect(sut.isModelLoaded == false)
    #expect(sut.isStreaming == false)
  }

  @Test("startStreaming before prepare on Parakeet throws notReady and leaves isStreaming false")
  func startStreamingBeforePrepareOnParakeet() async {
    let sut = ASRManager(engineMutationScope: .alwaysAllowedForTesting)

    do {
      try await sut.startStreaming(options: .default)
      Issue.record("expected ASRError.notReady, got success")
    } catch let error as ASRError {
      switch error {
      case .notReady:
        break
      default:
        Issue.record("expected ASRError.notReady, got \(error)")
      }
    } catch {
      Issue.record("expected ASRError.notReady, got \(error)")
    }

    #expect(sut.activeBackendType == .parakeet)
    #expect(sut.isModelLoaded == false)
    #expect(sut.isStreaming == false)
  }

  @Test("startStreaming on WhisperKit is a no-op because streaming is unsupported")
  func startStreamingOnWhisperKitDoesNothing() async throws {
    let sut = ASRManager(engineMutationScope: .alwaysAllowedForTesting)
    sut.setInitialBackendType(.whisperKit)

    try await sut.startStreaming(options: .default)

    #expect(sut.activeBackendType == .whisperKit)
    #expect(sut.isModelLoaded == false)
    #expect(sut.isStreaming == false)
    #expect(await sut.activeBackendSupportsStreaming == false)
  }

  @Test(
    "finalizeStreaming without an active stream throws streamingNotSupported and preserves flags")
  func finalizeWithoutActiveStreamThrows() async {
    let sut = ASRManager(engineMutationScope: .alwaysAllowedForTesting)

    do {
      _ = try await sut.finalizeStreaming()
      Issue.record("expected ASRError.streamingNotSupported, got success")
    } catch let error as ASRError {
      switch error {
      case .streamingNotSupported:
        break
      default:
        Issue.record("expected ASRError.streamingNotSupported, got \(error)")
      }
    } catch {
      Issue.record("expected ASRError.streamingNotSupported, got \(error)")
    }

    #expect(sut.activeBackendType == .parakeet)
    #expect(sut.isModelLoaded == false)
    #expect(sut.isStreaming == false)
  }
}
