import AppKit
import EnviousWisprServices
import SwiftUI
import Testing

@testable import EnviousWisprAppKit

/// A refused shortcut is never saved, not even half of it (#3106).
///
/// When one of these fails, a Keybinds row saves a shortcut that clashes with Record or with a
/// standard Mac shortcut, and it starts registering before anything can object; or a refused
/// capture saves the new key with the old modifiers, a shortcut the user never pressed.
@MainActor
@Suite("Keybinds recorder: refuse before saving (#3106)", .tags(.productOutcome))
struct HotkeyRecorderValidationTests {

  private final class Box {
    var keyCode: UInt16 = ShortcutRole.pasteLast.defaultKeyCode
    var modifiers: NSEvent.ModifierFlags = ShortcutRole.pasteLast.defaultModifiers
    var writes = 0
    var accepted = 0
    var validated: [ShortcutBinding] = []
  }

  private func recorder(_ box: Box, refusing refusal: ShortcutRefusal?) -> HotkeyRecorderView {
    HotkeyRecorderView(
      keyCode: Binding(
        get: { box.keyCode },
        set: {
          box.keyCode = $0
          box.writes += 1
        }),
      modifiers: Binding(
        get: { box.modifiers },
        set: {
          box.modifiers = $0
          box.writes += 1
        }),
      defaultKeyCode: ShortcutRole.pasteLast.defaultKeyCode,
      defaultModifiers: ShortcutRole.pasteLast.defaultModifiers,
      label: "Paste last dictation keybind",
      onBindingAccepted: { _, _ in box.accepted += 1 },
      validate: { proposed in
        box.validated.append(proposed)
        return refusal
      })
  }

  private func keyDown(_ keyCode: UInt16, _ flags: NSEvent.ModifierFlags) -> NSEvent {
    NSEvent.keyEvent(
      with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
      context: nil, characters: "v", charactersIgnoringModifiers: "v", isARepeat: false,
      keyCode: keyCode)!
  }

  @Test("A refused capture writes neither half and notifies no one")
  func refusedCaptureSavesNothing() {
    let box = Box()
    let refusal = recorder(box, refusing: .systemShortcut).acceptBinding(
      from: keyDown(9, [.command]))
    #expect(refusal == .systemShortcut)
    #expect(box.writes == 0)
    #expect(box.accepted == 0)
    #expect(box.keyCode == 9 && box.modifiers == [.control, .command], "unchanged")
    #expect(box.validated == [.keyboard(keyCode: 9, modifiers: [.command])], "asked once, first")
  }

  @Test("An allowed capture saves both halves and notifies once")
  func allowedCaptureSaves() {
    let box = Box()
    let refusal = recorder(box, refusing: nil).acceptBinding(
      from: keyDown(2, [.command, .shift]))
    #expect(refusal == nil)
    #expect(box.keyCode == 2 && box.modifiers == [.command, .shift])
    #expect(box.accepted == 1)
  }

  @Test("Reset is checked too: a refused default leaves both halves as they were")
  func refusedResetSavesNothing() {
    let box = Box()
    box.keyCode = 2
    box.modifiers = [.command, .shift]
    let refusal = recorder(box, refusing: .sameAs(.quickAdd)).applyDefault()
    #expect(refusal == .sameAs(.quickAdd))
    #expect(box.writes == 0)
    #expect(box.keyCode == 2 && box.modifiers == [.command, .shift])

    #expect(recorder(box, refusing: nil).applyDefault() == nil)
    #expect(box.keyCode == 9 && box.modifiers == [.control, .command])
  }

  @Test("Every refusal has a sentence that names the other shortcut")
  func refusalMessages() {
    #expect(HotkeyRecorderView.message(for: .systemShortcut).contains("standard Mac shortcut"))
    for role in ShortcutRole.allCases {
      let title = HotkeyRecorderView.title(of: role)
      #expect(HotkeyRecorderView.message(for: .sameAs(role)).contains(title))
      #expect(HotkeyRecorderView.message(for: .modifierConflict(role)).contains(title))
    }
  }
}
