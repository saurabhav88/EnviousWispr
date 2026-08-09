import AppKit
import EnviousWisprServices
import Foundation
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
}
