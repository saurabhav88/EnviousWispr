import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWispr

/// Phase D (#496) — pins the `CustomWordsPropagator` contract around the new
/// registry pattern that replaces AppState's 5-way custom-words fanout.
///
/// Tests assert observable behavior on conforming spy consumers, not internal
/// `consumers` array state. Spies are plain `@MainActor final class` types —
/// no actor indirection, no production-protocol re-use beyond the contract
/// the propagator broadcasts on.
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

  private static func makeWord(_ canonical: String) -> CustomWord {
    CustomWord(canonical: canonical)
  }

  // MARK: - Unit: weak-ref behavior

  /// Replaces "dead-pruning internal state" assertion (which would require a
  /// test seam to inspect `consumers`). Pins observable behavior: a deallocated
  /// consumer does not cause a crash on next `update`, and surviving consumers
  /// continue to receive broadcasts.
  @Test("Weak-ref behavior — surviving consumer still receives, no crash")
  func weakRefSurvivorReceives() {
    let propagator = CustomWordsPropagator()
    let survivor = SpyConsumer()
    propagator.register(survivor)

    // Register a transient consumer in a scope so its strong ref drops at
    // scope exit. The propagator's WeakBox is the only remaining reference,
    // and that reference is weak.
    autoreleasepool {
      let transient = SpyConsumer()
      propagator.register(transient)
      // Confirm initial-sync hit the transient before it drops.
      #expect(transient.setCount == 1)
    }

    let words = [Self.makeWord("survivor")]
    propagator.update(words)

    #expect(survivor.customWords == words)
    // Second update should also succeed — pruning happens inside update.
    let words2 = [Self.makeWord("survivor"), Self.makeWord("again")]
    propagator.update(words2)
    #expect(survivor.customWords == words2)
  }

  // MARK: - Unit: initial-sync on register

  /// `register(_:)` writes the propagator's current `words` to the consumer
  /// before returning. This is the contract that AppState init relies on for
  /// "all 5 consumers have the seed before the first user mutation."
  @Test("Initial-sync on register — late registrant gets current words")
  func initialSyncOnRegister() {
    let propagator = CustomWordsPropagator()

    let early = SpyConsumer()
    propagator.register(early)
    #expect(early.customWords.isEmpty)  // initial-synced from empty seed
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
    propagator.register(consumer)  // idempotent

    let baseline = consumer.setCount
    let word = Self.makeWord("x")
    propagator.update([word])
    #expect(consumer.setCount == baseline + 1)
    #expect(consumer.customWords == [word])
  }

  // MARK: - Unit: re-entrancy contract (DEBUG only)

  #if DEBUG
    /// Re-entrant `update()` from inside a consumer setter is contracted out.
    /// DEBUG builds trap immediately. This test documents the contract; production
    /// consumers MUST NOT re-enter the propagator synchronously.
    ///
    /// Skipped at runtime today: Swift Testing does not have a public API for
    /// asserting `precondition()` traps without crashing the test process. The
    /// contract is documented in `CustomWordsPropagator.update(_:)`. Future
    /// upgrade if a real re-entrant consumer appears: replace this no-op with
    /// a coalesced last-write-wins implementation and assert ordering instead.
    @Test("Re-entrancy contract — documented (skipped at runtime; precondition would trap)")
    func reentrancyContractIsDocumented() {
      // Intentionally does nothing at runtime. The contract is enforced by the
      // DEBUG `precondition(!isBroadcasting, ...)` inside `update(_:)`. Trying
      // to assert that here would crash the test process.
      //
      // Sanity: confirm that a normal (non-re-entrant) update sequence works.
      let propagator = CustomWordsPropagator()
      let spy = SpyConsumer()
      propagator.register(spy)
      let word = Self.makeWord("re-entry-not-attempted")
      propagator.update([word])
      #expect(spy.customWords == [word])
    }
  #endif

  // MARK: - Integration: initial-launch seeding

  /// Highest-risk regression. Pins the AppState init wire ordering's contract:
  /// preloaded coordinator words reach all known consumers BEFORE any user
  /// interaction. If Phase D's wire ordering breaks, this test fails before the
  /// propagator ever broadcasts on a real event.
  @Test("Integration — initial-launch seeding from preloaded words")
  func initialLaunchSeeding() {
    let preloaded = [
      Self.makeWord("foo"),
      Self.makeWord("bar"),
      Self.makeWord("baz"),
    ]

    // Mirrors AppState init: seed via update(_:) with no consumers attached,
    // then register each consumer (each receives the seed via initial-sync).
    let propagator = CustomWordsPropagator()
    propagator.update(preloaded)

    let one = SpyConsumer()
    let two = SpyConsumer()
    let three = SpyConsumer()
    propagator.register(one)
    propagator.register(two)
    propagator.register(three)

    #expect(one.customWords == preloaded)
    #expect(two.customWords == preloaded)
    #expect(three.customWords == preloaded)
    // Each consumer received exactly one write (the initial-sync). No
    // subsequent broadcast was needed.
    #expect(one.setCount == 1)
    #expect(two.setCount == 1)
    #expect(three.setCount == 1)
  }

  // MARK: - Integration: late-register receives current words

  /// Pins the contract that a consumer registered AFTER an `update()` still
  /// gets the most-recent broadcast value. Future surface for "AI-driven custom
  /// words" or "word-pack sources" that may register their own consumers at
  /// runtime relies on this behavior.
  @Test("Integration — consumer registered after update receives current words")
  func lateRegisterReceivesCurrent() {
    let propagator = CustomWordsPropagator()
    let alpha = SpyConsumer()
    propagator.register(alpha)

    let firstBatch = [Self.makeWord("one")]
    propagator.update(firstBatch)
    #expect(alpha.customWords == firstBatch)

    // Late-register: must see firstBatch immediately via initial-sync.
    let beta = SpyConsumer()
    propagator.register(beta)
    #expect(beta.customWords == firstBatch)

    // Another broadcast: both alpha and beta see it.
    let secondBatch = [Self.makeWord("one"), Self.makeWord("two")]
    propagator.update(secondBatch)
    #expect(alpha.customWords == secondBatch)
    #expect(beta.customWords == secondBatch)
  }
}
