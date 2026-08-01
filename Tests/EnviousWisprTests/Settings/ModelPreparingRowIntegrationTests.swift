import EnviousWisprCore
import EnviousWisprPipeline
import Testing

@testable import EnviousWisprAppKit

/// #1635 §11.4: the JOIN between the two halves of this fix.
///
/// Chunk 1 proves the coordinator publishes `warmInFlight`. Chunk 2 proves the copy mapping
/// turns `.whisperKit` into the preparing string. Neither proves the value the coordinator
/// actually publishes is the value the production mapper actually receives — and that gap
/// is precisely where the previous attempt at this issue died: every piece passed its own
/// test while the label could never appear on screen.
///
/// So these tests drive the real download-completion trigger (`isInstalled` flipping true,
/// then the `.setupStateChanged` poke that `observeInstalledState` fires on admission),
/// take the coordinator's OWN published snapshot, and feed it to the production
/// `ModelPreparingCopy.label` — the same call the row makes. No hand-supplied readiness, no
/// hand-built `EngineStatus`, no sleeps.
@MainActor
@Suite("Model preparing row integration (#1635)", .serialized)
struct ModelPreparingRowIntegrationTests {

  /// What the row would render right now, through the production mapping.
  private func renderedLabel(_ c: EngineCoordinator) -> String {
    ModelPreparingCopy.label(warmInFlight: c.status.warmInFlight)
  }

  /// Drive: not installed → user picks WhisperKit → download admits → coordinator switches
  /// and warms. Returns the coordinator with its warm parked on `warm`.
  ///
  /// **The admission is NOT poked by hand.** Flipping `whisperKitInstalled` is the whole
  /// trigger: the fake's flag is `@Observable`, so the coordinator's own
  /// `observeInstalledState()` sees the change and fires `.setupStateChanged` itself. An
  /// earlier draft called `poke(.setupStateChanged)` manually, which exercised the EFFECT
  /// of the trigger rather than the trigger, and the audit caught it.
  ///
  /// **IF THIS HANGS, `FakeEngineDeps.whisperKitInstalled` HAS STOPPED BEING OBSERVABLE.**
  /// The `#require` below does not catch that: losing observability still leaves the switch
  /// correctly blocked, so the precondition passes and the hang lands later at
  /// `waitUntilWaiting()`, waiting for a warm the coordinator was never told to start.
  /// Do NOT "fix" it with a timeout — that puts a clock back into the one place this test
  /// deliberately has none. Restore the `@Observable` box instead.
  private func driveToParkedWarm(
    _ fake: FakeEngineDeps, _ warm: AsyncLatch
  ) async throws -> EngineCoordinator {
    fake.whisperKitInstalled = false
    fake.onWarmAwait = { await warm.wait() }
    let c = fake.makeStartedCoordinator()

    // The user picks the optional engine before it exists on disk. The switch must be
    // refused (gate 4, not installed) with Parakeet still active — this is the real
    // ordering, since the Download button only renders once WhisperKit is selected.
    fake.selected = .whisperKit
    c.poke(.settingsChanged)
    let blocked = await enginePoll { c.status.blockedReason == .notInstalled }
    try #require(blocked, "an uninstalled engine must block the switch, not warm")
    #expect(fake.active == .parakeet, "and the old engine stays active meanwhile")
    #expect(fake.warmCount == 0, "nothing may warm before the model exists")
    #expect(renderedLabel(c) == ModelPreparingCopy.ready, "and the row is not preparing yet")

    // Download completes. Nothing else: the observation does the rest.
    fake.whisperKitInstalled = true

    await warm.waitUntilWaiting()
    return c
  }

  @Test("a completed download shows the preparing copy, then Model Ready")
  func settledWarmRoundTrip() async throws {
    let fake = FakeEngineDeps(selected: .parakeet, active: .parakeet)
    let warm = AsyncLatch()
    let c = try await driveToParkedWarm(fake, warm)

    #expect(
      renderedLabel(c) == ModelPreparingCopy.preparing,
      "the row must render the preparing copy from the coordinator's own published value")
    #expect(fake.active == .whisperKit, "and the engine really did switch")

    let completed = AsyncLatch()
    c.onEngineStateChangedForRecovery = { completed.release() }
    warm.release()
    await completed.wait()
    #expect(renderedLabel(c) == ModelPreparingCopy.ready, "and settles back to Model Ready")
  }

  @Test("a failed warm returns the row to Model Ready, never a stuck spinner")
  func failedWarmReturnsToReady() async throws {
    let fake = FakeEngineDeps(selected: .parakeet, active: .parakeet)
    fake.warmOutcome[.whisperKit] = .failed(FakeWarmError.failed)
    let warm = AsyncLatch()
    let c = try await driveToParkedWarm(fake, warm)

    #expect(renderedLabel(c) == ModelPreparingCopy.preparing)

    let completed = AsyncLatch()
    c.onEngineStateChangedForRecovery = { completed.release() }
    warm.release()
    await completed.wait()
    #expect(
      renderedLabel(c) == ModelPreparingCopy.ready,
      "a failed load must not leave a progress label spinning forever")
  }

  @Test("a cancelled warm returns the row to Model Ready")
  func cancelledWarmReturnsToReady() async throws {
    let fake = FakeEngineDeps(selected: .parakeet, active: .parakeet)
    fake.warmOutcome[.whisperKit] = .cancelled
    let warm = AsyncLatch()
    let c = try await driveToParkedWarm(fake, warm)

    #expect(renderedLabel(c) == ModelPreparingCopy.preparing)

    let completed = AsyncLatch()
    c.onEngineStateChangedForRecovery = { completed.release() }
    warm.release()
    await completed.wait()
    #expect(renderedLabel(c) == ModelPreparingCopy.ready)
  }
}
