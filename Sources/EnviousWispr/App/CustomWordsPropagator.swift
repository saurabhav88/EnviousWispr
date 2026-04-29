import EnviousWisprCore
import Foundation

/// Broadcasts the active custom-words list to all registered consumers.
///
/// AppState constructs one propagator at init, registers the known consumers
/// (pipeline word-correction + polish steps for both backends + the re-polish
/// service), and forwards `CustomWordsCoordinator.onWordsChanged` into
/// `update(_:)`. Replaces the prior 5-way fanout in AppState plus 5 setter
/// lines in `PipelineSettingsSync`.
///
/// Re-entrancy is contracted out: a consumer's setter must not call
/// `propagator.update(_:)` synchronously. DEBUG builds trap on violation.
@MainActor
final class CustomWordsPropagator {
  private final class WeakBox {
    weak var value: (any CustomWordsConsumer)?
    init(_ value: any CustomWordsConsumer) { self.value = value }
  }

  private var consumers: [WeakBox] = []
  private(set) var words: [CustomWord]
  #if DEBUG
    private var isBroadcasting: Bool = false
  #endif

  init(initialWords: [CustomWord] = []) {
    self.words = initialWords
  }

  /// Add a consumer to the registry. Idempotent on object identity. The
  /// consumer's `customWords` is initial-synced to the propagator's current
  /// `words` value before this call returns.
  func register(_ consumer: any CustomWordsConsumer) {
    let alreadyRegistered = consumers.contains { box in
      guard let existing = box.value else { return false }
      return ObjectIdentifier(existing) == ObjectIdentifier(consumer)
    }
    guard !alreadyRegistered else { return }
    consumers.append(WeakBox(consumer))
    consumer.customWords = words
  }

  /// Broadcast `words` to all live consumers. Dead weak references are
  /// pruned during this call.
  func update(_ words: [CustomWord]) {
    #if DEBUG
      precondition(
        !isBroadcasting,
        "CustomWordsPropagator: re-entrant update is not supported"
      )
      isBroadcasting = true
      defer { isBroadcasting = false }
    #endif
    self.words = words
    consumers.removeAll { $0.value == nil }
    for box in consumers {
      box.value?.customWords = words
    }
  }
}
