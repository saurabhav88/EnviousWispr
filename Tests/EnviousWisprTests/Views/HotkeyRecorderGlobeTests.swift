import AppKit
import EnviousWisprServices
import Foundation
import SwiftUI
import Testing

@testable import EnviousWisprAppKit

/// #1987 — the SECOND ingress path: assigning the Globe key in the shortcut recorder.
///
/// Dispatch and capture do not share code. `HotkeyService` decides what a press
/// DOES; `KeyCaptureNSView` decides what the recorder ACCEPTS while the user is
/// choosing a shortcut, and it has its own `flagsChanged` handler. Before #1987
/// each carried a private copy of the key-code-to-flag mapping, so a change to one
/// left the other refusing the key, and the feature would half-work in a way that
/// reads as a dispatch bug.
///
/// This suite exercises the capture half with the event shape measured on hardware
/// (probe, 2026-08-08). `@testable` is used deliberately here rather than widening
/// `KeyCaptureNSView`: it is an AppKit-local view with no cross-target consumer, so
/// the plan's access-control rule keeps it internal.
@MainActor
@Suite struct HotkeyRecorderGlobeTests {

  /// Builds the event the OS actually delivers for a standalone modifier: a
  /// `.flagsChanged` carrying the key code, with the flag present on press and
  /// absent on release.
  private func flagsChanged(keyCode: UInt16, flags: NSEvent.ModifierFlags) -> NSEvent {
    NSEvent.keyEvent(
      with: .flagsChanged,
      location: .zero,
      modifierFlags: flags,
      timestamp: 0,
      windowNumber: 0,
      context: nil,
      characters: "",
      charactersIgnoringModifiers: "",
      isARepeat: false,
      keyCode: keyCode
    )!
  }

  /// #2613 — the physically-held modifiers a test wants the view to believe in.
  /// A class, not a value, because the pre-held case has to CHANGE what is down
  /// after the view has already armed.
  private final class FlagsBox {
    var flags: NSEvent.ModifierFlags
    init(_ flags: NSEvent.ModifierFlags = []) { self.flags = flags }
  }

  /// #2613 — the whole event, not just its key code, because a chord's assertion is
  /// about its MODIFIERS and a key-code-only fixture cannot see them.
  private func keyCodes(_ events: [NSEvent]) -> [UInt16] { events.map(\.keyCode) }

  private func makeView(flags: FlagsBox = FlagsBox()) -> (KeyCaptureNSView, () -> [NSEvent]) {
    let view = KeyCaptureNSView()
    // #2613 — set BEFORE arming: arming is what reads the physically-held set, so
    // assigning it afterwards would test the empty-keyboard case whatever was asked
    // for. Defaulting to none also stops the suite reading the real keyboard, which
    // would go flaky whenever the person running it had a finger on Shift.
    view.modifierFlagsNow = { flags.flags }
    // The state under test. Every capture case below describes what happens WHILE
    // the user is recording a shortcut; `isRecording` defaults to false precisely
    // so that a view nobody armed captures nothing.
    view.isRecording = true
    var captured: [NSEvent] = []
    view.onKeyEvent = { captured.append($0) }
    return (view, { captured })
  }

  /// An un-armed view, for the gate cases below.
  private func makeIdleView() -> (KeyCaptureNSView, () -> [NSEvent]) {
    let view = KeyCaptureNSView()
    view.modifierFlagsNow = { [] }
    var captured: [NSEvent] = []
    view.onKeyEvent = { captured.append($0) }
    return (view, { captured })
  }

  /// `characters` is a parameter rather than a fixed "a" so an event that claims to
  /// be a particular shortcut actually IS one. Review caught the Command+W case
  /// below carrying W's key code with A's characters, which would have let the test
  /// keep passing against an implementation that read the characters instead.
  private func keyDown(
    keyCode: UInt16,
    flags: NSEvent.ModifierFlags = [],
    characters: String = "a"
  ) -> NSEvent {
    NSEvent.keyEvent(
      with: .keyDown,
      location: .zero,
      modifierFlags: flags,
      timestamp: 0,
      windowNumber: 0,
      context: nil,
      characters: characters,
      charactersIgnoringModifiers: characters,
      isARepeat: false,
      keyCode: keyCode
    )!
  }

  // MARK: - #1987 the capture view must be ARMED before it captures anything
  //
  // Founder-found, 2026-08-09, on the live build. Landing on the Shortcuts page and
  // pressing any key rebound the shortcut immediately: no click on the box, no
  // "press a key" prompt.
  //
  // The three handlers did not share one cause. `keyDown` and `flagsChanged` relied
  // on this hidden view lacking the opportunity to become first responder outside
  // recording, and #1987 removed that absence by making the enclosing control
  // `.focusable()`. `performKeyEquivalent` had no such protection at any point,
  // because AppKit can route a key equivalent through the view tree instead of to
  // the first responder.
  //
  // These are the two-way control: the cases above prove capture WORKS when armed,
  // these prove it does NOTHING when not. Without the second half, a gate that
  // refused everything would pass the first half completely.

  @Test("An un-armed view ignores a plain key press")
  func idleViewIgnoresKeyDown() {
    let (view, captured) = makeIdleView()
    view.keyDown(with: keyDown(keyCode: 0))
    #expect(captured().isEmpty)
  }

  @Test("An un-armed view ignores a bare modifier")
  func idleViewIgnoresModifier() {
    let (view, captured) = makeIdleView()
    view.flagsChanged(with: flagsChanged(keyCode: ModifierKeyCodes.globe, flags: [.function]))
    #expect(captured().isEmpty)
  }

  /// The worst arm, because AppKit can route a key equivalent through the view tree
  /// rather than to the first responder, so it fired even when this view held no
  /// focus. Returning true also claimed the shortcut, so an ordinary Command+W on
  /// the Shortcuts page both rebound the hotkey and failed to close the window.
  @Test("An un-armed view neither captures nor claims a key equivalent")
  func idleViewIgnoresKeyEquivalent() {
    let (view, captured) = makeIdleView()
    let handled = view.performKeyEquivalent(
      with: keyDown(keyCode: 13, flags: [.command], characters: "w"))
    #expect(captured().isEmpty)
    #expect(!handled, "an un-armed capture view must let the system handle the key equivalent")
  }

  /// The arming edge itself: capture must start and stop with the flag, so a view
  /// that was armed once does not keep capturing after recording ends.
  @Test("Capture follows the armed flag in both directions")
  func captureFollowsTheArmedFlag() {
    let (view, captured) = makeIdleView()

    view.keyDown(with: keyDown(keyCode: 0))
    #expect(captured().isEmpty)

    view.isRecording = true
    view.keyDown(with: keyDown(keyCode: 0))
    #expect(keyCodes(captured()) == [0])

    view.isRecording = false
    view.keyDown(with: keyDown(keyCode: 1))
    #expect(keyCodes(captured()) == [0], "capture continued after recording ended")
  }

  /// The one case that needs a real window, and the reason it is worth the cost:
  /// every other case here builds a detached view, whose `window` is nil, so the
  /// resignation branch is unreachable and deleting the whole `didSet` body leaves
  /// them all green. Review caught exactly that.
  ///
  /// What it protects: `acceptsFirstResponder` going false does NOT resign an
  /// existing first-responder status, so without the `didSet` a view that was armed
  /// once keeps receiving keys after recording ends, until something else happens to
  /// take focus. That is the founder's bug again, one step later in the sequence.
  @Test("Ending capture resigns the hidden capture view as first responder")
  func endingCaptureResignsFirstResponder() {
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
      styleMask: [.titled],
      backing: .buffered,
      defer: false
    )
    let view = KeyCaptureNSView(frame: window.contentView!.bounds)
    window.contentView = view

    view.isRecording = true
    #expect(view.acceptsFirstResponder)
    #expect(window.makeFirstResponder(view))
    #expect(window.firstResponder === view, "precondition: the armed view must hold focus")

    view.isRecording = false

    #expect(!view.acceptsFirstResponder)
    #expect(window.firstResponder !== view, "the view kept keyboard focus after recording ended")
  }

  /// #2613 INVERTED THIS TEST, and the inversion is the fix.
  ///
  /// It used to assert that a Globe PRESS commits. That is why no combination could
  /// ever be entered: a modifier press is a complete binding, so the Control of
  /// Control-Shift-W saved Control and stopped listening. A press now records the
  /// key and commits nothing; the case below commits it on the release.
  @Test("A bare modifier press commits nothing on its own")
  func aBareModifierPressCommitsNothing() {
    let (view, captured) = makeView()
    view.flagsChanged(with: flagsChanged(keyCode: ModifierKeyCodes.globe, flags: [.function]))
    #expect(
      captured().isEmpty,
      "committing on the press is what makes a combination impossible to enter")
  }

  /// #2613 INVERTED THIS TEST too. The release used to be dropped; it is now the
  /// commit point for a bare modifier, which is the only case where nothing earlier
  /// can tell whether the user meant that key alone.
  ///
  /// Globe specifically, because #1987 shipped it and the founder uses it: an
  /// earlier revision of #2613's design made bare Globe unsettable, and this pair
  /// is what would have caught that.
  @Test("The release of a lone modifier commits it")
  func theReleaseOfALoneModifierCommitsIt() {
    let (view, captured) = makeView()
    view.flagsChanged(with: flagsChanged(keyCode: ModifierKeyCodes.globe, flags: [.function]))
    view.flagsChanged(with: flagsChanged(keyCode: ModifierKeyCodes.globe, flags: []))
    #expect(keyCodes(captured()) == [ModifierKeyCodes.globe])
    #expect(HotkeyCapture.binding(for: captured()[0]).modifiers == [])
  }

  @Test("A full press then release assigns exactly once")
  func pressThenReleaseAssignsOnce() {
    let (view, captured) = makeView()
    view.flagsChanged(with: flagsChanged(keyCode: ModifierKeyCodes.globe, flags: [.function]))
    view.flagsChanged(with: flagsChanged(keyCode: ModifierKeyCodes.globe, flags: []))
    #expect(keyCodes(captured()) == [ModifierKeyCodes.globe])
  }

  @Test("Existing modifier keys are still accepted, so capture did not regress")
  func existingModifiersStillAccepted() {
    let (view, captured) = makeView()
    view.flagsChanged(with: flagsChanged(keyCode: ModifierKeyCodes.rightOption, flags: [.option]))
    view.flagsChanged(with: flagsChanged(keyCode: ModifierKeyCodes.rightOption, flags: []))
    #expect(keyCodes(captured()) == [ModifierKeyCodes.rightOption])
  }

  /// The measured trap on the capture side. Arrow keys carry `.function` in their
  /// flags, so a recorder that matched on the FLAG would assign itself to an arrow
  /// key the moment the user moved the cursor while recording.
  @Test(
    "An arrow key carrying .function is not accepted as a shortcut",
    arguments: [UInt16(123), 124, 125, 126])
  func arrowKeysNotAccepted(code: UInt16) {
    let (view, captured) = makeView()
    view.flagsChanged(with: flagsChanged(keyCode: code, flags: [.function]))
    #expect(captured().isEmpty)
  }

  // MARK: - #2613 a combination can be recorded at all
  //
  // The user report: "whatever I do it only detects the first key that is pressed,
  // attempting to press shift, option and control at the same time results in the
  // key being changed to left shift." One case per branch of the capture table, so
  // the table and this suite cannot drift apart.

  /// The reported bug, as a test. Goes red against the shipped code, which commits
  /// the Control press and never sees the W.
  @Test("Holding modifiers and pressing a letter records the whole combination")
  func aChordRecordsEveryHeldModifier() {
    let (view, captured) = makeView()
    view.flagsChanged(with: flagsChanged(keyCode: ModifierKeyCodes.leftControl, flags: [.control]))
    view.flagsChanged(
      with: flagsChanged(keyCode: ModifierKeyCodes.leftShift, flags: [.control, .shift]))
    view.keyDown(with: keyDown(keyCode: 13, flags: [.control, .shift], characters: "w"))

    #expect(keyCodes(captured()) == [13], "the letter is what completes a combination")
    let binding = HotkeyCapture.binding(for: captured()[0])
    #expect(binding.keyCode == 13)
    #expect(binding.modifiers == [.control, .shift])
  }

  /// A combination completes through the key-equivalent arm too. Both arms share one
  /// implementation precisely so they cannot answer differently, and this is the
  /// control that says so.
  @Test("A combination completes through performKeyEquivalent as well as keyDown")
  func aChordCompletesThroughKeyEquivalent() {
    let (view, captured) = makeView()
    view.flagsChanged(with: flagsChanged(keyCode: ModifierKeyCodes.leftCommand, flags: [.command]))
    let handled = view.performKeyEquivalent(
      with: keyDown(keyCode: 13, flags: [.command], characters: "w"))

    #expect(handled)
    #expect(keyCodes(captured()) == [13])
    #expect(HotkeyCapture.binding(for: captured()[0]).modifiers == [.command])
  }

  /// Two modifiers and no letter is not a shortcut, so nothing may commit — and the
  /// box must recover, because a user who fumbles should be able to let go and try
  /// again without reopening it.
  @Test("Two modifiers released with no letter commits nothing, and the box recovers")
  func twoModifiersWithNoLetterCommitNothingAndRecover() {
    let (view, captured) = makeView()
    view.flagsChanged(with: flagsChanged(keyCode: ModifierKeyCodes.leftControl, flags: [.control]))
    view.flagsChanged(
      with: flagsChanged(keyCode: ModifierKeyCodes.leftShift, flags: [.control, .shift]))
    view.flagsChanged(with: flagsChanged(keyCode: ModifierKeyCodes.leftShift, flags: [.control]))
    view.flagsChanged(with: flagsChanged(keyCode: ModifierKeyCodes.leftControl, flags: []))
    #expect(captured().isEmpty, "two modifiers alone are not a binding")

    view.flagsChanged(with: flagsChanged(keyCode: ModifierKeyCodes.rightOption, flags: [.option]))
    view.flagsChanged(with: flagsChanged(keyCode: ModifierKeyCodes.rightOption, flags: []))
    #expect(
      keyCodes(captured()) == [ModifierKeyCodes.rightOption],
      "the box did not recover after an abandoned attempt")
  }

  /// THE REFUTATION THAT KILLED AN EARLIER DESIGN, kept as a test.
  ///
  /// Left and right Shift are two key codes sharing one `.shift` flag. A design that
  /// decided press-versus-release by asking whether the flag was present classified
  /// the left release as a press, because the right key was still holding the flag
  /// up — so left Shift stayed "down" forever and no bare modifier could ever be set
  /// in that box again. Direction is read from the held set for this reason.
  @Test("Releasing one Shift while the other is held strands nothing")
  func releasingOnePairedModifierWhileItsSiblingIsHeldStrandsNothing() {
    let (view, captured) = makeView()
    view.flagsChanged(with: flagsChanged(keyCode: ModifierKeyCodes.leftShift, flags: [.shift]))
    view.flagsChanged(with: flagsChanged(keyCode: ModifierKeyCodes.rightShift, flags: [.shift]))
    // Left comes up while right still holds the aggregate flag up.
    view.flagsChanged(with: flagsChanged(keyCode: ModifierKeyCodes.leftShift, flags: [.shift]))
    view.flagsChanged(with: flagsChanged(keyCode: ModifierKeyCodes.rightShift, flags: []))
    #expect(captured().isEmpty)

    view.flagsChanged(with: flagsChanged(keyCode: ModifierKeyCodes.rightOption, flags: [.option]))
    view.flagsChanged(with: flagsChanged(keyCode: ModifierKeyCodes.rightOption, flags: []))
    #expect(
      keyCodes(captured()) == [ModifierKeyCodes.rightOption],
      "a stranded modifier is blocking every later bare-modifier binding")
  }

  /// A Globe combination cannot be registered, so it must be refused rather than
  /// stored: `.function` is not a Carbon modifier, so Globe+W would save, display
  /// and fire as plain W — making W a global hotkey.
  @Test("Globe held plus a letter commits nothing, and does not later save Globe")
  func globeHeldPlusALetterCommitsNothing() {
    let (view, captured) = makeView()
    view.flagsChanged(with: flagsChanged(keyCode: ModifierKeyCodes.globe, flags: [.function]))
    view.keyDown(with: keyDown(keyCode: 13, flags: [.function], characters: "w"))
    view.keyDown(with: keyDown(keyCode: 13, flags: [.function], characters: "w"))
    #expect(captured().isEmpty, "a Globe combination must be refused")

    view.flagsChanged(with: flagsChanged(keyCode: ModifierKeyCodes.globe, flags: []))
    #expect(captured().isEmpty, "the Globe release must not save a Globe nobody asked for")

    view.flagsChanged(with: flagsChanged(keyCode: ModifierKeyCodes.globe, flags: [.function]))
    view.flagsChanged(with: flagsChanged(keyCode: ModifierKeyCodes.globe, flags: []))
    #expect(
      keyCodes(captured()) == [ModifierKeyCodes.globe],
      "a fresh Globe press and release must still bind Globe")
  }

  /// The refusal keys off the Globe KEY being held, never off `.function` being
  /// present — arrow keys carry that flag. This is the two-way control for the
  /// Globe case above, and without it the refusal could be implemented as a flag
  /// test that silently makes every arrow key unsettable.
  @Test("An arrow key still completes, because the refusal is about the Globe key")
  func anArrowKeyStillCompletes() {
    let (view, captured) = makeView()
    view.keyDown(with: keyDown(keyCode: 126, flags: [.function], characters: ""))
    #expect(keyCodes(captured()) == [126])
  }

  /// Holding a key down long enough for macOS to repeat it must still produce one
  /// binding. The owners stop recording through a deferred task, so the view cannot
  /// rely on being disarmed in time.
  @Test("A repeated key press commits exactly once")
  func aRepeatedKeyPressCommitsExactlyOnce() {
    let (view, captured) = makeView()
    view.keyDown(with: keyDown(keyCode: 13, characters: "w"))
    view.keyDown(with: keyDown(keyCode: 13, characters: "w"))
    view.keyDown(with: keyDown(keyCode: 13, characters: "w"))
    #expect(keyCodes(captured()) == [13])
  }

  /// Caps Lock is ambient state, not part of the shortcut. It must not commit, must
  /// not spoil a combination, and must not reach the stored modifiers — where it
  /// would make a binding stop comparing equal to its own default.
  @Test("An ambient Caps Lock changes nothing about what commits")
  func ambientCapsLockChangesNothing() {
    let (view, captured) = makeView()
    view.flagsChanged(with: flagsChanged(keyCode: 57, flags: [.capsLock]))
    #expect(captured().isEmpty, "Caps Lock is not a shortcut")

    view.flagsChanged(
      with: flagsChanged(keyCode: ModifierKeyCodes.leftCommand, flags: [.capsLock, .command]))
    view.keyDown(with: keyDown(keyCode: 40, flags: [.capsLock, .command], characters: "k"))

    #expect(keyCodes(captured()) == [40])
    #expect(HotkeyCapture.binding(for: captured()[0]).modifiers == [.command])
  }

  /// A modifier ALREADY held when the box arms. Founder decision, 2026-09-03: wait
  /// for a neutral boundary.
  ///
  /// Without the wait the held key's RELEASE is read as a press, because the view
  /// starts with an empty held set, and the phantom never clears — so the next
  /// physical press is read as a release and commits on the way DOWN. If the
  /// phantom is Globe, every later key is refused and the box goes silently dead.
  @Test("A modifier held before arming does not corrupt the capture")
  func aModifierHeldBeforeArmingDoesNotCorruptTheCapture() {
    let flags = FlagsBox([.option])
    let (view, captured) = makeView(flags: flags)

    // The physical release of the key that was already down when the box armed.
    flags.flags = []
    view.flagsChanged(with: flagsChanged(keyCode: ModifierKeyCodes.rightOption, flags: []))
    #expect(captured().isEmpty, "a release we never saw go down is not a press")

    // A real press now, which must NOT be read as a release and commit early.
    view.flagsChanged(with: flagsChanged(keyCode: ModifierKeyCodes.rightOption, flags: [.option]))
    #expect(captured().isEmpty, "a bare modifier must not commit on the way down")

    view.flagsChanged(with: flagsChanged(keyCode: ModifierKeyCodes.rightOption, flags: []))
    #expect(keyCodes(captured()) == [ModifierKeyCodes.rightOption])
  }

  /// The Globe form of the same case, because it is the one whose failure is silent:
  /// a phantom Globe refuses every later key with no message.
  @Test("Globe held before arming does not leave the box refusing every key")
  func globeHeldBeforeArmingDoesNotDeadenTheBox() {
    let flags = FlagsBox([.function])
    let (view, captured) = makeView(flags: flags)

    flags.flags = []
    view.flagsChanged(with: flagsChanged(keyCode: ModifierKeyCodes.globe, flags: []))
    view.keyDown(with: keyDown(keyCode: 13, characters: "w"))
    #expect(keyCodes(captured()) == [13], "a phantom Globe is refusing ordinary keys")
  }

  /// Disarming clears every piece of capture state, so a reopened box starts clean
  /// rather than resuming a half-finished attempt from last time.
  @Test("Reopening the box starts a clean capture")
  func reopeningTheBoxStartsACleanCapture() {
    let (view, captured) = makeView()
    view.flagsChanged(with: flagsChanged(keyCode: ModifierKeyCodes.leftShift, flags: [.shift]))
    view.isRecording = false
    view.isRecording = true

    // If `held` had survived, this release would commit left Shift.
    view.flagsChanged(with: flagsChanged(keyCode: ModifierKeyCodes.leftShift, flags: []))
    #expect(captured().isEmpty, "capture state leaked across a reopen")

    view.keyDown(with: keyDown(keyCode: 13, characters: "w"))
    #expect(keyCodes(captured()) == [13])
  }

  /// A SwiftUI redraw re-assigns `isRecording` with the SAME value on every update
  /// pass. If that reset the capture, every unrelated redraw would silently discard
  /// a combination the user was halfway through entering.
  /// Review caught the FIRST version of this test being vacuous, and the reason is
  /// worth keeping: it asserted the committed chord carried `.control`, but
  /// `HotkeyCapture` reconstructs modifiers from the completing event's OWN flags,
  /// so the assertion passed whether or not the held set had been wiped. The
  /// expectation was built out of the mechanism under test.
  ///
  /// A held GLOBE is observable instead, because nothing can reconstruct it: if the
  /// state survives, the letter is refused; if it was wiped, the letter commits.
  @Test("An unchanged isRecording assignment does not discard a capture in progress")
  func anUnchangedAssignmentDoesNotDiscardACaptureInProgress() {
    let (view, captured) = makeView()
    view.flagsChanged(with: flagsChanged(keyCode: ModifierKeyCodes.globe, flags: [.function]))

    view.isRecording = true  // what `updateNSView` does on every pass
    view.keyDown(with: keyDown(keyCode: 13, flags: [.function], characters: "w"))
    view.flagsChanged(with: flagsChanged(keyCode: ModifierKeyCodes.globe, flags: []))

    #expect(captured().isEmpty, "the unchanged assignment erased the held Globe state")
  }

  /// The gap between arming and OWNING the keyboard, which the arming-time snapshot
  /// cannot see: `updateNSView` sets `isRecording` and then defers
  /// `makeFirstResponder` into a `Task`. A modifier pressed inside that gap is never
  /// seen going down, so its release would be read as a press and leave a phantom.
  ///
  /// Needs a real window, because first-responder status is what is under test.
  @Test("First-responder acquisition refreshes the neutral-boundary snapshot")
  func focusAcquisitionRefreshesNeutralBoundary() {
    let flags = FlagsBox()
    let view = KeyCaptureNSView()
    view.modifierFlagsNow = { flags.flags }
    view.isRecording = true

    // Globe goes down after arming and before focus is granted, so the view never
    // receives the press.
    flags.flags = [.function]
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
      styleMask: [.titled],
      backing: .buffered,
      defer: false
    )
    window.contentView = view
    #expect(window.makeFirstResponder(view))

    var captured: [NSEvent] = []
    view.onKeyEvent = { captured.append($0) }
    flags.flags = []
    view.flagsChanged(with: flagsChanged(keyCode: ModifierKeyCodes.globe, flags: []))
    view.keyDown(with: keyDown(keyCode: 13, characters: "w"))

    #expect(
      keyCodes(captured) == [13],
      "a phantom Globe from the arming gap is refusing ordinary keys")
  }

  /// The SECOND missed-transition gap, and the one `becomeFirstResponder` cannot
  /// see: the window keeps its stored first responder across losing key status, so
  /// coming back from another app fires no responder change at all — while key
  /// events went elsewhere the whole time.
  ///
  /// Without the fix this commits bare Shift on a key DOWN, which is the shape the
  /// whole change exists to remove.
  @Test("Returning from another app refreshes the snapshot, so a stale key cannot commit early")
  func returningToTheAppRefreshesTheSnapshot() {
    let flags = FlagsBox()
    let view = KeyCaptureNSView()
    view.modifierFlagsNow = { flags.flags }
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
      styleMask: [.titled],
      backing: .buffered,
      defer: false
    )
    window.contentView = view
    view.isRecording = true
    #expect(window.makeFirstResponder(view))

    var captured: [NSEvent] = []
    view.onKeyEvent = { captured.append($0) }

    // Shift goes down here, then the user leaves and releases it in the other app.
    flags.flags = [.shift]
    view.flagsChanged(with: flagsChanged(keyCode: ModifierKeyCodes.leftShift, flags: [.shift]))
    flags.flags = []

    // Back in the app. No responder change happens, only a key-window change.
    NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)

    // A real press, which must NOT be read as the release we missed.
    flags.flags = [.shift]
    view.flagsChanged(with: flagsChanged(keyCode: ModifierKeyCodes.leftShift, flags: [.shift]))
    #expect(captured.isEmpty, "a stale held key made a press commit as a release")

    flags.flags = []
    view.flagsChanged(with: flagsChanged(keyCode: ModifierKeyCodes.leftShift, flags: []))
    #expect(keyCodes(captured) == [ModifierKeyCodes.leftShift])
  }

  // MARK: - #1987 accepted-binding delivery
  //
  // These drive `HotkeyRecorderView.acceptBinding(from:)`, the REAL production
  // path, not the callback directly. An earlier version of this suite invoked
  // `onBindingAccepted` by hand and was correctly rejected: it passed with the
  // production invocation deleted. Deleting it now fails every test below.
  //
  // WHAT IS STILL NOT COVERED, stated rather than implied. `handleKeyEvent` reads
  // `dictationRuntime` from `@Environment` through `stopRecording()`, which traps
  // outside a rendered hierarchy, so ONE thing remains a manual-pass item: that
  // `handleKeyEvent` delegates to `acceptBinding` rather than dropping the event.
  // That is visible on the founder's manual pass — a Globe bind that silently did
  // nothing is not a subtle failure. `DictationRuntime.init` takes thirteen
  // collaborators, so faking one would be a large double bearing no relationship
  // to what is under test.

  /// A live binding pair backed by local storage, so the test observes what the
  /// view WRITES. `.constant` would discard the writes and make every assertion
  /// below vacuous.
  private final class BindingBox {
    var keyCode: UInt16 = ModifierKeyCodes.rightOption
    var modifiers: NSEvent.ModifierFlags = []
    /// The binding values as they stood at the moment the callback fired. Both
    /// surfaces depend on the write happening FIRST: the popover anchors on a
    /// control whose label must already read the new key.
    var seenAtCallback: [(UInt16, NSEvent.ModifierFlags)] = []
    var callbackArguments: [(UInt16, NSEvent.ModifierFlags)] = []
  }

  private func makeRecorder(_ box: BindingBox) -> HotkeyRecorderView {
    HotkeyRecorderView(
      keyCode: Binding(get: { box.keyCode }, set: { box.keyCode = $0 }),
      modifiers: Binding(get: { box.modifiers }, set: { box.modifiers = $0 }),
      defaultKeyCode: ModifierKeyCodes.rightOption,
      defaultModifiers: [],
      label: "Recording shortcut",
      onBindingAccepted: { code, mods in
        box.callbackArguments.append((code, mods))
        box.seenAtCallback.append((box.keyCode, box.modifiers))
      }
    )
  }

  @Test("Accepting Globe stores the key and notifies the owner exactly once")
  func acceptingGlobeNotifiesOwner() {
    let box = BindingBox()
    makeRecorder(box).acceptBinding(
      from: flagsChanged(keyCode: ModifierKeyCodes.globe, flags: [.function]))

    #expect(box.keyCode == ModifierKeyCodes.globe)
    #expect(box.modifiers == [])
    #expect(box.callbackArguments.count == 1)
    #expect(box.callbackArguments.first?.0 == ModifierKeyCodes.globe)
    #expect(box.callbackArguments.first?.1 == [])
  }

  /// The load-bearing ORDER. If the callback ran before the write, the guidance
  /// popover would anchor on a control still showing the old shortcut.
  @Test("The bindings are updated before the owner is notified")
  func bindingsAreWrittenBeforeTheCallback() {
    let box = BindingBox()
    makeRecorder(box).acceptBinding(
      from: flagsChanged(keyCode: ModifierKeyCodes.globe, flags: [.function]))

    #expect(box.seenAtCallback.count == 1)
    #expect(box.seenAtCallback.first?.0 == ModifierKeyCodes.globe)
  }

  /// A standalone modifier carries its own flag in `modifierFlags`. Storing that
  /// flag would demand the user hold Globe WHILE pressing Globe, so the key would
  /// never fire. Modifiers must come back empty.
  @Test(
    "A modifier-only key clears its own flag",
    arguments: [
      (ModifierKeyCodes.globe, NSEvent.ModifierFlags.function),
      (ModifierKeyCodes.rightOption, NSEvent.ModifierFlags.option),
      (ModifierKeyCodes.leftCommand, NSEvent.ModifierFlags.command),
    ])
  func modifierOnlyKeyClearsItsOwnFlag(code: UInt16, flag: NSEvent.ModifierFlags) {
    let box = BindingBox()
    makeRecorder(box).acceptBinding(from: flagsChanged(keyCode: code, flags: flag))

    #expect(box.keyCode == code)
    #expect(box.modifiers == [])
    #expect(box.callbackArguments.first?.1 == [])
  }

  /// The other side of the same branch: an ordinary chord must KEEP its modifiers,
  /// so the clearing above cannot be implemented by clearing unconditionally.
  @Test("A chord keeps its modifiers")
  func chordKeepsItsModifiers() {
    let box = BindingBox()
    let event = NSEvent.keyEvent(
      with: .keyDown,
      location: .zero,
      modifierFlags: [.command, .shift],
      timestamp: 0,
      windowNumber: 0,
      context: nil,
      characters: "d",
      charactersIgnoringModifiers: "d",
      isARepeat: false,
      keyCode: 2
    )!
    makeRecorder(box).acceptBinding(from: event)

    #expect(box.keyCode == 2)
    #expect(box.modifiers == [.command, .shift])
    #expect(box.callbackArguments.count == 1)
    #expect(box.callbackArguments.first?.1 == [.command, .shift])
  }

  /// An arrow key arrives as a `keyDown` carrying `.function`, and it must not be
  /// mistaken for the Globe key.
  ///
  /// #2613 CHANGED WHAT THIS STORES. The old assertion kept `.function`, on the
  /// reasoning that acceptance must not strip a legitimate chord component. That
  /// reasoning was wrong about the consumers: `KeySymbols.symbolsForModifiers`
  /// never renders `.function` and `HotkeyService.carbonModifiers` never registers
  /// it, so keeping it stored a bit that could not be seen or fired. The key code
  /// still identifies the arrow, which is what this test is really about.
  @Test("An arrow key is stored as a chord, not as the Globe key")
  func arrowKeyIsNotTreatedAsGlobe() {
    let box = BindingBox()
    let event = NSEvent.keyEvent(
      with: .keyDown,
      location: .zero,
      modifierFlags: [.function],
      timestamp: 0,
      windowNumber: 0,
      context: nil,
      characters: "",
      charactersIgnoringModifiers: "",
      isARepeat: false,
      keyCode: 126
    )!
    makeRecorder(box).acceptBinding(from: event)

    #expect(box.keyCode == 126)
    #expect(box.modifiers == [], "#2613: a bit neither display nor Carbon keeps must not be stored")
  }

  // MARK: - #1987 shared acceptance authority
  //
  // `HotkeyCapture` is what BOTH recording surfaces read. Settings goes through
  // `HotkeyRecorderView` and onboarding through `KeycapHotkeyView`, and each
  // previously carried its own copy of this logic, so the same press could bind
  // differently depending on where the user set it.
  //
  // These cover the shared AUTHORITY, not onboarding's delegation to it. That
  // distinction matters: `KeycapHotkeyView` is file-private and `@testable` does
  // not promote private to internal, so nothing here would fail if onboarding
  // stopped calling `HotkeyCapture` and grew a private copy again. What prevents
  // the drift is that neither view retains its own copy to drift from; what proves
  // onboarding still delegates is the founder's manual pass.

  /// Escape cancels rather than binding. Without this a user pressing Escape to
  /// back out would silently bind Escape as their dictation shortcut.
  @Test("Escape alone cancels")
  func escapeAloneCancels() {
    let event = NSEvent.keyEvent(
      with: .keyDown,
      location: .zero,
      modifierFlags: [],
      timestamp: 0,
      windowNumber: 0,
      context: nil,
      characters: "\u{1B}",
      charactersIgnoringModifiers: "\u{1B}",
      isARepeat: false,
      keyCode: 53
    )!
    #expect(HotkeyCapture.isCancel(event))
  }

  /// The two ways cancel must NOT fire, so it cannot be implemented as a bare
  /// key-code check. Escape WITH a modifier is a legitimate chord a user may want,
  /// and key code 53 arriving as a modifier change is not an Escape press at all.
  @Test("Escape with a modifier is a binding, not a cancel")
  func escapeWithModifierIsNotCancel() {
    let event = NSEvent.keyEvent(
      with: .keyDown,
      location: .zero,
      modifierFlags: [.command],
      timestamp: 0,
      windowNumber: 0,
      context: nil,
      characters: "\u{1B}",
      charactersIgnoringModifiers: "\u{1B}",
      isARepeat: false,
      keyCode: 53
    )!
    #expect(!HotkeyCapture.isCancel(event))
    #expect(HotkeyCapture.binding(for: event) == (53, [.command]))
  }

  @Test("A modifier change is never a cancel")
  func modifierChangeIsNeverCancel() {
    #expect(
      !HotkeyCapture.isCancel(
        flagsChanged(keyCode: ModifierKeyCodes.globe, flags: [.function])))
    #expect(!HotkeyCapture.isCancel(flagsChanged(keyCode: 53, flags: [])))
  }

  /// The property both surfaces now share by construction. Before #1987 this was
  /// two copies, so this test would have proven nothing about onboarding.
  @Test(
    "Every modifier-only key binds with empty modifiers",
    arguments: [
      ModifierKeyCodes.globe, ModifierKeyCodes.rightOption, ModifierKeyCodes.leftOption,
      ModifierKeyCodes.leftCommand, ModifierKeyCodes.rightCommand, ModifierKeyCodes.leftShift,
      ModifierKeyCodes.rightShift, ModifierKeyCodes.leftControl, ModifierKeyCodes.rightControl,
    ])
  func everyModifierOnlyKeyBindsEmpty(code: UInt16) {
    let flag = ModifierKeyCodes.flag(for: code)!
    let result = HotkeyCapture.binding(for: flagsChanged(keyCode: code, flags: flag))
    #expect(result.keyCode == code)
    #expect(result.modifiers == [])
  }
}
