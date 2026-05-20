import EnviousWisprCore
import EnviousWisprServices
import Foundation

/// Phase 0 (#640) — broadcasts the active vocabulary to consumers via two
/// typed lanes: corrector and polish. Pack-sourced terms reach corrector
/// only, never polish (bible §2.2). The lane split makes pack-to-prompt
/// leakage a Swift compile error.
///
/// `EnviousWisprApp.init()` constructs one propagator, registers the known
/// consumers (pipeline word-correction × 2, pipeline llmPolish × 2,
/// polishService.llmPolishStep = 5 total), and forwards
/// `CustomWordsCoordinator.onWordsChanged` into `update(corrector:polish:)`.
///
/// Re-entrancy is contracted out: a consumer's setter must not call
/// `propagator.update(...)` synchronously. DEBUG builds trap on violation.
@MainActor
final class CustomWordsPropagator {
  private final class CorrectorBox {
    weak var value: (any CorrectorVocabularyConsumer)?
    init(_ value: any CorrectorVocabularyConsumer) { self.value = value }
  }
  private final class PolishBox {
    weak var value: (any PolishVocabularyConsumer)?
    init(_ value: any PolishVocabularyConsumer) { self.value = value }
  }

  private var correctorConsumers: [CorrectorBox] = []
  private var polishConsumers: [PolishBox] = []
  private(set) var corrector: CorrectorVocabulary
  private(set) var polish: PolishVocabulary
  #if DEBUG
    private var isBroadcasting: Bool = false
  #endif

  init(corrector: CorrectorVocabulary = .empty, polish: PolishVocabulary = .empty) {
    self.corrector = corrector
    self.polish = polish
  }

  /// Add a corrector-lane consumer. Idempotent on object identity. The
  /// consumer's `correctorVocabulary` is initial-synced to the propagator's
  /// current `corrector` value before this call returns.
  func register(_ consumer: any CorrectorVocabularyConsumer) {
    let already = correctorConsumers.contains { box in
      guard let existing = box.value else { return false }
      return ObjectIdentifier(existing) == ObjectIdentifier(consumer)
    }
    guard !already else { return }
    correctorConsumers.append(CorrectorBox(consumer))
    consumer.correctorVocabulary = corrector
  }

  /// Add a polish-lane consumer. Idempotent on object identity. The
  /// consumer's `polishVocabulary` is initial-synced to the propagator's
  /// current `polish` value before this call returns.
  func register(_ consumer: any PolishVocabularyConsumer) {
    let already = polishConsumers.contains { box in
      guard let existing = box.value else { return false }
      return ObjectIdentifier(existing) == ObjectIdentifier(consumer)
    }
    guard !already else { return }
    polishConsumers.append(PolishBox(consumer))
    consumer.polishVocabulary = polish
  }

  /// Broadcast `corrector` and `polish` to all live consumers atomically.
  /// Both lanes share the same generation for this call. Dead weak refs are
  /// pruned during this call.
  func update(corrector: CorrectorVocabulary, polish: PolishVocabulary) {
    #if DEBUG
      precondition(
        !isBroadcasting,
        "CustomWordsPropagator: re-entrant update is not supported"
      )
      isBroadcasting = true
      defer { isBroadcasting = false }
    #endif
    self.corrector = corrector
    self.polish = polish
    correctorConsumers.removeAll { $0.value == nil }
    polishConsumers.removeAll { $0.value == nil }
    for box in correctorConsumers {
      box.value?.correctorVocabulary = corrector
    }
    for box in polishConsumers {
      box.value?.polishVocabulary = polish
    }
    // Phase 8a (#620): emit one event per lane per atomic broadcast.
    // Privacy-safe: counts only, no term strings. Bible §14.1 + §14.3.
    //
    // Codex audit P2 fix: skip emission when no consumers are registered.
    // `wireCustomWords` calls `update(...)` BEFORE registering consumers
    // (the seed step) so `register()`'s initial-sync sees the right value;
    // emitting during that pre-registration seed would produce misleading
    // `consumer_count=0` events on every app launch. Live broadcasts from
    // `coordinator.onWordsChanged` always have consumers and emit normally.
    if !correctorConsumers.isEmpty {
      TelemetryService.shared.customWordsPropagatorBroadcast(
        lane: "corrector",
        generation: corrector.generation,
        consumerCount: correctorConsumers.count,
        termCount: corrector.terms.count
      )
    }
    if !polishConsumers.isEmpty {
      TelemetryService.shared.customWordsPropagatorBroadcast(
        lane: "polish",
        generation: polish.generation,
        consumerCount: polishConsumers.count,
        termCount: polish.terms.count
      )
    }
  }
}

// MARK: - Wiring helper (extracted for testability)

/// Wires a `CustomWordsPropagator` to its consumers and a coordinator using
/// the former root state's exact init ordering: seed via `update`, register all consumers
/// (each receives the seed via initial-sync), then assign the coordinator's
/// `onWordsChanged` callback to broadcast future mutations.
///
/// Order is non-reversible. Reordering — e.g. assigning `onWordsChanged`
/// before registering consumers, or registering before seeding — produces
/// different observable behavior on first launch.
///
/// Returns the assigned `onWordsChanged` closure so tests can fire it
/// without depending on `CustomWordsCoordinator` internals.
@MainActor
@discardableResult
func wireCustomWords(
  propagator: CustomWordsPropagator,
  initialWords: [CustomWord],
  correctorConsumers: [any CorrectorVocabularyConsumer],
  polishConsumers: [any PolishVocabularyConsumer],
  coordinator: CustomWordsCoordinator
) -> ([CustomWord]) -> Void {
  let seed = LanePartitioner.split(initialWords, generation: 0)
  propagator.update(corrector: seed.corrector, polish: seed.polish)
  for consumer in correctorConsumers {
    propagator.register(consumer)
  }
  for consumer in polishConsumers {
    propagator.register(consumer)
  }
  // PR-C.1 of #763: the closure captures `propagator` STRONGLY. Pre-PR-C.1
  // this was `[weak propagator]` because the former root state held the propagator as a
  // stored `let`. With construction moved to `EnviousWisprApp.init()` the
  // propagator would otherwise have no strong owner once the former root state is deleted
  // (PR-C.4) — `CustomWordsCoordinator` only stores this closure. Strong
  // capture anchors the propagator's lifetime to the coordinator (App-owned
  // `@State`). No retain cycle: the propagator holds only weak consumer
  // boxes and never references the coordinator.
  let onChange: ([CustomWord]) -> Void = { words in
    let next = LanePartitioner.split(words, generation: propagator.corrector.generation &+ 1)
    propagator.update(corrector: next.corrector, polish: next.polish)
  }
  coordinator.onWordsChanged = onChange
  return onChange
}

/// Splits a flat `[CustomWord]` (as produced by `CustomWordsCoordinator`)
/// into the two typed lanes. Both lanes currently receive the same terms;
/// the type distinction (`CorrectorVocabulary` vs `PolishVocabulary`) is the
/// architectural seam that prevents accidental cross-wiring at compile time.
@MainActor
enum LanePartitioner {
  static func split(_ words: [CustomWord], generation: UInt64) -> (
    corrector: CorrectorVocabulary, polish: PolishVocabulary
  ) {
    return (
      corrector: CorrectorVocabulary(terms: words, generation: generation),
      polish: PolishVocabulary(terms: words, generation: generation)
    )
  }
}
