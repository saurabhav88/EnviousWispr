@preconcurrency import AVFoundation
import EnviousWisprCore
import Testing

@testable import EnviousWisprASR
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
      whisperKitSetup: WhisperKitSetupService(engineMutationScope: .alwaysAllowedForTesting),
      setupStateReader: { .ready },
      preloadAction: { @MainActor in counter.increment() }
    )

    coord.startPreloadObservation()
    // Signal, not clock: wait for the observation Task to actually reach and
    // read the backend guard before asserting the negative it implies.
    for _ in 0..<200 where fakeASR.activeBackendTypeAccessCount == 0 {
      await Task.yield()
    }
    await drainMainActorTasks()

    #expect(fakeASR.activeBackendTypeAccessCount > 0, "the backend guard must have been reached")
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
      whisperKitSetup: WhisperKitSetupService(engineMutationScope: .alwaysAllowedForTesting),
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

  // MARK: - #1918: Ollama status watch (poll + activation)

  /// Default placeholder delay for tests that never let the poll tick on its
  /// own (they assert on `startOllamaStatusWatch()`'s IMMEDIATE effects
  /// only); any test that cares about a poll tick injects its own
  /// signal-controlled `ollamaPollDelay` instead of relying on this firing.
  private func neverFiringPollDelay() async throws {
    try? await Task.sleep(for: .seconds(3600))  // settle: never-fires placeholder, real tests inject their own signal-controlled delay
  }

  private func makeCoordinator(
    ollamaStatusProbe: (@MainActor (String) async -> Void)? = nil,
    ollamaPollDelay: (@MainActor () async throws -> Void)? = nil
  ) -> SetupCoordinator {
    SetupCoordinator(
      asrManager: FakeASRManager(backend: .parakeet),
      whisperKitSetup: WhisperKitSetupService(engineMutationScope: .alwaysAllowedForTesting),
      preloadAction: { @MainActor in },
      ollamaStatusProbe: ollamaStatusProbe,
      ollamaPollDelay: ollamaPollDelay ?? neverFiringPollDelay
    )
  }

  @Test("applicationDidBecomeActive() probes only when a watch is active and the state is eligible")
  func applicationDidBecomeActiveProbesOnlyWhenWatchActive() async {
    let probeLog = ProbeLog()
    let coord = makeCoordinator(
      ollamaStatusProbe: { trigger in await probeLog.record(trigger) })

    // `ollamaSetup.setupState` defaults to `.detecting`, which is NOT
    // eligible for a silent background refresh — reach a real eligible
    // state first, the same way production only ever reaches one: through
    // a genuine call, never a direct assignment.
    _ = await coord.ollamaSetup.isServerRunning(
      transport: { request in
        (
          Data(),
          HTTPURLResponse(
            url: request.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!
        )
      })
    #expect(coord.ollamaSetup.setupState.allowsSilentBackgroundRefresh)

    // Before startOllamaStatusWatch(): no-op.
    coord.applicationDidBecomeActive()
    await drainMainActorTasks()
    #expect(await probeLog.triggers.isEmpty)

    // After starting the watch: probes with "app_active".
    coord.startOllamaStatusWatch()
    coord.applicationDidBecomeActive()
    for _ in 0..<200 where await probeLog.triggers.isEmpty { await Task.yield() }
    #expect(await probeLog.triggers == ["app_active"])

    coord.stopOllamaStatusWatch()
  }

  @Test(
    "cleanup() cancels the Ollama watch tasks: the injected probe receives no further calls even after the delay would have fired again"
  )
  func cleanupCancelsOllamaStatusTasks() async {
    let probeLog = ProbeLog()
    let gate = ReleaseGate()
    let started = AsyncStream.makeStream(of: Void.self)
    let startedContinuation = started.continuation

    let coord = makeCoordinator(
      ollamaStatusProbe: { trigger in await probeLog.record(trigger) },
      ollamaPollDelay: {
        startedContinuation.yield(())
        await gate.wait()
      })

    // Reach a real eligible state first — `.detecting` (the default) would
    // make this test pass vacuously, since no probe would fire either way.
    _ = await coord.ollamaSetup.isServerRunning(
      transport: { request in
        (
          Data(),
          HTTPURLResponse(
            url: request.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!
        )
      })
    #expect(coord.ollamaSetup.setupState.allowsSilentBackgroundRefresh)

    coord.startOllamaStatusWatch()

    var iterator = started.stream.makeAsyncIterator()
    _ = await iterator.next()  // poll task has entered its delay, about to probe once released

    coord.cleanup()
    await gate.release()
    await drainMainActorTasks(200)

    #expect(
      await probeLog.triggers.isEmpty, "no probe should fire once cleanup() has cancelled the watch"
    )
  }

  @Test("cleanup() also cancels migration/preload tasks")
  func cleanupCancelsMigrationAndPreloadTasks() async {
    let fakeASR = FakeASRManager(backend: .whisperKit)
    let migrationLog = ProbeLog()
    let migrationGate = ReleaseGate()
    let migrationStarted = AsyncStream.makeStream(of: Void.self)
    let migrationStartedContinuation = migrationStarted.continuation

    let coord = SetupCoordinator(
      asrManager: fakeASR,
      whisperKitSetup: WhisperKitSetupService(engineMutationScope: .alwaysAllowedForTesting),
      setupStateReader: { .ready },
      runDocumentsMigration: {
        migrationStartedContinuation.yield(())
        migrationStartedContinuation.finish()
        await migrationGate.wait()
        await migrationLog.record("migration-completed")
      },
      preloadAction: { @MainActor in await migrationLog.record("preload-fired") }
    )

    coord.startWhisperKitMigrationThenDetect()

    var iterator = migrationStarted.stream.makeAsyncIterator()
    _ = await iterator.next()  // migration task is parked

    coord.cleanup()
    await migrationGate.release()
    await drainMainActorTasks(200)

    // `runDocumentsMigration()` was already in flight when `cleanup()` ran,
    // so per Swift's cooperative cancellation it legitimately completes and
    // records "migration-completed" — cancellation only takes effect at the
    // NEXT check. What must NOT happen is anything AFTER it: the migration
    // task's own `guard !Task.isCancelled else { return }` (checked right
    // after this await) must stop it from calling `detectState()` and
    // `startPreloadObservation()` — and since this test's fake backend is
    // `.whisperKit` with `setupStateReader` fixed to `.ready`, preload would
    // fire almost immediately if that guard were missing.
    #expect(await migrationLog.triggers.contains("migration-completed"))
    #expect(
      !(await migrationLog.triggers.contains("preload-fired")),
      "cleanup() must stop the migration chain before it reaches startPreloadObservation()/preloadAction"
    )
  }

  @Test("stopOllamaStatusWatch actually cancels — no further probe calls after stop")
  func stopOllamaStatusWatchActuallyCancels() async {
    let probeLog = ProbeLog()
    let gate = ReleaseGate()
    let started = AsyncStream.makeStream(of: Void.self)
    let startedContinuation = started.continuation

    let coord = makeCoordinator(
      ollamaStatusProbe: { trigger in await probeLog.record(trigger) },
      ollamaPollDelay: {
        startedContinuation.yield(())
        await gate.wait()
      })

    // Reach a real eligible state first — `.detecting` (the default) would
    // make this test pass vacuously, since no probe would fire either way.
    _ = await coord.ollamaSetup.isServerRunning(
      transport: { request in
        (
          Data(),
          HTTPURLResponse(
            url: request.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!
        )
      })
    #expect(coord.ollamaSetup.setupState.allowsSilentBackgroundRefresh)

    coord.startOllamaStatusWatch()

    var iterator = started.stream.makeAsyncIterator()
    _ = await iterator.next()  // poll task has entered its delay, about to probe once released

    coord.stopOllamaStatusWatch()
    await gate.release()
    await drainMainActorTasks(200)

    #expect(
      await probeLog.triggers.isEmpty,
      "no probe should fire once stopOllamaStatusWatch() has cancelled the poll")
  }

  @Test(
    "cleanup() cancelling whisperKitMigrationTask before it starts must stop it from ever entering runDocumentsMigration — Task.cancel() only sets a flag, so a closure cancelled before entry still runs unless its own first line checks Task.isCancelled"
  )
  func cleanupBeforeMigrationTaskStartsPreventsEntry() async {
    let migrationLog = ProbeLog()
    let coord = SetupCoordinator(
      asrManager: FakeASRManager(backend: .whisperKit),
      whisperKitSetup: WhisperKitSetupService(engineMutationScope: .alwaysAllowedForTesting),
      setupStateReader: { .ready },
      runDocumentsMigration: { await migrationLog.record("migration-entered") },
      preloadAction: { @MainActor in }
    )

    coord.startWhisperKitMigrationThenDetect()
    coord.cleanup()  // cancels the Task before it has necessarily been scheduled to run at all
    await drainMainActorTasks(200)

    #expect(
      await migrationLog.triggers.isEmpty,
      "a migration task cancelled before it starts must never enter runDocumentsMigration")
  }

  @Test(
    "stopOllamaStatusWatch() cancelling the activation-probe task before it starts must stop it from ever probing — same Task.cancel()-only-sets-a-flag reasoning as the migration case"
  )
  func stopWatchBeforeActivationProbeStartsPreventsEntry() async {
    let probeLog = ProbeLog()
    let coord = makeCoordinator(ollamaStatusProbe: { trigger in await probeLog.record(trigger) })

    _ = await coord.ollamaSetup.isServerRunning(
      transport: { request in
        (
          Data(),
          HTTPURLResponse(
            url: request.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!
        )
      })
    #expect(coord.ollamaSetup.setupState.allowsSilentBackgroundRefresh)

    coord.startOllamaStatusWatch()
    coord.applicationDidBecomeActive()  // launches the activation-probe Task
    coord.stopOllamaStatusWatch()  // cancels it before it has necessarily been scheduled to run at all
    await drainMainActorTasks(200)

    #expect(
      await probeLog.triggers.isEmpty,
      "an activation-probe task cancelled before it starts must never call ollamaStatusProbe")
  }
}

/// Signal-based release for a parked async closure, matching
/// `OllamaSetupServiceDetectStateTests.ReleaseGate`.
private actor ReleaseGate {
  private var released = false
  private var waiter: CheckedContinuation<Void, Never>?
  func release() {
    released = true
    waiter?.resume()
    waiter = nil
  }
  func wait() async {
    if released { return }
    await withCheckedContinuation { waiter = $0 }
  }
}

/// Thread-safe log of every trigger an injected probe/callback was invoked
/// with, readable from a `@Sendable` closure under Swift 6 strict concurrency.
private actor ProbeLog {
  private(set) var triggers: [String] = []
  func record(_ trigger: String) { triggers.append(trigger) }
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
  private let backendType: ASRBackendType
  /// Signal, not clock: `startPreloadObservation()`'s guard reads this exactly
  /// once per loop entry before deciding whether to proceed — a test polls
  /// this count to prove the observation Task actually reached the guard,
  /// rather than waiting a fixed number of yields and hoping.
  private(set) var activeBackendTypeAccessCount = 0
  var activeBackendType: ASRBackendType {
    activeBackendTypeAccessCount += 1
    return backendType
  }
  init(backend: ASRBackendType) { self.backendType = backend }

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
