@preconcurrency import AVFoundation
import EnviousWisprCore
import Foundation
import Testing
import os

@testable import EnviousWisprASR

/// Phase G5 — exercises reset-branch behavior in `setInitialBackendType` and
/// `switchBackend` from a synthetic loaded state. Previously NOT_TESTABLE
/// because driving a real `ParakeetBackend` / `WhisperKitBackend` to
/// `isReady=true` requires a real model download/compile on CI.
///
/// `FakeASRBackend` is an actor (matches `ASRBackend: Actor` requirement)
/// that reports a controllable `isReady` and records `unload` / `prepare`
/// calls for assertions.
@Suite("ASRManager backend injection (Phase G5)")
@MainActor
struct ASRManagerBackendInjectionTests {

  // MARK: - switchBackend reset branch

  @Test("switchBackend from a loaded state resets isModelLoaded to false")
  func switchBackendFromLoadedResetsIsModelLoaded() async throws {
    let parakeet = FakeASRBackend(initiallyReady: true)
    let whisperKit = FakeASRBackend(initiallyReady: true)

    let manager = ASRManager(
      parakeetBackend: parakeet,
      whisperKitBackend: whisperKit
    )

    // Drive the manager to "loaded" via the public loadModel path. Because
    // FakeASRBackend reports ready, loadModel completes synchronously after
    // the actor hop and isModelLoaded becomes true.
    try await manager.loadModel()
    #expect(manager.isModelLoaded == true)

    await manager.switchBackend(to: .whisperKit)
    #expect(manager.isModelLoaded == false)
    #expect(manager.activeBackendType == .whisperKit)
  }

  @Test("switchBackend unloads the previous backend exactly once")
  func switchBackendUnloadsPreviousBackend() async throws {
    let parakeet = FakeASRBackend(initiallyReady: true)
    let whisperKit = FakeASRBackend(initiallyReady: true)

    let manager = ASRManager(
      parakeetBackend: parakeet,
      whisperKitBackend: whisperKit
    )
    try await manager.loadModel()

    await manager.switchBackend(to: .whisperKit)

    let parakeetUnloads = await parakeet.unloadCount
    let whisperKitUnloads = await whisperKit.unloadCount
    #expect(parakeetUnloads == 1)
    #expect(whisperKitUnloads == 0)
  }

  @Test("switchBackend to the same type is a no-op (no unload, flags preserved)")
  func switchBackendSameTypeIsNoOp() async throws {
    let parakeet = FakeASRBackend(initiallyReady: true)
    let whisperKit = FakeASRBackend(initiallyReady: true)

    let manager = ASRManager(
      parakeetBackend: parakeet,
      whisperKitBackend: whisperKit
    )
    try await manager.loadModel()

    await manager.switchBackend(to: .parakeet)

    let parakeetUnloads = await parakeet.unloadCount
    #expect(parakeetUnloads == 0)
    #expect(manager.activeBackendType == .parakeet)
    #expect(manager.isModelLoaded == true)
  }

  // MARK: - setInitialBackendType reset branch

  @Test("setInitialBackendType after a load resets isModelLoaded and isStreaming")
  func setInitialBackendTypeAfterLoadResetsFlags() async throws {
    let parakeet = FakeASRBackend(initiallyReady: true)
    let whisperKit = FakeASRBackend(initiallyReady: true)

    let manager = ASRManager(
      parakeetBackend: parakeet,
      whisperKitBackend: whisperKit
    )
    try await manager.loadModel()
    #expect(manager.isModelLoaded == true)

    manager.setInitialBackendType(.whisperKit)
    #expect(manager.isModelLoaded == false)
    #expect(manager.isStreaming == false)
    #expect(manager.activeBackendType == .whisperKit)
  }
}

// MARK: - Fake

/// Minimal `ASRBackend` actor for tests. Reports controllable readiness and
/// records lifecycle calls. Does NOT implement transcription or streaming —
/// G5 scope is the manager's reset branches, not real ASR work.
final actor FakeASRBackend: ASRBackend {
  private var ready: Bool
  private(set) var unloadCount: Int = 0
  private(set) var prepareCount: Int = 0

  init(initiallyReady: Bool) {
    self.ready = initiallyReady
  }

  // MARK: ASRBackend

  var isReady: Bool { ready }

  var supportsStreaming: Bool { false }

  func prepare() async throws {
    prepareCount += 1
    ready = true
  }

  func transcribe(audioSamples: [Float], options: TranscriptionOptions)
    async throws -> ASRResult
  {
    fatalError("FakeASRBackend.transcribe is not used by Phase G5 tests")
  }

  func unload() async {
    unloadCount += 1
    ready = false
  }
}
