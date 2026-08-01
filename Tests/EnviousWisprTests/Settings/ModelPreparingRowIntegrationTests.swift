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
  private func driveToParkedWarm(
    _ fake: FakeEngineDeps, _ warm: AsyncLatch
  ) async -> EngineCoordinator {
    fake.whisperKitInstalled = false
    fake.onWarmAwait = { await warm.wait() }
    let c = fake.makeStartedCoordinator()

    // The user picks the optional engine before it exists on disk. The switch is refused
    // (gate 4, not installed) and Parakeet stays active — this is the real ordering, since
    // the Download button only renders once WhisperKit is selected.
    fake.selected = .whisperKit
    c.poke(.settingsChanged)

    // Download completes. `observeInstalledState` fires exactly this poke on admission.
    fake.whisperKitInstalled = true
    c.poke(.setupStateChanged)

    await warm.waitUntilWaiting()
    return c
  }

  @Test("a completed download shows the preparing copy, then Model Ready")
  func settledWarmRoundTrip() async {
    let fake = FakeEngineDeps(selected: .parakeet, active: .parakeet)
    let warm = AsyncLatch()
    let c = await driveToParkedWarm(fake, warm)

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
  func failedWarmReturnsToReady() async {
    let fake = FakeEngineDeps(selected: .parakeet, active: .parakeet)
    fake.warmOutcome[.whisperKit] = .failed(FakeWarmError.failed)
    let warm = AsyncLatch()
    let c = await driveToParkedWarm(fake, warm)

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
  func cancelledWarmReturnsToReady() async {
    let fake = FakeEngineDeps(selected: .parakeet, active: .parakeet)
    fake.warmOutcome[.whisperKit] = .cancelled
    let warm = AsyncLatch()
    let c = await driveToParkedWarm(fake, warm)

    #expect(renderedLabel(c) == ModelPreparingCopy.preparing)

    let completed = AsyncLatch()
    c.onEngineStateChangedForRecovery = { completed.release() }
    warm.release()
    await completed.wait()
    #expect(renderedLabel(c) == ModelPreparingCopy.ready)
  }
}
