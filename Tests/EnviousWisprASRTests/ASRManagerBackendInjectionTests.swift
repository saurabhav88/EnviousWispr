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

  // MARK: - #2132 readiness contract

  @Test(
    "loadModel() reports SUCCESS while the backend is not ready — the failure only surfaces at transcribe"
  )
  func loadModelSucceedsWhileBackendIsNotReady() async throws {
    // The shape a real backend lands in when an unload, a cancelled load, or a
    // refused admission gate wins the race: prepare() returns normally, readiness
    // does not follow.
    let parakeet = FakeASRBackend(initiallyReady: false, readyAfterPrepare: false)
    let manager = ASRManager(
      engineMutationScope: .alwaysAllowedForTesting,
      parakeetSelection: ParakeetSelectionProvider(), parakeetBackendFactory: { parakeet })

    // The defect: this does NOT throw. `loadModel` records readiness
    // (`isModelLoaded = ready`) instead of requiring it, so every caller that
    // treats a non-throwing load as "the engine is ready" is wrong.
    try await manager.loadModel()
    #expect(manager.isModelLoaded == false, "load reported success but nothing is loaded")

    // ...and the truth only arrives one call later, as an instant refusal with
    // no work done. In crash recovery that instant refusal spends the single
    // permitted attempt and the recording is deleted (#2132).
    await #expect(throws: ASRError.self) {
      _ = try await manager.transcribe(audioSamples: [0.0], options: .default)
    }
  }

  // MARK: - #3546 one load request

  /// #2697 behaviour carried by the #3546 request: a Parakeet load with no
  /// request (never written, or cleared after a refusal) throws the unset error
  /// and never reaches the vendor, instead of guessing a directory.
  @Test("a Parakeet load with no request refuses, before and after a cleared request")
  func parakeetLoadWithoutRequestRefuses() async throws {
    let selection = ParakeetSelectionProvider()
    let manager = ASRManager(
      engineMutationScope: .alwaysAllowedForTesting, parakeetSelection: selection,
      parakeetBackendFactory: { ParakeetBackend() })
    await #expect(throws: ParakeetModelDirectoryUnsetError.self) {
      try await manager.loadModel()
    }
    selection.select(
      model: .v3, revision: nil,
      directory: URL(fileURLWithPath: "/nonexistent/parakeet-tdt-0.6b-v3"), cacheOnly: true,
      displayBytes: 1, repairable: true)
    selection.clear()
    await #expect(throws: ParakeetModelDirectoryUnsetError.self) {
      try await manager.loadModel()
    }
    #expect(manager.isModelLoaded == false)
  }

  /// #3546: an Ultra load is counted before the vendor loader. With nothing
  /// installed to count it, the load fails closed before the vendor; and a
  /// counting hook that throws (the store could not persist the attempt) stops
  /// the load with that error, still before the vendor.
  @Test("an uncounted Ultra load fails closed, and a throwing count stops the load")
  func ultraLoadIsCountedOrRefused() async throws {
    struct StoreDown: Error {}
    let selection = ParakeetSelectionProvider()
    let manager = ASRManager(
      engineMutationScope: .alwaysAllowedForTesting, parakeetSelection: selection,
      parakeetBackendFactory: { ParakeetBackend() })
    selection.select(
      model: .ultra, revision: nil,
      directory: URL(fileURLWithPath: "/nonexistent/parakeet-ultra"), cacheOnly: true,
      displayBytes: 1, repairable: false)
    await #expect(throws: ParakeetLoadAccountingUnavailableError.self) {
      try await manager.loadModel()
    }
    var counted: [ParakeetModel] = []
    selection.beforePhysicalLoad = { request in
      counted.append(request.model)
      throw StoreDown()
    }
    await #expect(throws: StoreDown.self) {
      try await manager.loadModel()
    }
    #expect(counted == [.ultra])
    #expect(manager.isModelLoaded == false)
  }

  /// #3546: offline-mode admission comes FIRST. A load refused for a conflicting
  /// mode never reaches the vendor, so it must not spend an Ultra attempt.
  @Test("a load refused for a conflicting offline mode is not counted")
  func conflictingModeRefusalSpendsNoAttempt() async throws {
    let selection = ParakeetSelectionProvider()
    let manager = ASRManager(
      engineMutationScope: .alwaysAllowedForTesting, parakeetSelection: selection,
      parakeetBackendFactory: { ParakeetBackend() })
    var counted = 0
    selection.beforePhysicalLoad = { _ in counted += 1 }
    selection.select(
      model: .ultra, revision: nil,
      directory: URL(fileURLWithPath: "/nonexistent/parakeet-ultra"), cacheOnly: true,
      displayBytes: 1, repairable: false)
    try manager.admitOfflineMode(cacheOnly: false)  // another load holds the other mode
    await #expect(throws: ParakeetOfflineModeConflictError.self) {
      try await manager.loadModel()
    }
    manager.releaseOfflineModeAdmission()
    #expect(counted == 0)
  }

  /// `clear()` removes the request but never rewinds the generation.
  @Test("the provider stamps increasing generations and clear keeps counting")
  func providerGenerationsIncrease() {
    let selection = ParakeetSelectionProvider()
    let directory = URL(fileURLWithPath: "/nonexistent/parakeet-tdt-0.6b-v3")
    let first = selection.select(
      model: .v3, revision: "r", directory: directory, cacheOnly: false, displayBytes: 1,
      repairable: false)
    selection.clear()
    #expect(selection.current == nil)
    let second = selection.select(
      model: .v3, revision: "r", directory: directory, cacheOnly: true, displayBytes: 1,
      repairable: true)
    #expect(second.generation > first.generation)
    #expect(selection.current == second)
  }

  // MARK: - #2918 transcription progress travels through the manager

  @Test("the manager installs the progress observer per call, hops it to the MainActor, and the backend clears it")
  func transcriptionProgressTravels() async throws {
    let backend = FakeASRBackend(initiallyReady: true)
    let manager = ASRManager(
      engineMutationScope: .alwaysAllowedForTesting,
      parakeetSelection: ParakeetSelectionProvider(), parakeetBackendFactory: { backend })
    try await manager.loadModel()
    let received = OSAllocatedUnfairLock(initialState: [Double]())
    manager.onTranscriptionProgress = { fraction in
      received.withLock { $0.append(fraction) }
    }
    _ = try await manager.transcribe(audioSamples: [0.0], options: .default)
    // The hop is a Task on the MainActor; let it land.
    for _ in 0..<50 where received.withLock({ $0.count }) < 2 {
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(received.withLock { $0 } == [0.25, 0.75])
    #expect(await backend.progressObserverIsInstalled == false, "cleared by the backend on exit")
    // Without a consumer nothing is installed: dictation pays nothing for the bar.
    manager.onTranscriptionProgress = nil
    _ = try await manager.transcribe(audioSamples: [0.0], options: .default)
    #expect(received.withLock { $0 } == [0.25, 0.75], "no consumer, no ticks")
  }

  // MARK: - switchBackend reset branch

  @Test("switchBackend from a loaded state resets isModelLoaded to false")
  func switchBackendFromLoadedResetsIsModelLoaded() async throws {
    let parakeet = FakeASRBackend(initiallyReady: true)
    let manager = ASRManager(
      engineMutationScope: .alwaysAllowedForTesting,
      parakeetSelection: ParakeetSelectionProvider(), parakeetBackendFactory: { parakeet })

    // Drive the manager to "loaded" via the public loadModel path. Because
    // FakeASRBackend reports ready, loadModel completes synchronously after
    // the actor hop and isModelLoaded becomes true.
    try await manager.loadModel()
    #expect(manager.isModelLoaded == true)

    await manager.switchBackend(to: .whisperKit)
    #expect(manager.isModelLoaded == false)
    #expect(manager.activeBackendType == .whisperKit)
  }

  /// #3546 A-fail: when this fails, a failed Ultra load is still releasing its model while
  /// the v3 fallback loads, so both models are resident at once.
  @Test("a failed load returns its error only after the failed candidate finished unloading")
  func failedLoadAwaitsCandidateCleanup() async throws {
    struct LoadBroke: Error {}
    let failing = FakeASRBackend(initiallyReady: false, prepareFailure: LoadBroke())
    let resident = FakeASRBackend(initiallyReady: true)
    var made = 0
    let manager = ASRManager(
      engineMutationScope: .alwaysAllowedForTesting,
      parakeetSelection: ParakeetSelectionProvider(),
      parakeetBackendFactory: {
        made += 1
        return made == 1 ? resident : failing
      })
    await failing.gateUnload()
    var returned = false
    let load = Task { @MainActor in
      defer { returned = true }
      try await manager.loadModel()
    }
    var parked = false
    for _ in 0..<500 {
      if await failing.unloadCount == 1 {
        parked = true
        break
      }
      // deadline-fallback: bounded poll for the cleanup to start (500 x 10 ms).
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(parked, "the failed candidate's cleanup started")
    for _ in 0..<20 { await Task.yield() }
    #expect(returned == false, "the error waits for the cleanup")
    await failing.releaseUnload()
    await #expect(throws: LoadBroke.self) { try await load.value }
    #expect(await failing.unloadsFinished == 1)
  }

  /// #3546 A3: when this fails, an idle unload queued by the previous dictation lands on the
  /// model an in-session Parakeet Ultra activation is loading.
  @Test("cancelling the idle timer also stops an unload it already queued")
  func cancelIdleTimerStopsQueuedUnload() async throws {
    func loadedManager() async throws -> (ASRManager, FakeASRBackend) {
      let backend = FakeASRBackend(initiallyReady: true)
      let manager = ASRManager(
        engineMutationScope: .alwaysAllowedForTesting,
        parakeetSelection: ParakeetSelectionProvider(), parakeetBackendFactory: { backend })
      try await manager.loadModel()
      return (manager, backend)
    }
    let (control, controlBackend) = try await loadedManager()
    let (cancelled, cancelledBackend) = try await loadedManager()

    cancelled.noteTranscriptionComplete(policy: .immediately)
    cancelled.cancelIdleTimer()
    control.noteTranscriptionComplete(policy: .immediately)

    // Bounded: a queued unload that never settles fails here instead of hanging the suite.
    let settled = await withDeadline(seconds: 5) {
      await control.waitForQueuedIdleUnloadForTesting()
      await cancelled.waitForQueuedIdleUnloadForTesting()
      return true
    }
    #expect(settled == true, "both queued unloads settled")
    #expect(await controlBackend.unloadCount == 1, "control: an uncancelled queued unload runs")
    #expect(await cancelledBackend.unloadCount == 0)
    #expect(cancelled.isModelLoaded)
  }

  /// #3546 A3: when this fails, the in-session Ultra activation's unload returns while an idle
  /// unload is still releasing v3, and Ultra starts loading beside it.
  @Test("a second unload waits for the one already running and does not start its own")
  func secondUnloadJoinsTheRunningOne() async throws {
    let backend = FakeASRBackend(initiallyReady: true)
    let manager = ASRManager(
      engineMutationScope: .alwaysAllowedForTesting,
      parakeetSelection: ParakeetSelectionProvider(), parakeetBackendFactory: { backend })
    try await manager.loadModel()
    await backend.gateUnload()
    let first = Task { @MainActor in await manager.unloadModel() }
    var parked = false
    for _ in 0..<500 {
      if await backend.unloadCount == 1 {
        parked = true
        break
      }
      // deadline-fallback: bounded poll for the first unload to reach the backend (500 x 10 ms).
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(parked, "the first unload is running")
    var secondReturned = false
    let second = Task { @MainActor in
      await manager.unloadModel()
      secondReturned = true
    }
    for _ in 0..<20 { await Task.yield() }
    #expect(secondReturned == false, "the second unload waits for the running one")
    await backend.releaseUnload()
    await first.value
    await second.value
    #expect(await backend.unloadCount == 1, "one physical unload")
    #expect(manager.isModelLoaded == false)
  }

  /// #3546 A3: when this fails, one cancelled live-preview stream that never finishes holds
  /// every later cancelled stream, with its audio and model references, for the app's life.
  @Test("a newer retired stream finishes even while an older one is still draining")
  func newerRetiredStreamFinishesBehindAHeldOlderOne() async throws {
    actor Gate {
      private var open = false
      private var waiters: [CheckedContinuation<Void, Never>] = []
      private(set) var finished = false
      func wait() async {
        if open { return }
        await withCheckedContinuation { waiters.append($0) }
      }
      func release() {
        open = true
        for w in waiters { w.resume() }
        waiters = []
      }
      func markFinished() { finished = true }
    }
    let olderHeld = Gate()
    let older = ParakeetBackend.chainRetirement(
      previous: nil, cancel: {}, finish: { await olderHeld.wait() })
    let newer = Gate()
    let newerRetirement = ParakeetBackend.chainRetirement(
      previous: older.drain, cancel: {}, finish: { await newer.markFinished() })
    await newerRetirement.cancellation.value

    var newerFinished = false
    for _ in 0..<500 {
      if await newer.finished {
        newerFinished = true
        break
      }
      // deadline-fallback: bounded poll for the newer finish (500 x 10 ms).
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(newerFinished, "the newer stream's finish does not wait for the older drain")

    // The chain still covers the held older stream, and completes once it finishes.
    await olderHeld.release()
    let drained = await withDeadline(seconds: 5) {
      await newerRetirement.drain.value
      return true
    }
    #expect(drained == true)
  }

  @Test("switchBackend unloads the previous backend exactly once")
  func switchBackendUnloadsPreviousBackend() async throws {
    let parakeet = FakeASRBackend(initiallyReady: true)
    let manager = ASRManager(
      engineMutationScope: .alwaysAllowedForTesting,
      parakeetSelection: ParakeetSelectionProvider(), parakeetBackendFactory: { parakeet })
    try await manager.loadModel()

    await manager.switchBackend(to: .whisperKit)

    let parakeetUnloads = await parakeet.unloadCount
    #expect(parakeetUnloads == 1)
  }

  @Test("switchBackend to the same type is a no-op (no unload, flags preserved)")
  func switchBackendSameTypeIsNoOp() async throws {
    let parakeet = FakeASRBackend(initiallyReady: true)
    let manager = ASRManager(
      engineMutationScope: .alwaysAllowedForTesting,
      parakeetSelection: ParakeetSelectionProvider(), parakeetBackendFactory: { parakeet })
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
    let manager = ASRManager(
      engineMutationScope: .alwaysAllowedForTesting,
      parakeetSelection: ParakeetSelectionProvider(), parakeetBackendFactory: { parakeet })
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

  private func waitForPrepareEntered(_ backend: FakeASRBackend, count: Int = 1) async {
    while await backend.prepareCount < count { await Task.yield() }
  }

  @Test(
    "a load superseded by cancelInFlightLoad mid-flight releases the caller EARLY with ASRLoadCancelledError, before the vendor call itself returns (#1908)"
  )
  func cancelInFlightLoadSupersedes() async throws {
    let parakeet = FakeASRBackend(initiallyReady: false, gated: true)
    let manager = ASRManager(
      engineMutationScope: .alwaysAllowedForTesting,
      parakeetSelection: ParakeetSelectionProvider(), parakeetBackendFactory: { parakeet })

    let loadTask = Task { @MainActor in
      // #1908: `cancelInFlightLoad()` resumes the caller directly with
      // `ASRLoadCancelledError` — matching `ASRManagerProxy`'s existing
      // contract — rather than waiting for the vendor call to notice the
      // generation bump on its own eventual completion. This is the fix for
      // the parity gap grounded review found: a vendor call that never
      // observes `Task.isCancelled` must not be able to hang this caller.
      await #expect(throws: ASRLoadCancelledError.self) { try await manager.loadModel() }
    }
    await waitForPrepareEntered(parakeet)
    manager.cancelInFlightLoad()  // bumps the generation AND releases the caller immediately
    await loadTask.value  // must NOT need `releaseGate()` first — that is the point of the fix
    #expect(manager.isModelLoaded == false, "a superseded load must not resurrect readiness")

    // The vendor call itself is still parked in the background (orphaned,
    // per the plan's accepted-risk note) — release it so the suite does not
    // leak a hung Task past this test.
    await parakeet.releaseGate()
  }

  @Test("unloadModel during an in-flight load supersedes it (bump-before-guard, Codex r2)")
  func unloadDuringInFlightLoadSupersedes() async throws {
    let parakeet = FakeASRBackend(initiallyReady: false, gated: true)
    let manager = ASRManager(
      engineMutationScope: .alwaysAllowedForTesting,
      parakeetSelection: ParakeetSelectionProvider(), parakeetBackendFactory: { parakeet })

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
      engineMutationScope: .alwaysAllowedForTesting,
      parakeetSelection: ParakeetSelectionProvider(), parakeetBackendFactory: { parakeet })

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
    "a real backend switch during an in-flight load retires it so the next load starts fresh (Codex P2)"
  )
  func realSwitchDuringInFlightLoadStartsFresh() async throws {
    let parakeet = FakeASRBackend(initiallyReady: false, gated: true)
    let manager = ASRManager(
      engineMutationScope: .alwaysAllowedForTesting,
      parakeetSelection: ParakeetSelectionProvider(), parakeetBackendFactory: { parakeet })

    let loadTask = Task { @MainActor in
      await #expect(throws: ASRLoadSupersededError.self) { try await manager.loadModel() }
    }
    await waitForPrepareEntered(parakeet)
    await manager.switchBackend(to: .whisperKit)  // retires the parakeet load task
    await parakeet.releaseGate()
    await loadTask.value

    // #1386 PR-2: the manager no longer owns a WhisperKit backend to load, so
    // the invariant is now proven by switching BACK — the next load must start
    // FRESH, not join the retired (superseded) task and inherit its throw.
    // The gated fake parks EVERY prepare, so the retry needs its own release:
    // run it as a task, wait for its park (prepareCount == 2), then open the
    // gate again. Awaiting `loadModel()` inline here deadlocks the suite.
    await manager.switchBackend(to: .parakeet)
    let retryTask = Task { @MainActor in try await manager.loadModel() }
    await waitForPrepareEntered(parakeet, count: 2)
    await parakeet.releaseGate()
    try await retryTask.value
    #expect(manager.isModelLoaded == true)
    #expect(manager.activeBackendType == .parakeet)
    let prepares = await parakeet.prepareCount
    #expect(prepares == 2, "loaded fresh, not via the stale task")
  }

  // MARK: - #1386 PR-2: the manager is Parakeet-only

  @Test("loadModel refuses an engine the manager does not own, loudly")
  func loadModelRefusesNonOwnedBackend() async throws {
    let parakeet = FakeASRBackend(initiallyReady: true)
    let manager = ASRManager(
      engineMutationScope: .alwaysAllowedForTesting,
      parakeetSelection: ParakeetSelectionProvider(), parakeetBackendFactory: { parakeet })
    manager.setInitialBackendType(.whisperKit)

    // WhisperKit loads in-process behind its relocation gate, never here. A
    // silent no-op would look like a successful warm-up of a model that isn't
    // there; worse, the old code mapped one the gate never saw.
    await #expect(throws: ASRManagerNotOwnedError(backend: .whisperKit)) {
      try await manager.loadModel()
    }
    #expect(manager.isModelLoaded == false)
    let prepares = await parakeet.prepareCount
    #expect(prepares == 0, "the Parakeet backend must not be loaded for a WhisperKit request")
  }

  @Test("transcribe refuses an engine the manager does not own")
  func transcribeRefusesNonOwnedBackend() async throws {
    let parakeet = FakeASRBackend(initiallyReady: true)
    let manager = ASRManager(
      engineMutationScope: .alwaysAllowedForTesting,
      parakeetSelection: ParakeetSelectionProvider(), parakeetBackendFactory: { parakeet })
    manager.setInitialBackendType(.whisperKit)

    await #expect(throws: ASRManagerNotOwnedError(backend: .whisperKit)) {
      _ = try await manager.transcribe(audioSamples: [0.0], options: .default)
    }
  }

  @Test("the manager reports no streaming support for an engine it does not own")
  func noStreamingSupportForNonOwnedBackend() async throws {
    let manager = ASRManager(
      engineMutationScope: .alwaysAllowedForTesting,
      parakeetSelection: ParakeetSelectionProvider(),
      parakeetBackendFactory: { FakeASRBackend(initiallyReady: true) })
    manager.setInitialBackendType(.whisperKit)
    #expect(await manager.activeBackendSupportsStreaming == false)
  }

  @Test(
    "unloadModel during an in-flight load retires it so a retry starts FRESH, not joins the doomed task (Codex re-review P2)"
  )
  func unloadDuringInFlightLoadRetiresTaskSoRetryStartsFresh() async throws {
    // One backend PER LOAD, as production's factory builds. A shared instance let the superseded
    // load's cleanup `unload()` (ready = false) land between the retry's prepare and its readiness
    // read, so the retry's successful load reported not-loaded (flaky in CI, #3191).
    let backends = BackendSequence()
    let manager = ASRManager(
      engineMutationScope: .alwaysAllowedForTesting,
      parakeetSelection: ParakeetSelectionProvider(),
      parakeetBackendFactory: { backends.makeGated() })

    // The manager builds one backend at init; each load then builds its own.
    let initial = backends.count

    // Load A parks in prepare() holding generation G.
    let loadTask = Task { @MainActor in
      await #expect(throws: ASRLoadSupersededError.self) { try await manager.loadModel() }
    }
    while backends.count < initial + 1 { await Task.yield() }
    await waitForPrepareEntered(backends.all[initial])

    // unloadModel bumps the generation (superseding A) AND must retire A's
    // single-flight handle so the next load does not join A's doomed task.
    await manager.unloadModel()

    // Retry B: with the handle retired it starts a FRESH load (a second backend prepares);
    // with the bug it would JOIN A via single-flight and never build a second backend.
    let retry = Task { @MainActor in try await manager.loadModel() }

    // Bounded poll — never a spin-on-condition that could hang under the bug.
    var enteredFresh = false
    for _ in 0..<10_000 {
      if backends.count >= initial + 2, await backends.all[initial + 1].prepareCount >= 1 {
        enteredFresh = true
        break
      }
      await Task.yield()
    }

    for backend in backends.all { await backend.releaseGate() }  // resumes A (throws) and B
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
/// Hands out a new gated backend per `parakeetBackendFactory` call, in order.
final class BackendSequence: @unchecked Sendable {
  private let lock = NSLock()
  private var backends: [FakeASRBackend] = []

  var all: [FakeASRBackend] { lock.withLock { backends } }
  var count: Int { lock.withLock { backends.count } }

  func makeGated() -> FakeASRBackend {
    lock.withLock {
      let backend = FakeASRBackend(initiallyReady: false, gated: true)
      backends.append(backend)
      return backend
    }
  }
}

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

  /// #2132: when false, `prepare()` completes NORMALLY but leaves `isReady`
  /// false — the shape a real backend lands in when an unload or a refused
  /// admission gate wins the race with a load. Default preserves prior behaviour.
  private let readyAfterPrepare: Bool

  /// #3546: when set, `prepare()` throws it (a failed model load).
  private let prepareFailure: (any Error)?

  init(
    initiallyReady: Bool, gated: Bool = false, readyAfterPrepare: Bool = true,
    prepareFailure: (any Error)? = nil
  ) {
    self.ready = initiallyReady
    self.gated = gated
    self.readyAfterPrepare = readyAfterPrepare
    self.prepareFailure = prepareFailure
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
    if let prepareFailure { throw prepareFailure }
    ready = readyAfterPrepare
  }

  /// Release ALL parked `gated` `prepare()` calls (supports multiple waiters).
  func releaseGate() {
    let parked = gateContinuations
    gateContinuations.removeAll()
    for c in parked { c.resume() }
  }

  /// #2787: when set, `transcribe` parks after its readiness guard until
  /// `releaseTranscribeGate()` — the shape of a vendor decode that does not
  /// return. Separate from the `prepare()` gate so a test can hold the decode
  /// with the model loaded normally.
  private var transcribeGated = false
  private var transcribeGateContinuations: [CheckedContinuation<Void, Never>] = []

  func gateTranscribe() { transcribeGated = true }

  private var parkedWaiters: [(id: UUID, continuation: CheckedContinuation<Bool, Never>)] = []

  /// Resolves `true` once a gated `transcribe` is parked, `false` after the
  /// deadline — a signal wait, bounded so a test never hangs on it.
  func transcribeParked() async -> Bool {
    if !transcribeGateContinuations.isEmpty { return true }
    return await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
      let id = UUID()
      parkedWaiters.append((id, c))
      Task {
        try? await Task.sleep(for: .seconds(5))  // deadline-fallback: bounds the signal wait
        await self.expireParkedWaiter(id)
      }
    }
  }

  private func expireParkedWaiter(_ id: UUID) {
    guard let index = parkedWaiters.firstIndex(where: { $0.id == id }) else { return }
    parkedWaiters.remove(at: index).continuation.resume(returning: false)
  }

  func releaseTranscribeGate() {
    let parked = transcribeGateContinuations
    transcribeGateContinuations.removeAll()
    for c in parked { c.resume() }
  }

  func transcribe(
    audioSamples: [Float], options: TranscriptionOptions,
    onInferenceEntered: ASRInferenceEntryObserver? = nil
  ) async throws -> ASRResult {
    // #2132: mirrors `ParakeetBackend.transcribe`'s entry guard exactly
    // (`guard isReady ... else { throw ASRError.notReady }`). A double must
    // refuse what the real tool refuses, or a test proves nothing about it.
    guard ready else { throw ASRError.notReady }
    if transcribeGated {
      await withCheckedContinuation { c in
        transcribeGateContinuations.append(c)
        let waiters = parkedWaiters
        parkedWaiters.removeAll()
        for waiter in waiters { waiter.continuation.resume(returning: true) }
      }
    }
    // #3546: the simulated vendor entry, after readiness and the preparatory gate, behind
    // the last cancellation check, like the real backends.
    try Task.checkCancellation()
    onInferenceEntered?()
    // #2918: a backend that can say how far it is reports through the installed observer,
    // then clears it, exactly as the real backends do.
    if let observer = progressObserver {
      observer(0.25)
      observer(0.75)
    }
    progressObserver = nil
    return ASRResult(
      text: "ok", language: nil, duration: 0, processingTime: 0, backendType: .parakeet)
  }

  private var progressObserver: (@Sendable (Double) -> Void)?
  func setTranscriptionProgressObserver(_ observer: (@Sendable (Double) -> Void)?) async {
    progressObserver = observer
  }
  var progressObserverIsInstalled: Bool { progressObserver != nil }

  /// #3546: when set, `unload()` parks until `releaseUnload()`, so a test can see whether
  /// its caller waits for the cleanup to finish.
  private var unloadGated = false
  private var unloadContinuations: [CheckedContinuation<Void, Never>] = []
  private(set) var unloadsFinished = 0

  func gateUnload() { unloadGated = true }

  func releaseUnload() {
    unloadGated = false
    let parked = unloadContinuations
    unloadContinuations.removeAll()
    for c in parked { c.resume() }
  }

  func unload() async {
    unloadCount += 1
    ready = false
    if unloadGated {
      await withCheckedContinuation { unloadContinuations.append($0) }
    }
    unloadsFinished += 1
  }
}
