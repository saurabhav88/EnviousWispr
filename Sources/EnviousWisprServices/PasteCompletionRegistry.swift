import Foundation

/// Phase 0 (#640) — broadcasts paste-completion events from the dictation
/// pipeline. Bible §6.5.
///
/// Emitted by `TranscriptFinalizer` after a successful auto-paste. Phase 7
/// (#629) auto-learn is the first planned subscriber: it watches for edits to
/// the just-pasted text and surfaces them as custom-word suggestions.
///
/// **Scope of emission** (intentional, see plan §3.5):
/// - YES: dictation auto-paste via `TranscriptFinalizer.deliverPaste` when
///   the cascade outcome is `.delivered` (paste actually landed).
/// - NO: dictation auto-paste that fell back to clipboard-only (e.g. AX
///   denied, CGEvent failed) — observers would falsely learn from a paste
///   that did not happen.
/// - NO: dictation copy-only branch (no paste attempted).
/// - NO: saved-transcript Copy/Paste buttons (manual UI gesture, not dictation).
public struct PasteCompletionEvent: Sendable {
  public let pastedText: String
  public let destinationBundleID: String?
  public let timestamp: Date

  public init(pastedText: String, destinationBundleID: String?, timestamp: Date = Date()) {
    self.pastedText = pastedText
    self.destinationBundleID = destinationBundleID
    self.timestamp = timestamp
  }
}

/// Subscribers conform to receive `PasteCompletionEvent` notifications.
/// Stored weakly by `PasteCompletionRegistry`. Calls to `pasteCompleted` run
/// on `@MainActor` because the registry itself is `@MainActor`-isolated.
@MainActor
public protocol PasteCompletionObserver: AnyObject {
  func pasteCompleted(_ event: PasteCompletionEvent)
}

/// Single shared registry per app instance. Constructed inside
/// `TranscriptPolishService` and threaded into both pipeline finalizers via
/// `TranscriptFinalizer.init`. Phase 7 subscribers register here.
///
/// All operations execute on `@MainActor` because the only emitter
/// (`TranscriptFinalizer.finalize`) and the only foreseeable subscribers
/// (AX observation in Phase 7) live on the main actor. Keeping the actor
/// constraint tight avoids paying for unnecessary cross-actor hops on the
/// dictation hot path.
@MainActor
public final class PasteCompletionRegistry {
  private final class WeakBox {
    weak var value: (any PasteCompletionObserver)?
    init(_ value: any PasteCompletionObserver) { self.value = value }
  }

  private var observers: [WeakBox] = []

  public init() {}

  /// Register `observer` for future events. Idempotent on object identity.
  /// Stored weakly — observers must outlive their registration via their own
  /// strong reference.
  public func subscribe(_ observer: any PasteCompletionObserver) {
    let alreadyRegistered = observers.contains { box in
      guard let existing = box.value else { return false }
      return ObjectIdentifier(existing) == ObjectIdentifier(observer)
    }
    guard !alreadyRegistered else { return }
    observers.append(WeakBox(observer))
  }

  /// Broadcast `event` to all live observers. Dead weak references are
  /// pruned during this call.
  public func emit(_ event: PasteCompletionEvent) {
    observers.removeAll { $0.value == nil }
    for box in observers {
      box.value?.pasteCompleted(event)
    }
  }

  /// Test-only — current observer count (after pruning dead weak refs).
  // periphery:ignore - test seam
  public var observerCount: Int {
    observers.removeAll { $0.value == nil }
    return observers.count
  }
}
