import AppKit

/// Which action a shortcut triggers.
///
/// A closed set, deliberately: the #1991 defect was possible because "record"
/// and "cancel" were never named as members of one thing, so a dispatch path
/// could handle one and silently omit the other and nothing said so.
/// **Declaration order is SEVERITY order, and it is load-bearing.** `allCases` is iterated to answer
/// "which role dies if the modifier monitors are missing", and the field holds one value, so the most
/// severe loss must come first: record kills dictation entirely, cancel kills the ability to abort one,
/// Quick Add, Paste Last and Copy Last are limbs. `roleOrderIsSeverityOrder` in
/// `HotkeyQuickAddShortcutTests` pins it —
/// reordering these cases silently mislabels that telemetry rather than failing to compile.
package enum ShortcutRole: String, Sendable, CaseIterable {
  case record
  case cancel
  /// Quick Add (#2381): capture the selected word into the library.
  ///
  /// Unlike cancel this one is armed WHENEVER THE SERVICE IS (as record is), because it
  /// does not belong to a recording. That is why it sorts after cancel in the matcher
  /// (last of the original three; #3106 added two more always-armed roles below it).
  case quickAdd
  /// Paste Last Dictation (#3106): paste the newest delivered dictation at the cursor again.
  /// Armed whenever the service is, like Quick Add, and below it: a limb that reuses text never
  /// outranks one that captures it.
  case pasteLast
  /// Copy Last Dictation (#3106): put the newest delivered dictation on the clipboard. Least
  /// severe: losing it costs one convenience, and Paste Last covers the same need.
  case copyLast

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
    case .pasteLast: "paste_last"
    case .copyLast: "copy_last"
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
    // Control-Shift-W. A CHORD deliberately: it takes the Carbon path, and the persona review's
    // hard requirement is that a user who has never heard of this feature never triggers it by
    // accident. Still reachable with one hand.
    //
    // **SHIFT, not the Option this shipped with in #2381, because Option is RECORD'S OWN KEY.**
    // Record above is bare Right Option, so the two shipped defaults collided out of the box: the
    // Option half of Control-Option-W is dispatched by the modifier monitor before the W ever
    // reaches Carbon (`HotkeyService.handleFlagsChangedValues`), so on the right-hand Option key a
    // user following our own hint started a push-to-talk recording instead of opening the panel.
    // `quickAddOwnsItsBinding` saw the collision and correctly refused to advertise the chord, so
    // every fresh install read "Currently unavailable" on the Quick Add tab (founder report,
    // 2026-09-02).
    //
    // **And not plain Control-W, which is free in Cocoa text fields and taken everywhere else.**
    // Two measurements, taken 2026-09-02 on the dev machine, and one thing that is merely widely
    // documented, kept apart on purpose:
    //   - MEASURED: zsh binds Control-W to `backward-kill-word` (`bindkey | grep '\^W'`).
    //   - MEASURED: AppKit's own StandardKeyBinding.dict carries no `^W` entry at all, which is why
    //     the chord looks free from inside a Cocoa text field.
    //   - NOT VERIFIED HERE, documented elsewhere: readline, vim and emacs each bind it too.
    // A global hotkey outranks the focused app, so binding Control-W would take word-delete away
    // from every terminal on the Mac. Adding Shift clears both measured cases.
    case .quickAdd: .keyboard(keyCode: 13, modifiers: [.control, .shift])
    // Control-Command-V and Control-Command-C: Wispr Flow's own defaults for the same two actions,
    // shipped ON (founder decision, #3106). Chords, so they take the Carbon path and a user who
    // never heard of the feature does not trip it. Accepted cost, known when chosen: while
    // EnviousWispr holds them they override Terminal's "Paste Escaped Text" / "Paste Ruler"
    // (Control-Command-V) and Apple's formatting-copy and Final Cut Pro's Color Board
    // (Control-Command-C). Both are rebindable in Keybinds.
    case .pasteLast: .keyboard(keyCode: 9, modifiers: [.control, .command])
    case .copyLast: .keyboard(keyCode: 8, modifiers: [.control, .command])
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

/// Every role's current binding, as one value (#3106).
///
/// The matcher's questions all have the same shape — "does a HIGHER role own this?" — and with
/// five roles, passing each binding as its own argument is how one call site comes to omit one.
/// A switch-backed subscript, so a new role must be given a stored binding here.
package struct ShortcutBindings: Equatable, Sendable {
  package var record: ShortcutBinding
  package var cancel: ShortcutBinding
  package var quickAdd: ShortcutBinding
  package var pasteLast: ShortcutBinding
  package var copyLast: ShortcutBinding

  package init(
    record: ShortcutBinding, cancel: ShortcutBinding, quickAdd: ShortcutBinding,
    pasteLast: ShortcutBinding, copyLast: ShortcutBinding
  ) {
    self.record = record
    self.cancel = cancel
    self.quickAdd = quickAdd
    self.pasteLast = pasteLast
    self.copyLast = copyLast
  }

  /// What a fresh install has, read from `ShortcutRole.defaultBinding`.
  package static let shipped = ShortcutBindings(
    record: ShortcutRole.record.defaultBinding, cancel: ShortcutRole.cancel.defaultBinding,
    quickAdd: ShortcutRole.quickAdd.defaultBinding,
    pasteLast: ShortcutRole.pasteLast.defaultBinding,
    copyLast: ShortcutRole.copyLast.defaultBinding)

  package subscript(role: ShortcutRole) -> ShortcutBinding {
    switch role {
    case .record: record
    case .cancel: cancel
    case .quickAdd: quickAdd
    case .pasteLast: pasteLast
    case .copyLast: copyLast
    }
  }
}

/// The single authority for what an input means.
///
/// Pure and `nonisolated` by construction: no state, no timers, no side effects.
/// That is what makes it testable without a live event stream, and it is a
/// requirement rather than a nicety for #1996, where the mouse tap callback must
/// reach a verdict synchronously on its own thread.
///
/// **One rule for every role pair, asked in severity order (#3106).** `ShortcutRole`'s declaration
/// order is the priority: a higher role always wins a binding two roles contend for, and the lower
/// one yields. Three questions, one owner each below: which role a bare-modifier press belongs to
/// (`role(forBareModifierKeyCode:bindings:armed:)`), whether a role's binding is a standing promise
/// worth advertising (`ownsItsBinding(_:in:)`), and whether a role may hold its Carbon chord right
/// now (`mayHoldCarbonChord(_:in:armed:)`).
///
/// **Two kinds of collision, and they compare different things.** A CARBON collision is two chords
/// Carbon would register as one: compared on `carbonEffectiveModifiers`, because Carbon drops
/// Function, Caps Lock and the rest. A PREFIX collision is a bare modifier and a chord that needs
/// that modifier held: compared on EVERY flag a modifier key maps to, Globe's `.function` included,
/// because the modifier monitor sees the Globe press before the chord's key arrives whatever Carbon
/// later keeps. So a chord recorded with Fn and one without are one chord to Carbon, while a bare
/// Globe binding still intercepts the Fn one.
package enum ShortcutMatcher {

  /// The modifiers Carbon actually registers, mirroring `HotkeyService.carbonModifiers`.
  ///
  /// Every other bit — Caps Lock, Function, Numeric Pad, and the device-dependent flags — is
  /// dropped on the way to `RegisterEventHotKey`, so two bindings differing only there are ONE
  /// chord as far as the system is concerned. Comparing anything else answers a question nobody
  /// asked.
  package static let carbonEffectiveModifiers: NSEvent.ModifierFlags = [
    .command, .option, .control, .shift,
  ]

  /// Every flag a standalone modifier key can carry: the PREFIX question's scope (see the type doc).
  private static let prefixModifiers: NSEvent.ModifierFlags = .deviceIndependentFlagsMask

  /// The roles that outrank `role`, most severe first.
  private static func roles(above role: ShortcutRole) -> ArraySlice<ShortcutRole> {
    ShortcutRole.allCases.prefix { $0 != role }
  }

  /// Whether `role` would answer its own binding, asked of the code that dispatches it.
  ///
  /// **Both arms assume the service is running and cancel may be armed at any moment**, which is the
  /// honest question for a menu label: a hint is a standing promise, not a claim about this instant,
  /// so a chord that stops working the moment a recording starts must not be advertised.
  ///
  /// Only HIGHER roles can take a binding from `role`, so a lower role's binding never changes the
  /// answer.
  package static func ownsItsBinding(_ role: ShortcutRole, in bindings: ShortcutBindings) -> Bool {
    let binding = bindings[role]
    if case .keyboard(let keyCode, _) = binding, binding.isBareModifier {
      // `armed` carries cancel too: a label promising a key that cancel takes over for the whole of
      // every recording is worse than no label.
      return self.role(
        forBareModifierKeyCode: keyCode, bindings: bindings, armed: Set(ShortcutRole.allCases))
        == role
    }
    // **A CHORD IS NOT DISPATCHED ONLY BY CARBON, WHICH IS WHERE THE PREVIOUS VERSION OF THIS WAS
    // WRONG.** Pressing Command-W emits the Command press FIRST, and the modifier monitor routes
    // every bare modifier press through `role(forBareModifierKeyCode:)` before the W ever reaches
    // Carbon (`HotkeyService.installModifierMonitors`, and the dispatch at its
    // `ShortcutMatcher.role` call). So a chord whose modifier is a higher-priority role's BARE
    // binding is intercepted: Record on bare Command and Quick Add on Command-W means the user
    // starts a recording while following this hint.
    //
    // That is the exact mirror of the refusal `role` already makes in the other direction — it
    // rejects a bare Quick Add modifier the record CHORD needs. Both directions now exist.
    //
    // **The closure claim, stated so it can be falsified rather than hoped for:** a press reaches
    // exactly two mechanisms, the modifier monitor and Carbon, and a chord press produces two kinds
    // of event, one press per required modifier and then its key. Both are checked below: every
    // required modifier against every higher bare binding, and the key through Carbon equivalence.
    // A further finding would have to name a THIRD dispatch mechanism, not another combination of
    // these two.
    //
    // #3106: Globe's `.function` is now in scope here as it is on the dispatch side. The previous
    // loop walked only `[.command, .option, .control, .shift]`, so a bare-Globe Record over an
    // Fn-chord Quick Add was advertised although the Globe press starts a recording first.
    //
    // And the Carbon half: whether another role registers the same chord — key code plus the
    // modifiers Carbon actually keeps. Record registers first and cancel takes the chord for the
    // whole of every recording, so either one owning it means this label is a promise we cannot
    // keep.
    //
    // **The registration ruling (`HotkeyService.mayHoldItsChord`) is deliberately NOT called
    // here.** Its `isEnabled`/`isSuspended` arguments are runtime state a menu label does not have,
    // so calling it means inventing values to get an answer. History worth keeping: that ruling,
    // then `quickAddMayHoldItsChord`, once compared bindings with raw `==` — the very defect three
    // review rounds found in this label — and Quick Add was not unregistered for a cancel chord
    // differing only in a dropped modifier. Fixed in #2432 by asking `carbonEquivalent` below; since
    // #3106 both this label and `mayHoldCarbonChord` compare that way, so there is one spelling of
    // the question rather than two.
    for higher in roles(above: role) {
      let other = bindings[higher]
      if bareModifier(other, isPrefixOf: binding, within: prefixModifiers) { return false }
      if carbonEquivalent(binding, other) { return false }
    }
    return true
  }

  /// The more severe role that has taken `role`'s binding, or nil when `role` keeps it (#3106).
  ///
  /// The same two collisions `ownsItsBinding` asks about, answered with WHO, so a Keybinds row can
  /// say which shortcut took its keys. `ownsItsBinding(role)` is true exactly when this is nil;
  /// `ShortcutArbitrationTests` sweeps that equivalence.
  package static func displacingRole(of role: ShortcutRole, in bindings: ShortcutBindings)
    -> ShortcutRole?
  {
    let binding = bindings[role]
    for higher in roles(above: role) {
      let other = bindings[higher]
      if carbonEquivalent(binding, other)
        || bareModifier(other, isPrefixOf: binding, within: prefixModifiers)
        || bareModifier(binding, isPrefixOf: other, within: prefixModifiers)
      {
        return higher
      }
    }
    return nil
  }

  /// Whether `role` may hold its Carbon registration now, given which roles are armed.
  ///
  /// **A shared chord is a policy question, and the event-tap path already answered it while the
  /// Carbon path had no answer at all.** `role(forBareModifierKeyCode:...)` gives the binding to the
  /// most severe armed role; this is the same ruling for the other dispatch mechanism: a higher
  /// armed role outranks a lower one on a chord they share, for as long as it is armed. Cancel is
  /// armed only during a recording, so a lower role relinquishes a Cancel chord then and regains it
  /// when Cancel disarms.
  ///
  /// #3106: Record now counts too. `RegisterEventHotKey` refuses a duplicate, and Record registers
  /// first, so a lower role on Record's chord was registered, refused and reported as a failure,
  /// and could never fire. It now yields quietly.
  ///
  /// #3106: the PREFIX direction counts as well. A lower chord whose modifier is a higher armed
  /// role's bare binding is intercepted on the way in: the modifier press fires the higher role,
  /// then the key completes the chord in Carbon, so one press did two things. The lower chord gives
  /// up its registration instead. Accepted cost, deliberately: that chord no longer works when
  /// pressed with the OTHER side's modifier key either (bare Right Option does not match a Left
  /// Option press), because a registration that works on one side and double-fires on the other is
  /// not one the user can rely on. `ownsItsBinding` withholds its hint for the same binding.
  ///
  /// A bare binding holds no Carbon registration at all: the modifier monitors observe it.
  package static func mayHoldCarbonChord(
    _ role: ShortcutRole, in bindings: ShortcutBindings, armed: Set<ShortcutRole>
  ) -> Bool {
    let binding = bindings[role]
    guard binding.isCarbonRegistrable else { return false }
    // **CARBON-equivalent, not `==` (#2432).** `RegisterEventHotKey` never sees Caps Lock,
    // Function or Numeric Pad, so two bindings differing only there are ONE chord to the
    // system while raw equality calls them different. This function decides whether Quick Add
    // KEEPS its registration, so the wrong answer left both roles claiming one chord: Quick
    // Add registers at start and holds it, cancel arrives second during a recording and is
    // refused, and the user's cancel key opens the Quick Add panel while the recording runs.
    // That is the same failure `cancelWinsASharedChord` already covers, reachable through a
    // modifier Carbon discards.
    for higher in roles(above: role) where armed.contains(higher) {
      let other = bindings[higher]
      if carbonEquivalent(binding, other) { return false }
      if bareModifier(other, isPrefixOf: binding, within: prefixModifiers) { return false }
    }
    return true
  }

  /// Do these two bindings reach Carbon as ONE chord?
  ///
  /// Same key code, and the same modifiers AFTER dropping everything
  /// `RegisterEventHotKey` never sees. Two bindings differing only in Caps Lock, Function or
  /// Numeric Pad are one chord to the system, so `==` on the raw values answers a question
  /// nobody asked — and answers it wrongly in the direction that lets two roles both claim
  /// the same registration.
  ///
  /// **One owner, because there were two.** This comparison was written inline here and
  /// asked again with raw `==` in `HotkeyService.quickAddMayHoldItsChord`, where the second
  /// spelling was a live defect on the dispatch path (#2432). Two spellings of one question
  /// is how the record and cancel paths drifted apart in the first place.
  package static func carbonEquivalent(_ one: ShortcutBinding, _ other: ShortcutBinding) -> Bool {
    guard case .keyboard(let oneKey, let oneModifiers) = one,
      case .keyboard(let otherKey, let otherModifiers) = other
    else { return false }
    return oneKey == otherKey
      && oneModifiers.intersection(carbonEffectiveModifiers)
        == otherModifiers.intersection(carbonEffectiveModifiers)
  }

  /// Is `bare` a standalone modifier whose flag `chord` needs held, among `flags`?
  ///
  /// The PREFIX collision, asked from either side: pressing a chord emits its modifiers first, and
  /// the modifier monitor dispatches that press before the chord's key reaches Carbon. So a bare
  /// binding on one of a chord's modifiers and that chord cannot both work. One spelling for both
  /// directions — the dispatch refusal in `role(forBareModifierKeyCode:)` and the standing label
  /// check in `ownsItsBinding` asked it separately, in two different shapes.
  package static func bareModifier(
    _ bare: ShortcutBinding, isPrefixOf chord: ShortcutBinding, within flags: NSEvent.ModifierFlags
  ) -> Bool {
    guard bare.isBareModifier, case .keyboard(let keyCode, _) = bare,
      let flag = ModifierKeyCodes.flag(for: keyCode), flags.contains(flag)
    else { return false }
    return chord.requiredModifiers.contains(flag)
  }

  /// Which armed role a bare-modifier key press belongs to, if any.
  ///
  /// `armed` is passed in rather than inferred because the roles are not
  /// symmetric: record and Quick Add are live whenever the service is running,
  /// while cancel is armed only for the duration of a recording. A matcher that
  /// assumed all were always live would cancel recordings that had not started.
  ///
  /// **The always-armed roles are checked AFTER cancel, and the order is a safety decision rather
  /// than an arbitrary one.** Quick Add, Paste Last and Copy Last are armed at all times, so
  /// putting any of them ahead of cancel would shadow cancel for the entire duration of every
  /// recording — silently taking away the key that stops one. Behind cancel, a shared binding gives
  /// them every moment cancel is not armed, and costs the user nothing they had before. (Written
  /// for Quick Add in #2381, when it was the only always-armed role and sorted last; #3106 added the
  /// two below it.)
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
  ///
  /// **The first armed role bound to this key decides, and a refusal does not fall through.** A
  /// refused press returns nil rather than offering the key to the next role down, exactly as the
  /// three explicit arms this loop replaced did.
  package static func role(
    forBareModifierKeyCode keyCode: UInt16,
    bindings: ShortcutBindings,
    armed: Set<ShortcutRole>
  ) -> ShortcutRole? {
    let bare = ShortcutBinding.keyboard(keyCode: keyCode, modifiers: [])
    guard
      let matched = ShortcutRole.allCases.first(where: {
        armed.contains($0) && bindings[$0] == bare
      })
    else { return nil }
    // REFUSE when this modifier is also the first half of a HIGHER armed role's chord.
    //
    // Record is never refused: nothing outranks it.
    //
    // Cancel's refusal (#1991). Cancel on bare Right Command with record on Command+D: pressing
    // Command to STOP the recording arrives here first, as a bare Command press that matches the
    // cancel binding exactly, and the recording is discarded before D is ever pressed. The user
    // loses everything they just said while trying to stop — and it is deterministic, not a race.
    //
    // Pre-fix dispatch compared against the record key alone and returned early, so this is a
    // regression THIS change introduced, and it lands hardest on precisely the users it was written
    // for.
    //
    // Refusing is the correct direction, not a compromise: while the record chord needs this
    // modifier, a bare press of it is genuinely ambiguous — nothing here can distinguish "cancel"
    // from "starting the record chord", and no amount of waiting makes it unambiguous without
    // inventing a timeout that would itself be wrong. Accepting wrongly destroys dictation the user
    // authored; refusing wrongly costs a shortcut that could never have worked reliably in that
    // configuration.
    //
    // Quick Add's refusal (#2381): the SAME refusal as cancel's, for the same reason one step over.
    // With the record chord needing this modifier, a bare press of it is genuinely ambiguous, and
    // accepting it opens a panel that TAKES KEY FOCUS — so the rest of the chord lands in the panel
    // and the recording the user was starting never happens. Cancel refuses because accepting
    // destroys text already spoken; this refuses because accepting prevents text being spoken at
    // all. Neither is recoverable by waiting.
    //
    // #3106: every higher ARMED role counts, not only Record. An armed Cancel chord needing this
    // modifier made a bare Quick Add fire on the way to cancelling, opening a panel that takes key
    // focus mid-cancel; Paste Last and Copy Last yield the same way to every role above them.
    for higher in roles(above: matched) where armed.contains(higher) {
      if bareModifier(bare, isPrefixOf: bindings[higher], within: prefixModifiers) { return nil }
    }
    return matched
  }
}

/// Why a shortcut the user just recorded cannot be saved (#3106).
package enum ShortcutRefusal: Equatable, Sendable {
  /// A standard macOS shortcut every app uses (Copy, Paste, Quit, ...). Taking it globally would
  /// break it in every app, and Paste Last on Command-V would re-trigger itself from its own paste.
  case systemShortcut
  /// Another shortcut already uses this exact key combination, as Carbon sees it.
  case sameAs(ShortcutRole)
  /// A bare modifier key and a chord that needs that modifier held: whichever is pressed, the other
  /// one fires first or as well.
  case modifierConflict(ShortcutRole)
}

extension ShortcutMatcher {

  /// Standard macOS shortcuts a recorded binding may not take: the Edit menu's (Undo, Redo, Cut,
  /// Copy, Paste, Select All) and the app-level ones every Mac app answers (Quit, Close, Hide,
  /// Minimize, app switching, Spotlight, window cycling). A CLOSED set, taken from macOS's own
  /// menus rather than from our users' data, so it is not a prediction about anyone's habits.
  /// Compared Carbon-style, so a Caps Lock riding on the capture does not slip past it.
  package static let reservedSystemChords: [ShortcutBinding] = [
    .keyboard(keyCode: 6, modifiers: [.command]),  // Z  Undo
    .keyboard(keyCode: 6, modifiers: [.command, .shift]),  // Z  Redo
    .keyboard(keyCode: 7, modifiers: [.command]),  // X  Cut
    .keyboard(keyCode: 8, modifiers: [.command]),  // C  Copy
    .keyboard(keyCode: 9, modifiers: [.command]),  // V  Paste
    .keyboard(keyCode: 0, modifiers: [.command]),  // A  Select All
    .keyboard(keyCode: 12, modifiers: [.command]),  // Q  Quit
    .keyboard(keyCode: 13, modifiers: [.command]),  // W  Close
    .keyboard(keyCode: 4, modifiers: [.command]),  // H  Hide
    .keyboard(keyCode: 46, modifiers: [.command]),  // M  Minimize
    .keyboard(keyCode: 48, modifiers: [.command]),  // Tab  App switcher
    .keyboard(keyCode: 49, modifiers: [.command]),  // Space  Spotlight
    .keyboard(keyCode: 50, modifiers: [.command]),  // `  Cycle windows
  ]

  /// Whether `proposed` may be saved as `role`'s binding. Nil means it may.
  ///
  /// Refuses, founder-approved 2026-09-22:
  /// - a standard macOS shortcut, for every role (as Wispr Flow does);
  /// - an EXACT duplicate of any other role's binding, in both directions ("already in use", as
  ///   Wispr Flow does): two rows on one chord is never what the user meant;
  /// - a PREFIX collision (a bare modifier and a chord needing it, either direction) with a MORE
  ///   severe role: that binding could never work, and capture is where it can be explained.
  ///
  /// **A prefix collision with a LESS severe role is allowed, deliberately** ("higher wins", from a
  /// web-grounded council the founder requested). Arbitration gives the key to the higher role, the
  /// lower one yields, and its own Keybinds row says so. Refusing instead would let a convenience
  /// shortcut veto the heart's: with Paste Last on its shipped Control-Command-V, a user could not
  /// move Record to bare Right Command or Right Control until they had first found and moved Paste
  /// Last.
  package static func refusal(
    assigning proposed: ShortcutBinding, to role: ShortcutRole, in bindings: ShortcutBindings
  ) -> ShortcutRefusal? {
    if reservedSystemChords.contains(where: { carbonEquivalent($0, proposed) }) {
      return .systemShortcut
    }
    for other in ShortcutRole.allCases where other != role {
      if carbonEquivalent(proposed, bindings[other]) { return .sameAs(other) }
    }
    for other in roles(above: role) {
      let existing = bindings[other]
      if bareModifier(proposed, isPrefixOf: existing, within: prefixModifiers)
        || bareModifier(existing, isPrefixOf: proposed, within: prefixModifiers)
      {
        return .modifierConflict(other)
      }
    }
    return nil
  }
}
