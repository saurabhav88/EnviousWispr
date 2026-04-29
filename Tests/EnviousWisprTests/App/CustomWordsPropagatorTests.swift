import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWispr

/// Phase D (#496) — pins the `CustomWordsPropagator` contract around the new
/// registry pattern that replaces AppState's 5-way custom-words fanout.
///
/// Tests assert observable behavior on conforming spy consumers. Spies are
/// plain `@MainActor final class` types — no actor indirection.
///
/// Coverage shape (after Codex truth-audit, 2026-04-29):
/// - Unit: weak storage (deinit probe), initial-sync, dup-register idempotence.
/// - Integration via `wireCustomWords`: AppState's exact wire ordering
///   exercised against spy consumers + a real `CustomWordsCoordinator`. This
///   is the test that catches "future AppState refactor drops a register()
///   call" or "wire ordering reversed."
@MainActor
@Suite("CustomWordsPropagator — Phase D registry contract")
struct CustomWordsPropagatorTests {

  // MARK: - Fixtures

  /// Plain spy. Records every assignment to `customWords` so tests can pin
  /// invocation count and final value at the consumer level.
  private final class SpyConsumer: CustomWordsConsumer {
    var customWords: [CustomWord] = [] {
      didSet { setCount += 1 }
    }
    var setCount: Int = 0
  }

  /// Reference holder for cross-isolation flag access from a nonisolated
  /// `deinit`. Marked `@unchecked Sendable` because all writes happen during
  /// synchronous deallocation on the test's @MainActor thread (autoreleasepool
  /// drain is synchronous), and reads happen from the same actor afterward.
  private final class DeinitFlag: @unchecked Sendable {
    var fired: Bool = false
  }

  /// Spy that flips a flag in `deinit`. Used to actually prove weak storage
  /// in the propagator: a strong-storing buggy implementation would keep
  /// this alive past the autoreleasepool boundary, the flag would stay
  /// false, and the test would fail.
  private final class DeinitProbeSpy: CustomWordsConsumer {
    var customWords: [CustomWord] = []
    let flag: DeinitFlag
    init(flag: DeinitFlag) { self.flag = flag }
    deinit { flag.fired = true }
  }

  private static func makeWord(_ canonical: String) -> CustomWord {
    CustomWord(canonical: canonical)
  }

  // MARK: - Unit: weak storage proven via deinit probe

  /// Substantive proof of weak storage: registers a probe consumer in an
  /// autoreleasepool, asserts its `deinit` fires after the pool exits.
  /// A buggy propagator that stored consumers strongly would keep the probe
  /// alive past the autoreleasepool, the deinit closure would never fire,
  /// and `deinitFired` would stay false.
  @Test("Weak storage — transient consumer is deinit'd after autoreleasepool exits")
  func weakStorageDeinitProbe() {
    let propagator = CustomWordsPropagator()
    let flag = DeinitFlag()
    autoreleasepool {
      let probe = DeinitProbeSpy(flag: flag)
      propagator.register(probe)
      // Sanity: probe received initial-sync before going out of scope.
      #expect(probe.customWords.isEmpty)
    }
    #expect(
      flag.fired,
      "Probe consumer must be deallocated after the autoreleasepool exits — proves the propagator stores it weakly."
    )

    // After deallocation, a subsequent update must not crash and must prune
    // the dead box. Surviving consumer registered AFTER probe death sees
    // the broadcast cleanly.
    let survivor = SpyConsumer()
    propagator.register(survivor)
    let words = [Self.makeWord("survivor")]
    propagator.update(words)
    #expect(survivor.customWords == words)
  }

  // MARK: - Unit: initial-sync on register

  /// `register(_:)` writes the propagator's current `words` to the consumer
  /// before returning. AppState init relies on this for "all consumers have
  /// the seed before the first user mutation."
  @Test("Initial-sync on register — late registrant gets current words")
  func initialSyncOnRegister() {
    let propagator = CustomWordsPropagator()

    let early = SpyConsumer()
    propagator.register(early)
    #expect(early.customWords.isEmpty)
    #expect(early.setCount == 1)

    let updated = [Self.makeWord("alpha"), Self.makeWord("beta")]
    propagator.update(updated)
    #expect(early.customWords == updated)
    #expect(early.setCount == 2)

    // Late-registered consumer must receive `updated` via initial-sync, NOT
    // the empty initial seed and NOT a subsequent broadcast.
    let late = SpyConsumer()
    propagator.register(late)
    #expect(late.customWords == updated)
    #expect(late.setCount == 1)
  }

  // MARK: - Unit: duplicate-register idempotence

  /// Registering the same instance twice must not double-write on broadcast.
  @Test("Duplicate-register idempotence — same instance written once per update")
  func duplicateRegisterIdempotent() {
    let propagator = CustomWordsPropagator()
    let consumer = SpyConsumer()
    propagator.register(consumer)
    propagator.register(consumer)  // second call is a no-op

    let baseline = consumer.setCount
    let word = Self.makeWord("x")
    propagator.update([word])
    #expect(consumer.setCount == baseline + 1)
    #expect(consumer.customWords == [word])
  }

  // MARK: - Integration: wireCustomWords exact AppState ordering

  /// Highest-risk regression test (per Codex grounded review). Drives
  /// `wireCustomWords` — the exact helper AppState's init calls — with spy
  /// consumers + a real `CustomWordsCoordinator`. Catches:
  ///   - someone dropping a `register()` call from AppState's wiring
  ///   - reordering (assigning `onWordsChanged` before registers, or
  ///     registering before the seed)
  ///   - the coordinator's onWordsChanged closure failing to broadcast
  @Test(
    "Integration — wireCustomWords seeds all 5 spy consumers + coordinator broadcast reaches them")
  func wireCustomWordsIntegration() {
    let coordinator = CustomWordsCoordinator()
    let preloaded = [
      Self.makeWord("preload-one"),
      Self.makeWord("preload-two"),
    ]

    // Five spies stand in for the five real production consumers
    // (pipeline × 2 × 2 + polishService).
    let spies: [SpyConsumer] = (0..<5).map { _ in SpyConsumer() }
    let propagator = CustomWordsPropagator()

    wireCustomWords(
      propagator: propagator,
      initialWords: preloaded,
      consumers: spies,
      coordinator: coordinator
    )

    // After wiring, every spy must hold the preloaded words via
    // register()'s initial-sync, BEFORE any user interaction.
    for (i, spy) in spies.enumerated() {
      #expect(
        spy.customWords == preloaded,
        "spy[\(i)] missed the preloaded seed; check register() initial-sync ordering")
    }

    // Now fire the coordinator callback that wireCustomWords installed.
    // Every spy must receive the new list. Catches "onWordsChanged was
    // assigned but doesn't actually broadcast through propagator."
    let updated = preloaded + [Self.makeWord("user-added")]
    coordinator.onWordsChanged?(updated)
    for (i, spy) in spies.enumerated() {
      #expect(
        spy.customWords == updated,
        "spy[\(i)] missed the broadcast triggered through coordinator.onWordsChanged")
    }
  }

  // MARK: - Integration: late-register receives current words

  /// Pins the contract that a consumer registered AFTER an `update()` still
  /// gets the most-recent broadcast value. Future surface for AI-driven custom
  /// words / word-pack sources that may register their own consumers at
  /// runtime.
  @Test("Integration — consumer registered after update receives current words")
  func lateRegisterReceivesCurrent() {
    let propagator = CustomWordsPropagator()
    let alpha = SpyConsumer()
    propagator.register(alpha)

    let firstBatch = [Self.makeWord("one")]
    propagator.update(firstBatch)
    #expect(alpha.customWords == firstBatch)

    let beta = SpyConsumer()
    propagator.register(beta)
    #expect(beta.customWords == firstBatch)

    let secondBatch = [Self.makeWord("one"), Self.makeWord("two")]
    propagator.update(secondBatch)
    #expect(alpha.customWords == secondBatch)
    #expect(beta.customWords == secondBatch)
  }
}
