import Testing

@testable import EnviousWisprASR

// Actor-orchestration tests for the #1276 Step 1 load-state machine. These drive
// the real `WhisperKitBackend` actor through `TestSeams` (fake kit build + fake
// warm-up) and an injected resolver, so single-flight, generation staleness
// (the #1282 class), the fail-open warm-up budget, load-failure retry, and the
// two-consumer paths are exercised WITHOUT a real WhisperKit / model. The pure
// (state × event) matrix lives in `WhisperKitLoadStateTests`.

private final class FakeModel: LoadedASRModel {}

/// One-shot async gate (signal-based, no sleeps — test-timing discipline).
private actor AsyncGate {
  private var isOpen = false
  private var waiters: [CheckedContinuation<Void, Never>] = []
  func open() {
    isOpen = true
    for w in waiters { w.resume() }
    waiters.removeAll()
  }
  func wait() async {
    if isOpen { return }
    await withCheckedContinuation { waiters.append($0) }
  }
}

/// Records how many times the fake load / warm-up ran.
private actor CallRecorder {
  private(set) var loadCount = 0
  private(set) var warmupCount = 0
  func recordLoad() { loadCount += 1 }
  func recordWarmup() { warmupCount += 1 }
}

@Suite("WhisperKitBackend — load-state orchestration (#1276 Step 1)")
struct WhisperKitBackendLoadOrchestrationTests {

  // Seam bundle whose load succeeds immediately and warm-up completes fast.
  private func fastSeams(_ recorder: CallRecorder) -> WhisperKitBackend.TestSeams {
    WhisperKitBackend.TestSeams(
      loadModel: { _ in
        await recorder.recordLoad()
        return FakeModel()
      },
      runWarmup: {
        await recorder.recordWarmup()
        return .completed(ms: 1)
      })
  }

  // MARK: #1386 PR-2 — relocation gate (mmap safety)

  @Test("relocation gate REFUSAL blocks the map — loadModel never runs")
  func relocationGateRefusalBlocksLoad() async throws {
    struct GatePending: Error {}
    let recorder = CallRecorder()
    // The gate runs at the top of performLoad, BEFORE the fake loadModel seam:
    // a refusal (relocation in flight / TCC deferred) throws before any map.
    let backend = WhisperKitBackend(
      testSeams: fastSeams(recorder), relocationGate: { throw GatePending() })
    try? await backend.loadForTesting { "/fake" }
    #expect(await recorder.loadCount == 0, "gate refusal must block the map")
    #expect(!(await backend.isReady))
  }

  @Test("relocation gate OPEN permits the load")
  func relocationGateOpenPermitsLoad() async throws {
    let recorder = CallRecorder()
    let backend = WhisperKitBackend(testSeams: fastSeams(recorder), relocationGate: {})
    try await backend.loadForTesting { "/fake" }
    #expect(await recorder.loadCount == 1)
    #expect(await backend.isReady)
  }

  // MARK: invariant #1 — single-flight

  @Test("concurrent prepare joins ONE load (single-flight, invariant #1)")
  func singleFlightJoinsOneLoad() async throws {
    let recorder = CallRecorder()
    let loadEntered = AsyncGate()
    let release = AsyncGate()
    let seams = WhisperKitBackend.TestSeams(
      loadModel: { _ in
        await recorder.recordLoad()
        await loadEntered.open()
        await release.wait()
        return FakeModel()
      },
      runWarmup: {
        await recorder.recordWarmup()
        return .completed(ms: 1)
      })
    let backend = WhisperKitBackend(testSeams: seams)

    // A starts the load and parks inside loadModel.
    async let a: Void = backend.loadForTesting { "/fake" }
    await loadEntered.wait()  // A is in loadModel; state is .loading

    // B arrives while A's load is in flight — must JOIN, not start a 2nd load.
    async let b: Void = backend.loadForTesting { "/fake" }

    await release.open()
    try await a
    try await b

    #expect(await recorder.loadCount == 1)
    #expect(await recorder.warmupCount == 1)
    #expect(await backend.isReady)
    #expect(await backend.loadPhaseForTesting == .ready(staleWarmup: nil))
  }

  // MARK: invariant #3 / #1282 — unload during load supersedes

  @Test("unload during load → superseded, never becomes ready (invariant #3 / #1282)")
  func unloadDuringLoadSupersedes() async throws {
    let recorder = CallRecorder()
    let loadEntered = AsyncGate()
    let release = AsyncGate()
    let seams = WhisperKitBackend.TestSeams(
      loadModel: { _ in
        await recorder.recordLoad()
        await loadEntered.open()
        await release.wait()
        return FakeModel()
      },
      runWarmup: {
        await recorder.recordWarmup()
        return .completed(ms: 1)
      })
    let backend = WhisperKitBackend(testSeams: seams)

    let loadTask = Task { try await backend.loadForTesting { "/fake" } }
    await loadEntered.wait()  // load in flight

    await backend.unload()  // bumps generation, → .idle
    await release.open()  // let the (now-stale) load finish

    // The superseded load throws rather than resurrecting readiness.
    do {
      try await loadTask.value
      Issue.record("expected the superseded load to throw")
    } catch is ASRLoadSupersededError {
      // expected
    } catch {
      Issue.record("expected ASRLoadSupersededError, got \(error)")
    }
    #expect(await backend.isReady == false)
    #expect(await backend.loadPhaseForTesting == .idle)
    #expect(await recorder.warmupCount == 0)  // never warmed a discarded model
  }

  // MARK: invariant #3 (warm-up phase) — unload during warm-up supersedes

  @Test("unload during warm-up → prepare throws superseded, not false success (Codex code-diff r1)")
  func unloadDuringWarmupSupersedes() async throws {
    let recorder = CallRecorder()
    let warmupEntered = AsyncGate()
    let release = AsyncGate()
    let seams = WhisperKitBackend.TestSeams(
      loadModel: { _ in
        await recorder.recordLoad()
        return FakeModel()
      },
      runWarmup: {
        await recorder.recordWarmup()
        await warmupEntered.open()
        await release.wait()
        return .completed(ms: 1)
      })
    let backend = WhisperKitBackend(testSeams: seams)

    let loadTask = Task { try await backend.loadForTesting { "/fake" } }
    await warmupEntered.wait()  // state is .warming, parked in the warm-up await
    await backend.unload()  // bump generation, → .idle
    await release.open()  // let the (now-stale) warm-up resolve

    // The superseded warm-up must throw — NOT return success while unloaded.
    do {
      try await loadTask.value
      Issue.record("expected the superseded warm-up to throw")
    } catch is ASRLoadSupersededError {
      // expected
    } catch {
      Issue.record("expected ASRLoadSupersededError, got \(error)")
    }
    #expect(await backend.isReady == false)
    #expect(await backend.loadPhaseForTesting == .idle)
  }

  // MARK: invariant #6 / #4 — fail-open ready + budget-once

  @Test(
    "warm-up timeout → fail-open ready; first vend drops the orphan, no second drain (inv #4/#6)")
  func warmupTimeoutFailOpenAndBudgetOnce() async throws {
    let recorder = CallRecorder()
    let warmupHang = AsyncGate()  // never opened until teardown → warm-up "hangs"
    var seams = WhisperKitBackend.TestSeams(
      loadModel: { _ in
        await recorder.recordLoad()
        return FakeModel()
      },
      runWarmup: {
        await recorder.recordWarmup()
        await warmupHang.wait()  // exceeds the (tiny) deadline → fail-open timeout
        return .completed(ms: 1)
      })
    seams.warmupDeadlineSeconds = 0.05  // signal-fast timeout, not a real 20s wait
    let backend = WhisperKitBackend(testSeams: seams)

    try await backend.loadForTesting { "/fake" }

    // Fail-open: ready despite the warm-up not finishing, orphan carried + spent.
    #expect(await backend.isReady)
    #expect(
      await backend.loadPhaseForTesting
        == .ready(staleWarmup: WarmupInfo(generation: 0, budgetSpent: true)))

    // First vend: budget already spent → drop the orphan, vend without re-draining.
    let afterVend = await backend.vendForTesting()
    #expect(afterVend == .ready(staleWarmup: nil))

    // Second vend: clean ready, nothing to drain.
    let afterSecondVend = await backend.vendForTesting()
    #expect(afterSecondVend == .ready(staleWarmup: nil))

    await warmupHang.open()  // release the parked warm-up task for clean teardown
    await backend.unload()
  }

  // MARK: invariant #2 — unload then prepare starts a fresh load

  @Test("unload then prepare starts a FRESH load, not a doomed join (invariant #2)")
  func unloadThenPrepareStartsFresh() async throws {
    let recorder = CallRecorder()
    let backend = WhisperKitBackend(testSeams: fastSeams(recorder))

    try await backend.loadForTesting { "/fake" }
    #expect(await backend.isReady)
    #expect(await recorder.loadCount == 1)

    await backend.unload()
    #expect(await backend.loadPhaseForTesting == .idle)

    try await backend.loadForTesting { "/fake" }  // fresh load
    #expect(await backend.isReady)
    #expect(await recorder.loadCount == 2)
  }

  // MARK: test 9 — load failure returns to idle and retries

  @Test("load failure → idle, next prepare retries (test 9)")
  func loadFailureReturnsToIdleAndRetries() async throws {
    let recorder = CallRecorder()
    struct FakeLoadError: Error {}
    let seams = WhisperKitBackend.TestSeams(
      loadModel: { _ in
        await recorder.recordLoad()
        if await recorder.loadCount == 1 { throw FakeLoadError() }
        return FakeModel()
      },
      runWarmup: {
        await recorder.recordWarmup()
        return .completed(ms: 1)
      })
    let backend = WhisperKitBackend(testSeams: seams)

    await #expect(throws: FakeLoadError.self) {
      try await backend.loadForTesting { "/fake" }
    }
    #expect(await backend.isReady == false)
    #expect(await backend.loadPhaseForTesting == .idle)  // retryable, not stuck

    try await backend.loadForTesting { "/fake" }  // retry succeeds
    #expect(await backend.isReady)
    #expect(await recorder.loadCount == 2)
  }

  // MARK: test 10b — two consumers then teardown

  @Test("two consumers join one load, then unload lands everyone in idle (test 10b)")
  func twoConsumersThenUnload() async throws {
    let recorder = CallRecorder()
    let loadEntered = AsyncGate()
    let release = AsyncGate()
    let seams = WhisperKitBackend.TestSeams(
      loadModel: { _ in
        await recorder.recordLoad()
        await loadEntered.open()
        await release.wait()
        return FakeModel()
      },
      runWarmup: {
        await recorder.recordWarmup()
        return .completed(ms: 1)
      })
    let backend = WhisperKitBackend(testSeams: seams)

    async let a: Void = backend.loadForTesting { "/fake" }
    await loadEntered.wait()
    async let b: Void = backend.loadForTesting { "/fake" }

    await release.open()
    try await a
    try await b
    #expect(await recorder.loadCount == 1)  // 10a: shared single load

    await backend.unload()  // 10b: teardown
    #expect(await backend.isReady == false)
    #expect(await backend.loadPhaseForTesting == .idle)
  }
}
