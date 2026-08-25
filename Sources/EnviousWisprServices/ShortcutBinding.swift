import AppKit

/// Which action a shortcut triggers.
///
/// A closed set, deliberately: the #1991 defect was possible because "record"
/// and "cancel" were never named as members of one thing, so a dispatch path
/// could handle one and silently omit the other and nothing said so.
/// **Declaration order is SEVERITY order, and it is load-bearing.** `allCases` is iterated to answer
/// "which role dies if the modifier monitors are missing", and the field holds one value, so the most
/// severe loss must come first: record kills dictation entirely, cancel kills the ability to abort one,
/// Quick Add is a limb. `roleOrderIsSeverityOrder` in `HotkeyQuickAddShortcutTests` pins it —
/// reordering these cases silently mislabels that telemetry rather than failing to compile.
package enum ShortcutRole: String, Sendable, CaseIterable {
  case record
  case cancel
  /// Quick Add (#2381): capture the selected word into the library.
  ///
  /// Unlike the other two this one is armed WHENEVER THE SERVICE IS, because it
  /// does not belong to a recording. That is why it sorts last in the matcher.
  case quickAdd

  /// The wire name this role uses in hotkey telemetry.
  ///
  /// `record` is `"toggle"` because that is the string production has been sending since #1175 and a
  /// rename would split every existing breakdown. A switch, so a fourth role cannot inherit a
  /// neighbour's name by omission.
  package var telemetryKind: String {
    switch self {
    case .record: "toggle"
    case .cancel: "cancel"
    case .quickAdd: "quick_add"
    }
  }
}

/// What each shortcut is bound to on a fresh install.
///
/// **One owner, because this value was previously written in three places that nothing linked.**
/// `SettingsDefaultValues` decides what a fresh install stores, `HotkeyService` carries a
/// compiled-in fallback, and each Settings row hard-codes what its Reset button offers. Any one of
/// them could move without the others, and the visible symptom is the worst kind: Reset takes the
/// user to a shortcut no fresh install has, so their "back to how it shipped" stops matching a
/// colleague's, every screenshot, and every support answer. Nothing fails, nothing is red.
///
/// A guard over those three literals was written first and then deleted in favour of this. A guard
/// fires after the mistake is made; one constant makes it unwriteable.
extension ShortcutRole {
  /// The shipped binding for this role. A switch, so a new role must declare one.
  package var defaultBinding: ShortcutBinding {
    switch self {
    // Right Option, a bare modifier: the record key is held or tapped constantly, so it earns the
    // one shape that needs no chord.
    case .record: .keyboard(keyCode: ModifierKeyCodes.rightOption, modifiers: [])
    // Escape, bare.
    case .cancel: .keyboard(keyCode: 53, modifiers: [])
    // Control-Option-W (#2381). A CHORD deliberately: it takes the Carbon path, and the persona
    // review's hard requirement is that a user who has never heard of this feature never triggers
    // it by accident. Still reachable with one hand.
    case .quickAdd: .keyboard(keyCode: 13, modifiers: [.control, .option])
    }
  }

  /// The shipped key code, for callers that store the two halves separately.
  package var defaultKeyCode: UInt16 {
    switch defaultBinding {
    case .keyboard(let keyCode, _): keyCode
    }
  }

  /// The shipped modifiers, for callers that store the two halves separately.
  package var defaultModifiers: NSEvent.ModifierFlags {
    switch defaultBinding {
    case .keyboard(_, let modifiers): modifiers
    }
  }
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
  /// `armed` is passed in rather than inferred because the roles are not
  /// symmetric: record and Quick Add are live whenever the service is running,
  /// while cancel is armed only for the duration of a recording. A matcher that
  /// assumed all were always live would cancel recordings that had not started.
  ///
  /// **Quick Add is checked LAST, and the order is a safety decision rather than
  /// an arbitrary one.** It is the only role armed at all times, so putting it
  /// ahead of cancel would shadow cancel for the entire duration of every
  /// recording — silently taking away the key that stops one. Behind cancel, a
  /// shared binding gives Quick Add every moment cancel is not armed, and costs
  /// the user nothing they had before.
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
    quickAdd: ShortcutBinding,
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
    if armed.contains(.quickAdd), quickAdd == .keyboard(keyCode: keyCode, modifiers: []) {
      // The SAME refusal as cancel's, for the same reason one step over. With the
      // record chord needing this modifier, a bare press of it is genuinely
      // ambiguous, and accepting it opens a panel that TAKES KEY FOCUS — so the
      // rest of the chord lands in the panel and the recording the user was
      // starting never happens. Cancel refuses because accepting destroys text
      // already spoken; this refuses because accepting prevents text being spoken
      // at all. Neither is recoverable by waiting.
      if let flag = ModifierKeyCodes.flag(for: keyCode),
        record.requiredModifiers.contains(flag)
      {
        return nil
      }
      return .quickAdd
    }
    return nil
  }
}
