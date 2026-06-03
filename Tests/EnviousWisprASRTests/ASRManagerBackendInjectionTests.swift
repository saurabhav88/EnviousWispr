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

// MARK: - #959 load-generation readiness-integrity guard

/// Verifies that only the CURRENT load may mark the model loaded, and that a
/// superseded load fails loudly (throws `ASRLoadSupersededError`) instead of
/// resurrecting a false `.ready`. Drives `ASRManager` (in-process) with a gated
/// `FakeASRBackend` so a cancel/unload/switch can land WHILE a load is parked.
@Suite("ASRManager load-generation guard (#959)")
@MainActor
struct ASRManagerLoadGenerationTests {

  private func waitForPrepareEntered(_ backend: FakeASRBackend) async {
    while await backend.prepareCount == 0 { await Task.yield() }
  }

  @Test("a load superseded by cancelInFlightLoad mid-flight throws and stays unloaded")
  func cancelInFlightLoadSupersedes() async throws {
    let parakeet = FakeASRBackend(initiallyReady: false, gated: true)
    let manager = ASRManager(
      parakeetBackend: parakeet, whisperKitBackend: FakeASRBackend(initiallyReady: false))

    let loadTask = Task { @MainActor in
      await #expect(throws: ASRLoadSupersededError.self) { try await manager.loadModel() }
    }
    await waitForPrepareEntered(parakeet)
    manager.cancelInFlightLoad()  // bumps the generation while the load is parked
    await parakeet.releaseGate()
    await loadTask.value
    #expect(manager.isModelLoaded == false, "a superseded load must not resurrect readiness")
  }

  @Test("unloadModel during an in-flight load supersedes it (bump-before-guard, Codex r2)")
  func unloadDuringInFlightLoadSupersedes() async throws {
    let parakeet = FakeASRBackend(initiallyReady: false, gated: true)
    let manager = ASRManager(
      parakeetBackend: parakeet, whisperKitBackend: FakeASRBackend(initiallyReady: false))

    let loadTask = Task { @MainActor in
      await #expect(throws: ASRLoadSupersededError.self) { try await manager.loadModel() }
    }
    await waitForPrepareEntered(parakeet)
    // `isModelLoaded` is still false here; the bump must happen BEFORE the
    // `guard isModelLoaded` early-return so the in-flight load is still caught.
    await manager.unloadModel()
    await parakeet.releaseGate()
    await loadTask.value
    #expect(manager.isModelLoaded == false)
  }

  @Test("same-backend switch during an in-flight load does NOT supersede it (Codex r3)")
  func sameBackendSwitchDoesNotSupersede() async throws {
    let parakeet = FakeASRBackend(initiallyReady: false, gated: true)
    let manager = ASRManager(
      parakeetBackend: parakeet, whisperKitBackend: FakeASRBackend(initiallyReady: false))

    let loadTask = Task { @MainActor in try await manager.loadModel() }
    await waitForPrepareEntered(parakeet)
    // No-op switch (already .parakeet): must return at the same-backend guard
    // BEFORE bumping the generation, so the valid load completes successfully.
    await manager.switchBackend(to: .parakeet)
    await parakeet.releaseGate()
    try await loadTask.value  // must NOT throw
    #expect(
      manager.isModelLoaded == true, "a no-op switch must not supersede a valid in-flight load")
  }

  @Test(
    "a real backend switch during an in-flight load retires it so the new backend loads fresh (Codex P2)"
  )
  func realSwitchDuringInFlightLoadStartsFresh() async throws {
    let parakeet = FakeASRBackend(initiallyReady: false, gated: true)
    let whisperKit = FakeASRBackend(initiallyReady: false)  // ungated — loads normally
    let manager = ASRManager(parakeetBackend: parakeet, whisperKitBackend: whisperKit)

    let loadTask = Task { @MainActor in
      await #expect(throws: ASRLoadSupersededError.self) { try await manager.loadModel() }
    }
    await waitForPrepareEntered(parakeet)
    await manager.switchBackend(to: .whisperKit)  // retires the parakeet load task
    await parakeet.releaseGate()
    await loadTask.value

    // The next load must start FRESH for the new backend, not join the retired
    // (superseded) parakeet task and receive ASRLoadSupersededError.
    try await manager.loadModel()
    #expect(manager.isModelLoaded == true)
    #expect(manager.activeBackendType == .whisperKit)
    let wkPrepares = await whisperKit.prepareCount
    #expect(wkPrepares == 1, "new backend loaded fresh, not via the stale task")
  }

  @Test(
    "unloadModel during an in-flight load retires it so a retry starts FRESH, not joins the doomed task (Codex re-review P2)"
  )
  func unloadDuringInFlightLoadRetiresTaskSoRetryStartsFresh() async throws {
    let parakeet = FakeASRBackend(initiallyReady: false, gated: true)
    let manager = ASRManager(
      parakeetBackend: parakeet, whisperKitBackend: FakeASRBackend(initiallyReady: false))

    // Load A parks in prepare() holding generation G.
    let loadTask = Task { @MainActor in
      await #expect(throws: ASRLoadSupersededError.self) { try await manager.loadModel() }
    }
    await waitForPrepareEntered(parakeet)

    // unloadModel bumps the generation (superseding A) AND must retire A's
    // single-flight handle so the next load does not join A's doomed task.
    await manager.unloadModel()

    // Retry B: with the handle retired it starts a FRESH load (a second prepare);
    // with the bug it would JOIN A via single-flight and never enter a new prepare.
    let retry = Task { @MainActor in try await manager.loadModel() }

    // Bounded poll — never a spin-on-condition that could hang under the bug.
    var enteredFresh = false
    for _ in 0..<10_000 {
      if await parakeet.prepareCount >= 2 {
        enteredFresh = true
        break
      }
      await Task.yield()
    }

    await parakeet.releaseGate()  // resumes A (cancelled → throws) and B (if it parked fresh)
    await loadTask.value

    #expect(
      enteredFresh, "retry must start a fresh load, not join the superseded in-flight task")
    if enteredFresh {
      try await retry.value  // the fresh load must succeed
      #expect(manager.isModelLoaded == true)
    } else {
      _ = try? await retry.value  // bug path: drain B so the test doesn't leak a task
    }
  }

  // Codex code-diff P1 (single-flight identity guard): a superseded load's `defer`
  // must not clear a retry's `inFlightLoadTask`. Verified by inspection + Codex
  // re-review rather than a dedicated test — reproducing it needs THREE concurrent
  // same-backend loads (A superseded, B installed, C joins B), which the
  // single-continuation `FakeASRBackend` gate cannot model without a multi-waiter
  // rewrite disproportionate to a 2-line, provably-correct guard
  // (`defer { if activeLoadTaskID == myTaskID { inFlightLoadTask = nil } }`).
}

// MARK: - Fake

/// Minimal `ASRBackend` actor for tests. Reports controllable readiness and
/// records lifecycle calls. Does NOT implement transcription or streaming —
/// G5 scope is the manager's reset branches, not real ASR work.
final actor FakeASRBackend: ASRBackend {
  private var ready: Bool
  private(set) var unloadCount: Int = 0
  private(set) var prepareCount: Int = 0

  /// #959: when `gated`, `prepare()` parks until `releaseGate()` so a test can
  /// supersede an in-flight load (cancel / unload / switch) BEFORE the load
  /// completes, then release it to exercise the generation guard. The waiter list
  /// is an array (not a single slot) so MULTIPLE concurrent loads can park at once
  /// — e.g. a superseded load plus a fresh retry — and be released together
  /// without one overwriting the other's continuation and deadlocking.
  private let gated: Bool
  private var gateContinuations: [CheckedContinuation<Void, Never>] = []

  init(initiallyReady: Bool, gated: Bool = false) {
    self.ready = initiallyReady
    self.gated = gated
  }

  // MARK: ASRBackend

  var isReady: Bool { ready }

  var supportsStreaming: Bool { false }

  func prepare() async throws {
    prepareCount += 1
    if gated {
      await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
        gateContinuations.append(c)
      }
    }
    ready = true
  }

  /// Release ALL parked `gated` `prepare()` calls (supports multiple waiters).
  func releaseGate() {
    let parked = gateContinuations
    gateContinuations.removeAll()
    for c in parked { c.resume() }
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
