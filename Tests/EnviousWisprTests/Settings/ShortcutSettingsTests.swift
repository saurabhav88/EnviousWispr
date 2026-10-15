import AppKit
import EnviousWisprServices
import Foundation
import Testing

@testable import EnviousWisprAppKit

/// #3765 PR-C: what a Keybinds row saves and refuses, which the dev control door now calls too.
///
/// When this fails, a Keybinds row saves a shortcut into another row's fields, saves half of a
/// refused shortcut, lets two rows share one key, or a shortcut written from outside the screen
/// uses up the one-time Globe key explanation the user never saw.
@MainActor
@Suite(.tags(.productOutcome))
struct ShortcutSettingsTests {
  private static func settings() -> SettingsManager {
    SettingsManager(defaults: TestDefaults.suite("ew.tests.3765.shortcut.\(UUID().uuidString)")!)
  }

  private func flagsChanged(_ keyCode: UInt16, _ flags: NSEvent.ModifierFlags) -> NSEvent {
    NSEvent.keyEvent(
      with: .flagsChanged, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
      context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false,
      keyCode: keyCode)!
  }

  private func keyDown(_ keyCode: UInt16, _ flags: NSEvent.ModifierFlags) -> NSEvent {
    NSEvent.keyEvent(
      with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
      context: nil, characters: "k", charactersIgnoringModifiers: "k", isARepeat: false,
      keyCode: keyCode)!
  }

  private func binding(_ event: NSEvent) -> ShortcutBinding {
    let captured = HotkeyCapture.binding(for: event)
    return .keyboard(keyCode: captured.keyCode, modifiers: captured.modifiers)
  }

  @Test("each row saves into its own two fields, recording into the toggle pair")
  func eachRoleWritesItsOwnPair() {
    let s = Self.settings()
    // F1 to F5 with Control-Option: no default and no Mac shortcut uses them.
    let codes: [ShortcutRole: UInt16] = [
      .record: 122, .cancel: 120, .quickAdd: 99, .pasteLast: 118, .copyLast: 96,
    ]
    for role in ShortcutRole.allCases {
      let code = codes[role]!
      #expect(
        ShortcutSettings.assign(
          .keyboard(keyCode: code, modifiers: [.control, .option]), to: role, in: s) == nil,
        "\(role)")
    }
    #expect(s.toggleKeyCode == 122 && s.toggleModifiers == [.control, .option])
    #expect(s.cancelKeyCode == 120 && s.cancelModifiers == [.control, .option])
    #expect(s.quickAddKeyCode == 99 && s.quickAddModifiers == [.control, .option])
    #expect(s.pasteLastKeyCode == 118 && s.pasteLastModifiers == [.control, .option])
    #expect(s.copyLastKeyCode == 96 && s.copyLastModifiers == [.control, .option])
    for role in ShortcutRole.allCases {
      #expect(
        s.shortcutBindings[role]
          == .keyboard(keyCode: codes[role]!, modifiers: [.control, .option]))
    }
  }

  @Test("an allowed shortcut saves the key code, then the modifiers")
  func writeOrder() {
    let s = Self.settings()
    var changed: [SettingsManager.SettingKey] = []
    s.onChange = { changed.append($0) }
    #expect(
      ShortcutSettings.assign(
        .keyboard(keyCode: 2, modifiers: [.command, .shift]), to: .copyLast, in: s)
        == nil)
    #expect(changed == [.copyLastKeyCode, .copyLastModifiers])
  }

  @Test("a standard Mac shortcut is refused for every row and saves nothing")
  func systemShortcutRefused() {
    for role in ShortcutRole.allCases {
      let s = Self.settings()
      let before = s.shortcutBindings
      var changes = 0
      s.onChange = { _ in changes += 1 }
      #expect(
        ShortcutSettings.assign(.keyboard(keyCode: 8, modifiers: [.command]), to: role, in: s)
          == .systemShortcut, "\(role)")
      #expect(changes == 0)
      #expect(s.shortcutBindings == before)
    }
  }

  @Test("another row's exact shortcut is refused, naming that row")
  func duplicateRefused() {
    let s = Self.settings()
    let pasteLast = s.shortcutBindings.pasteLast
    #expect(
      ShortcutSettings.refusal(assigning: pasteLast, to: .quickAdd, in: s) == .sameAs(.pasteLast))
    #expect(ShortcutSettings.assign(pasteLast, to: .quickAdd, in: s) == .sameAs(.pasteLast))
    #expect(s.quickAddKeyCode == ShortcutRole.quickAdd.defaultKeyCode)
    #expect(s.quickAddModifiers == ShortcutRole.quickAdd.defaultModifiers)
    #expect(
      ShortcutSettings.refusal(assigning: s.shortcutBindings.quickAdd, to: .quickAdd, in: s) == nil,
      "a row's own shortcut is not a clash with itself")
  }

  @Test("a clash with a more important row is refused; with a less important one it is allowed")
  func modifierConflictIsDirectional() {
    let s = Self.settings()
    // Recording is bare Right Option by default: Option-K under Add a word could never fire.
    #expect(
      ShortcutSettings.assign(.keyboard(keyCode: 40, modifiers: [.option]), to: .quickAdd, in: s)
        == .modifierConflict(.record))
    #expect(s.quickAddKeyCode == ShortcutRole.quickAdd.defaultKeyCode)
    // Recording on bare Right Control is allowed although Paste Last needs Control: higher wins.
    #expect(
      ShortcutSettings.assign(
        .keyboard(keyCode: ModifierKeyCodes.rightControl, modifiers: []), to: .record, in: s) == nil
    )
    #expect(s.toggleKeyCode == ModifierKeyCodes.rightControl && s.toggleModifiers == [])
  }

  @Test("a captured lone modifier saves no modifiers; a captured chord keeps only the four")
  func capturedEventsNormalize() {
    let s = Self.settings()
    let lone = binding(flagsChanged(ModifierKeyCodes.rightCommand, []))
    #expect(lone == .keyboard(keyCode: ModifierKeyCodes.rightCommand, modifiers: []))
    #expect(ShortcutSettings.assign(lone, to: .record, in: s) == nil)
    #expect(s.toggleKeyCode == ModifierKeyCodes.rightCommand && s.toggleModifiers == [])

    let chord = binding(keyDown(40, [.control, .shift, .capsLock, .function]))
    #expect(chord == .keyboard(keyCode: 40, modifiers: [.control, .shift]))
    #expect(ShortcutSettings.assign(chord, to: .quickAdd, in: s) == nil)
    #expect(s.quickAddKeyCode == 40 && s.quickAddModifiers == [.control, .shift])
  }

  @Test("saving Globe to recording leaves the one-time Globe explanation for the screen")
  func assignLeavesGlobeClaim() {
    let s = Self.settings()
    #expect(
      ShortcutSettings.assign(
        .keyboard(keyCode: ModifierKeyCodes.globe, modifiers: []), to: .record, in: s)
        == nil)
    #expect(s.toggleKeyCode == ModifierKeyCodes.globe)
    #expect(s.claimGlobeKeyGuidancePresentation(for: ModifierKeyCodes.globe), "still unclaimed")
    #expect(!s.claimGlobeKeyGuidancePresentation(for: ModifierKeyCodes.globe), "claimed once")
  }

  @Test("the fields read back what the row shows")
  func fieldsReadTheSavedPair() {
    let s = Self.settings()
    for role in ShortcutRole.allCases {
      #expect(
        ShortcutBinding.keyboard(
          keyCode: s[keyPath: ShortcutSettings.keyCodeField(for: role)],
          modifiers: s[keyPath: ShortcutSettings.modifiersField(for: role)])
          == s.shortcutBindings[role], "\(role)")
    }
  }

  @Test("the shared save asks first, then writes the key code and the modifiers, once each")
  func commitOrder() {
    var events: [String] = []
    let candidate = ShortcutBinding.keyboard(keyCode: 2, modifiers: [.command, .shift])
    let refused = ShortcutSettings.commit(
      candidate,
      validate: { events.append("validate \($0 == candidate)"); return .sameAs(.record) },
      writeKeyCode: { _ in events.append("keyCode") },
      writeModifiers: { _ in events.append("modifiers") })
    #expect(refused == .sameAs(.record))
    #expect(events == ["validate true"], "a refusal writes neither half")

    events = []
    let allowed = ShortcutSettings.commit(
      candidate,
      validate: { _ in events.append("validate"); return nil },
      writeKeyCode: { events.append("keyCode \($0)") },
      writeModifiers: { events.append("modifiers \($0 == [.command, .shift])") })
    #expect(allowed == nil)
    #expect(events == ["validate", "keyCode 2", "modifiers true"])
  }
}
