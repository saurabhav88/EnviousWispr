import AppKit
import Foundation

/// What the Escape Recovery pill will need in order to paste, frozen before the
/// driver clears its session context (#2087).
///
/// **Nothing writes one yet.** Chunk 7 adds the capture at the terminal, chunk 8
/// the pill that reads it. The sentences below describe the contract this type
/// exists to keep, not behaviour the app performs today.
///
/// **Not the text, by design.** It carries an id, so the presenter can re-read at
/// press time and a row deleted or expired in the meantime resolves to nothing
/// rather than pasting a copy the store no longer agrees with.
///
/// What it does carry is the PASTE TARGET, and that is the whole reason the type
/// exists. `KernelDictationDriver.clearContextConfigIfTerminalOrIdle()` sets
/// `context.targetApp` and `context.targetElement` to nil on the `.idle` arm, and
/// it runs BEFORE `onStateChange` fires, so anything reading them during that
/// callback finds nil. They are captured here first, while they are still live.
///
/// Deliberately NOT `Sendable`: `AXUIElement` and `NSRunningApplication` are
/// main-actor handles, and the plan a `Sendable` planner produces must never be
/// able to carry them. Making that a compile error rather than a convention is
/// the point — see `EscapeRecoveryCompletion`.
@MainActor
public final class CancelUndoPayload {
  /// Identifies the pending row. Re-read at press time, never cached text.
  public let transcriptID: UUID
  /// The app that was frontmost when the user pressed cancel.
  public let targetApp: NSRunningApplication?
  /// The specific field, when one was resolvable. Nil is normal and not a
  /// failure: the paste cascade already handles an app-only target.
  public let targetElement: AXUIElement?

  public init(transcriptID: UUID, targetApp: NSRunningApplication?, targetElement: AXUIElement?) {
    self.transcriptID = transcriptID
    self.targetApp = targetApp
    self.targetElement = targetElement
  }
}

/// A concluded Escape Recovery, as a value (#2087).
///
/// The transported VALUE only. It carries no lifetime rule of its own and may be
/// held or copied freely — the one-shot discipline belongs to
/// `EscapeRecoveryCompletionSlot`, which is what the driver actually owns.
///
/// **"No payload ⇒ no pill" is structural, not asserted.** An earlier draft was a
/// class carrying `outcome` and `payload?` side by side, with an `assert` pinning
/// the two together. `assert` compiles out of Release, so that guarantee held
/// only in Debug — precisely backwards, since Release is where users are. As an
/// enum, `.saved` cannot be written without a target and nothing else can carry
/// one, in every configuration and with no runtime check to forget. Save failure
/// and abandonment cannot present a pill even by mistake.
///
/// One value rather than a sendable outcome passed beside a non-sendable
/// payload: two parallel parameters can disagree, and this cannot. `public` for
/// the same reason `CancelUndoPayload` is — it crosses into
/// `PipelineStateChangeHandler.handle(...)`, which AppKit calls. Only the flat
/// `outcome` continues into the planner's `Sendable` plan; the target stops here.
@MainActor
public enum EscapeRecoveryCompletion {
  /// Text was durably written, and this is how to put it back. The only case
  /// that carries a target, because it is the only one with anything to restore.
  /// (Chunk 9 owns where the row lives and how long it lasts.)
  case saved(CancelUndoPayload)

  /// Every ending that produced no restorable row. Kept as its own closed set
  /// rather than reusing `EscapeRecoveryTerminalOutcome`, so that `.saved` is
  /// simply not expressible without a payload.
  case nothingToRestore(NothingToRestore)

  /// The endings that leave the user with nothing to paste. Four cases, not one
  /// failure flag: `abandoned` is a choice the user made and must never read as
  /// a fault of ours, and `empty` is a recording with no speech in it rather
  /// than something breaking.
  public enum NothingToRestore: String, Equatable, Sendable, CaseIterable {
    case empty
    case transcriptionFailed
    case saveFailed
    case abandoned
  }

  /// The flat outcome the planner and telemetry speak in. Exhaustively switched,
  /// so a new `NothingToRestore` case is a compile error here rather than a
  /// silently unreported ending.
  public var outcome: EscapeRecoveryTerminalOutcome {
    switch self {
    case .saved: return .saved
    case .nothingToRestore(let reason):
      switch reason {
      case .empty: return .empty
      case .transcriptionFailed: return .transcriptionFailed
      case .saveFailed: return .saveFailed
      case .abandoned: return .abandoned
      }
    }
  }

  /// The pill's paste target, or nil when there is nothing to offer.
  public var payload: CancelUndoPayload? {
    switch self {
    case .saved(let payload): return payload
    case .nothingToRestore: return nil
    }
  }
}

/// One-shot storage for a completion, owned by `KernelDictationDriver`.
///
/// **This is where the one-shot guarantee lives**, not on the value it holds.
/// `take()` returns the completion and clears it in the same step, and there is
/// no property read at all. Round 7 of the plan review caught why that matters:
/// `onStateChange` can fire more than once for a session, so a plain read would
/// present the pill again on every later notification and a user who cancelled
/// once would be offered their text two or three times.
///
/// Separate from the completion so the take-and-clear discipline lives in one
/// place rather than at each call site. A caller cannot accidentally read
/// without consuming, because reading is not offered.
@MainActor
package final class EscapeRecoveryCompletionSlot {
  private var stored: EscapeRecoveryCompletion?

  /// Populate the slot. No production caller exists yet; the one that lands must
  /// run BEFORE the driver clears its session context, while the paste target
  /// handles are still live. Today only the driver's DEBUG test seam writes here.
  package func put(_ completion: EscapeRecoveryCompletion) { stored = completion }

  /// Take the completion, clearing it. A second call returns nil — that is the
  /// duplicate-pill guard, and it is why this is a method rather than a property.
  package func take() -> EscapeRecoveryCompletion? {
    defer { stored = nil }
    return stored
  }

  /// Clear without consuming. The driver calls this on the first observation
  /// that reports a new `SessionID`, so a completion nobody took cannot surface
  /// against a later, unrelated dictation.
  package func clear() { stored = nil }

  /// Test-only visibility. Deliberately not a general read accessor: exposing one
  /// would reintroduce exactly the non-consuming read this type exists to forbid.
  #if DEBUG
    package var isEmptyForTesting: Bool { stored == nil }
  #endif
}
