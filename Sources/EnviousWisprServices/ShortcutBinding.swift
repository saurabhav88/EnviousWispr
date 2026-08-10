import AppKit

/// Which action a shortcut triggers.
///
/// A closed set, deliberately: the #1991 defect was possible because "record"
/// and "cancel" were never named as members of one thing, so a dispatch path
/// could handle one and silently omit the other and nothing said so.
package enum ShortcutRole: String, Sendable, CaseIterable {
  case record
  case cancel
}

/// One shortcut, whatever kind it is.
///
/// Today this is keyboard-only. It exists as an enum rather than a struct
/// because a mouse case is the next member (#1996) and the whole point of the
/// type is that adding a kind forces every consumer to say what it does with
/// it, instead of a new kind being quietly invisible to one of two dispatch
/// paths — which is exactly how a bare-modifier cancel key came to be stored,
/// displayed, and completely inert for six users.
///
/// **A bare modifier stores empty modifiers, not its own flag.** Settled by
/// #1987: a standalone Right Command is `keyboard(keyCode: 54, modifiers: [])`,
/// because storing `.command` would require the user to hold the key while
/// pressing it. `isBareModifier` is the single reader of that convention.
package enum ShortcutBinding: Equatable, Sendable {
  case keyboard(keyCode: UInt16, modifiers: NSEvent.ModifierFlags)

  /// True when this is a standalone modifier key with no chord around it — the
  /// shape Carbon cannot register and the `NSEvent` monitors must observe.
  package var isBareModifier: Bool {
    switch self {
    case .keyboard(let keyCode, let modifiers):
      return modifiers.isEmpty && ModifierKeyCodes.isModifierOnly(keyCode)
    }
  }

  /// True when Carbon can register this binding. The complement of
  /// `isBareModifier` today; a distinct name because the two questions diverge
  /// the moment a non-keyboard kind exists, and a caller asking "can Carbon take
  /// this" must not be answered by "is it a bare modifier".
  package var isCarbonRegistrable: Bool {
    switch self {
    case .keyboard:
      return !isBareModifier
    }
  }

  /// The modifiers this binding requires to be HELD. Empty for a bare modifier,
  /// which stores its own flag as empty by the #1987 convention.
  package var requiredModifiers: NSEvent.ModifierFlags {
    switch self {
    case .keyboard(_, let modifiers):
      return modifiers
    }
  }
}

/// The single authority for what an input means.
///
/// Pure and `nonisolated` by construction: no state, no timers, no side effects.
/// That is what makes it testable without a live event stream, and it is a
/// requirement rather than a nicety for #1996, where the mouse tap callback must
/// reach a verdict synchronously on its own thread.
package enum ShortcutMatcher {

  /// Which armed role a bare-modifier key press belongs to, if any.
  ///
  /// `armed` is passed in rather than inferred because the two roles are not
  /// symmetric: record is live whenever the service is running, while cancel is
  /// armed only for the duration of a recording. A matcher that assumed both
  /// were always live would cancel recordings that had not started.
  ///
  /// **Record wins a tie, and nothing currently prevents the tie.** No conflict
  /// check has ever existed at either capture surface, so a user can already
  /// have both roles on one key and some may. Preferring record keeps their
  /// behaviour exactly as it is today — the old dispatch compared against the
  /// record key alone, so record won there too — which means this change is not
  /// a regression for them, merely not yet a fix.
  ///
  /// Refusing the pair belongs at capture time, where it can be explained in the
  /// UI, and it needs both recorders plus user-visible copy. That is the next
  /// slice's work and is NOT implemented here. This comment says so rather than
  /// implying a guard exists, and no unused `conflicts(...)` helper ships ahead
  /// of the consumers that would call it.
  package static func role(
    forBareModifierKeyCode keyCode: UInt16,
    record: ShortcutBinding,
    cancel: ShortcutBinding,
    armed: Set<ShortcutRole>
  ) -> ShortcutRole? {
    if armed.contains(.record), record == .keyboard(keyCode: keyCode, modifiers: []) {
      return .record
    }
    if armed.contains(.cancel), cancel == .keyboard(keyCode: keyCode, modifiers: []) {
      // REFUSE when this modifier is also the first half of the record chord.
      //
      // Cancel on bare Right Command with record on Command+D: pressing Command
      // to STOP the recording arrives here first, as a bare Command press that
      // matches the cancel binding exactly, and the recording is discarded
      // before D is ever pressed. The user loses everything they just said while
      // trying to stop — and it is deterministic, not a race.
      //
      // Pre-fix dispatch compared against the record key alone and returned
      // early, so this is a regression THIS change introduced, and it lands
      // hardest on precisely the users it was written for.
      //
      // Refusing is the correct direction, not a compromise: while the record
      // chord needs this modifier, a bare press of it is genuinely ambiguous —
      // nothing here can distinguish "cancel" from "starting the record chord",
      // and no amount of waiting makes it unambiguous without inventing a
      // timeout that would itself be wrong. Accepting wrongly destroys dictation
      // the user authored; refusing wrongly costs a shortcut that could never
      // have worked reliably in that configuration.
      if let flag = ModifierKeyCodes.flag(for: keyCode),
        record.requiredModifiers.contains(flag)
      {
        return nil
      }
      return .cancel
    }
    return nil
  }
}
