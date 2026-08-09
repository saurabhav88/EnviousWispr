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

  private func makeView() -> (KeyCaptureNSView, () -> [UInt16]) {
    let view = KeyCaptureNSView()
    var captured: [UInt16] = []
    view.onKeyEvent = { captured.append($0.keyCode) }
    return (view, { captured })
  }

  @Test("The recorder accepts a Globe press")
  func acceptsGlobePress() {
    let (view, captured) = makeView()
    view.flagsChanged(with: flagsChanged(keyCode: ModifierKeyCodes.globe, flags: [.function]))
    #expect(captured() == [ModifierKeyCodes.globe])
  }

  /// Without this the recorder would bind on the release too, so a single tap
  /// would register as two assignments.
  @Test("The recorder ignores the Globe release")
  func ignoresGlobeRelease() {
    let (view, captured) = makeView()
    view.flagsChanged(with: flagsChanged(keyCode: ModifierKeyCodes.globe, flags: []))
    #expect(captured().isEmpty)
  }

  @Test("A full press then release assigns exactly once")
  func pressThenReleaseAssignsOnce() {
    let (view, captured) = makeView()
    view.flagsChanged(with: flagsChanged(keyCode: ModifierKeyCodes.globe, flags: [.function]))
    view.flagsChanged(with: flagsChanged(keyCode: ModifierKeyCodes.globe, flags: []))
    #expect(captured() == [ModifierKeyCodes.globe])
  }

  @Test("Existing modifier keys are still accepted, so capture did not regress")
  func existingModifiersStillAccepted() {
    let (view, captured) = makeView()
    view.flagsChanged(with: flagsChanged(keyCode: ModifierKeyCodes.rightOption, flags: [.option]))
    #expect(captured() == [ModifierKeyCodes.rightOption])
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

  /// An arrow key arrives as a `keyDown` carrying `.function`. It is a legitimate
  /// chord component, so unlike the capture layer above, acceptance must NOT strip
  /// it — but it must also not be mistaken for the Globe key.
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
    #expect(box.modifiers == [.function])
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
