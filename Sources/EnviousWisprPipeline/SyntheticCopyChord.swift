import AppKit
import Carbon.HIToolbox
import CoreGraphics
import EnviousWisprCore

/// Posts one Command+C at a named process, and derives which key that actually is (#2465).
///
/// **Live mechanics only, no decisions.** Every question of whether a copy SHOULD be attempted is
/// answered by `SelectionAcquisition` before anything here runs. This file is the half that cannot
/// be unit-tested — it talks to the window server — so it is kept small enough to read, and Live UAT
/// is its proof, the same split `SelectionReader` and `PasteService` already keep.
///
/// **The one thing to know before editing: the chord is BRACKETED by explicit `flagsChanged`
/// events, and dropping that brackets nothing and breaks the whole machine.** Setting
/// `kCGEventFlagMaskCommand` on the key events alone leaves Command latched DOWN system-wide —
/// measured during this issue's proof of concept in both `kCGEventSourceStateHIDSystemState` and
/// `CombinedSessionState`, on the founder's own machine, where every click afterwards became a
/// Command-click until a clearing event was posted. Nothing in a normal test run notices, because
/// the damage is to a global the test does not read.
enum SyntheticCopyChord {

  /// The result of one attempt, as three states rather than a Bool.
  ///
  /// **`clearFailed` is a success that could not tidy up after itself, and it is deliberately not a
  /// failure.** By the time the clearing event can fail, the copy has already been posted and the
  /// word may already be on the board — refusing there would throw away a capture in order to report
  /// a machine state the user cannot act on differently. The caller logs it loudly and keeps the
  /// text. (`modifierReleaseFailed` was proposed as a refusal during review and rejected for exactly
  /// this reason.)
  enum PostResult: Equatable {
    /// Posted, and Command was cleared afterwards.
    ///
    /// **`posted` means WE POSTED, never that the app received or acted on it.** `CGEvent.postToPid`
    /// returns nothing and there is no delivery receipt, so this value is a statement about our own
    /// side of the boundary. It is safe only because the caller does not treat it as the outcome:
    /// `SelectionAcquisition` goes on to judge by the ARTIFACT, polling the pasteboard's change
    /// count, and reports `copyRefused` when the board never moves however cleanly this returned.
    ///
    /// Stated because the opposite is the ordinary mistake — judging an outcome by whether the call
    /// terminated rather than by whether the thing happened — and a case named `posted` reads like
    /// success at every call site that has not read this.
    case posted
    /// Posted, and the clearing event could not be created or sent.
    case clearFailed
    /// Nothing was posted: the event source or the key events could not be created.
    case notPosted
  }

  /// Post Command+C at one process.
  ///
  /// - Parameter pid: the process to aim at. **Never re-derived here** — it comes from the sample
  ///   the Accessibility read used, so the chord cannot land on whatever came forward since.
  /// - Parameter copyKeyCode: the virtual key that means "c" on the ACTIVE layout. See
  ///   `copyKeyCode()`; passing a constant is the defect that resolver exists to prevent.
  ///
  /// **Aimed at the pid rather than the session tap.** Measured 2026-08-26: a backgrounded
  /// application answers a pid-targeted chord, which is what lets the menu-bar door use this at all
  /// (by click time the frontmost application is us). A session-tap post would go to whoever is in
  /// front, which after a menu click is the wrong process.
  @MainActor
  static func post(at pid: pid_t, copyKeyCode: CGKeyCode) -> PostResult {
    // `.hidSystemState` rather than `.combinedSessionState`: the flags we are about to set and clear
    // are read back from the HID state by the caller's modifier check, and setting one state while
    // reading the other is how a clear looks like it never happened.
    guard let source = CGEventSource(stateID: .hidSystemState) else { return .notPosted }

    // **EVERY event is built before ANY of them is posted, including the RELEASE.**
    //
    // An earlier version built the two key events up front and then called a helper that CREATED
    // the release event after Command was already down. If that creation failed — memory pressure,
    // resource exhaustion — Command stayed latched system-wide and the function returned
    // `clearFailed` having posted no release at all. The comment above it claimed "everything that
    // can fail happens BEFORE Command goes down", which was the whole point and was not true of
    // the line it was written above.
    //
    // The knowledge file this session wrote about the latch says exactly this: build everything
    // that can fail BEFORE pressing the modifier. Writing that sentence did not stop the defect one
    // file away. Found by the confirming review round; owner
    // `~/.claude/knowledge/dev/gotchas.md`, "Posting a synthetic modifier chord LATCHES".
    //
    // So after this guard there is no construction left and no early return: four posts, none of
    // which can fail, and the release is unconditional by CONSTRUCTION rather than by a `defer` a
    // later edit could step around.
    guard
      let commandDown = flagsEvent(.maskCommand, source: source),
      let commandUp = flagsEvent([], source: source),
      let keyDown = CGEvent(keyboardEventSource: source, virtualKey: copyKeyCode, keyDown: true),
      let keyUp = CGEvent(keyboardEventSource: source, virtualKey: copyKeyCode, keyDown: false)
    else { return .notPosted }

    commandDown.postToPid(pid)
    keyDown.flags = .maskCommand
    keyDown.postToPid(pid)
    keyUp.flags = .maskCommand
    keyUp.postToPid(pid)
    commandUp.postToPid(pid)

    // **`clearFailed` is now unreachable from this function and the case stays**, because the state
    // it names is still real: a release we posted can be lost by the window server, and a future
    // path that cannot prebuild its release would need it. Deleting a case to make a switch shorter
    // is how a state stops being handled rather than stops existing.
    return .posted
  }

  /// One `flagsChanged` event carrying exactly `flags`.
  ///
  /// **A `flagsChanged` event, not a key event with flags set.** The modifier state the window
  /// server tracks is changed by this event type and by nothing else, so a key event that merely
  /// CARRIES `.maskCommand` tells the target app about the chord while leaving the machine's idea of
  /// the Command key untouched on the way in and stuck on the way out.
  ///
  /// The virtual key is the physical Command key, because a `flagsChanged` event names the key whose
  /// state changed. It is a layout-independent modifier position and not affected by the resolver
  /// below, which is about the character key.
  ///
  /// **BUILDS, never posts.** The split is the fix for the latch described in `post`: a helper that
  /// created and posted in one step made it impossible to construct the release before pressing.
  @MainActor
  private static func flagsEvent(
    _ flags: CGEventFlags,
    source: CGEventSource
  ) -> CGEvent? {
    guard
      let event = CGEvent(
        keyboardEventSource: source, virtualKey: CGKeyCode(kVK_Command), keyDown: !flags.isEmpty)
    else { return nil }
    event.type = .flagsChanged
    event.flags = flags
    return event
  }

  /// Which virtual key means "c" on the keyboard layout that is active RIGHT NOW.
  ///
  /// **Never `kVK_ANSI_C`, and the reason is that a wrong answer here is INVISIBLE.** Virtual key 8
  /// is a physical POSITION on an ANSI board; under Dvorak and several non-US layouts that position
  /// is a different letter. Posting it would press the wrong key, the app would decline to copy, and
  /// the run would report `copyRefused` — which is indistinguishable from an app that genuinely did
  /// not answer. A silent wrong result wearing a known failure's clothes, and the only thing that
  /// catches a regression is the alternate-layout Live UAT case.
  ///
  /// **The ASCII-capable layout, not the current input source.** With a Japanese or Chinese input
  /// method active there is no Latin layout to translate against, and macOS itself resolves keyboard
  /// shortcuts through the ASCII-capable layout — so that is the one that answers the question
  /// "which key does this user press for copy".
  ///
  /// Returns nil rather than a guess when the layout cannot be read; the caller decides what to do
  /// with that, and what it does is documented at the call site rather than hidden here.
  static func copyKeyCode() -> CGKeyCode? {
    guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
      let rawLayout = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
    else { return nil }

    let layoutData = Unmanaged<CFData>.fromOpaque(rawLayout).takeUnretainedValue() as Data
    let keyboardType = UInt32(LMGetKbdType())

    // **Resolved under the COMMAND layer, because that is the layer the key will be pressed in.**
    //
    // A layout can map the same physical key to different characters with and without Command, and
    // at least one shipped layout does exactly that on purpose: "Dvorak - QWERTY ⌘" types Dvorak and
    // switches to QWERTY while Command is held, so that Command shortcuts stay where muscle memory
    // left them. Resolving with modifier state 0 finds the key that types an unmodified "c" — the
    // Dvorak position — and `post` then sends that key WITH `.maskCommand`, where the Command layer
    // makes it a different letter entirely. Two different questions, and the wrong one was asked.
    //
    // The failure is invisible: it presents as `copyRefused`, indistinguishable from an app that
    // declined. Found by cloud review on PR #2472, and it is the exact case this function's own doc
    // named as the one most likely to escape.
    //
    // `UCKeyTranslate` wants the modifier flags shifted right by 8, so Command (`cmdKey`, 0x0100)
    // is state 1. Measured on this machine's US layout: both states answer 8, which is what makes
    // this change safe everywhere the two layers agree.
    let commandState = UInt32((cmdKey >> 8) & 0xFF)

    // A REVERSE lookup, because the layout maps key to character and the question is the other way
    // round. 128 translations of one keystroke each, run once per invocation of a user gesture.
    //
    // The unmodified layer is a FALLBACK rather than the answer: a layout whose Command layer
    // produces no plain "c" at all is one we cannot resolve correctly, and a best guess there beats
    // refusing the feature outright — it is the behaviour every layout had before this fix.
    for modifierState in [commandState, UInt32(0)] {
      for candidate in 0..<CGKeyCode(128) {
        guard
          let produced = character(
            forKeyCode: candidate, layoutData: layoutData, keyboardType: keyboardType,
            modifierState: modifierState)
        else { continue }
        if produced == "c" { return candidate }
      }
    }
    return nil
  }

  /// The unmodified character one virtual key produces under a given layout.
  ///
  /// `modifierState` is the `UCKeyTranslate` form — the Carbon modifier flags shifted RIGHT by 8 —
  /// not `CGEventFlags`. Passing the wrong one silently answers about a different layer.
  private static func character(
    forKeyCode keyCode: CGKeyCode,
    layoutData: Data,
    keyboardType: UInt32,
    modifierState: UInt32
  ) -> Character? {
    var deadKeyState: UInt32 = 0
    var length = 0
    var characters = [UniChar](repeating: 0, count: 4)

    let status = layoutData.withUnsafeBytes { raw -> OSStatus in
      guard let base = raw.baseAddress else { return OSStatus(paramErr) }
      let layout = base.assumingMemoryBound(to: UCKeyboardLayout.self)
      return UCKeyTranslate(
        layout,
        keyCode,
        UInt16(kUCKeyActionDown),
        modifierState,
        keyboardType,
        OptionBits(kUCKeyTranslateNoDeadKeysBit),
        &deadKeyState,
        characters.count,
        &length,
        &characters)
    }

    guard status == noErr, length == 1, let scalar = UnicodeScalar(characters[0]) else {
      return nil
    }
    return Character(scalar)
  }
}
