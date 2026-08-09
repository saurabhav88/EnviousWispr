import AppKit
import EnviousWisprServices
import Foundation
import Testing

/// #1987 — the standalone-modifier key set and its projections.
///
/// The mapping used to live in three places: a hand-written membership set plus
/// two private key-code-to-flag switches, one on the dispatch path and one on the
/// capture view. Adding a key meant remembering all three, and forgetting the flag
/// half was silent: the lookup returned `[]` for an unknown code, and
/// `OptionSet.contains` is a superset test, so
/// `anything.contains([])` is `true`. A member without a flag therefore read as
/// PRESSED on its release event, and push-to-talk would start recording and never
/// stop.
///
/// Membership is now DERIVED from the mapping and the flag lookup returns an
/// optional, so that state is unrepresentable rather than merely guarded. The
/// completeness test below is characterization: it documents the invariant, it is
/// no longer the thing protecting it.
@Suite struct KeySymbolsTests {

  /// The eight keys that shipped before the Globe key, with the flag each has
  /// always set. Written out longhand rather than derived from the type under
  /// test: a test that asks the implementation what it believes and then asserts
  /// the answer matches proves only that the code equals itself.
  private static let preExistingMappings: [(code: UInt16, flag: NSEvent.ModifierFlags)] = [
    (55, .command), (54, .command),
    (58, .option), (61, .option),
    (56, .shift), (60, .shift),
    (59, .control), (62, .control),
  ]

  @Test("The eight pre-existing keys map exactly as they did before consolidation")
  func existingMappingsUnchanged() {
    for (code, expected) in Self.preExistingMappings {
      #expect(ModifierKeyCodes.isModifierOnly(code), "key code \(code) lost membership")
      #expect(
        ModifierKeyCodes.flag(for: code) == expected,
        "key code \(code) changed flag under consolidation")
    }
  }

  @Test("The Globe key is a member and maps to .function")
  func globeIsMapped() {
    #expect(ModifierKeyCodes.globe == 63)
    #expect(ModifierKeyCodes.isModifierOnly(ModifierKeyCodes.globe))
    #expect(ModifierKeyCodes.flag(for: ModifierKeyCodes.globe) == .function)
  }

  @Test("Membership is exactly nine keys, so nothing was added or lost")
  func membershipCount() {
    #expect(ModifierKeyCodes.all.count == 9)
    #expect(ModifierKeyCodes.all.contains(ModifierKeyCodes.globe))
  }

  @Test("Characterization: every member has a non-nil flag, by construction")
  func everyMemberHasAFlag() {
    for code in ModifierKeyCodes.all {
      #expect(
        ModifierKeyCodes.flag(for: code) != nil,
        "member \(code) has no flag; press and release would be indistinguishable")
    }
  }

  /// The measured trap. Arrow keys really do carry `.function` in their event
  /// flags (probe, 2026-08-08: `keyCode=123 raw=0xa00100 numericPad+FUNCTION`),
  /// so an implementation that matched on the FLAG rather than the KEY CODE would
  /// start dictation every time the user moved the cursor.
  @Test(
    "Arrow keys are not standalone modifiers even though their events carry .function",
    arguments: [UInt16(123), 124, 125, 126])
  func arrowKeysRejected(code: UInt16) {
    #expect(!ModifierKeyCodes.isModifierOnly(code))
    #expect(ModifierKeyCodes.flag(for: code) == nil)
  }

  @Test(
    "F-row keys are not standalone modifiers",
    arguments: [UInt16(122), 120, 99, 118, 96, 97])
  func fRowKeysRejected(code: UInt16) {
    #expect(!ModifierKeyCodes.isModifierOnly(code))
    #expect(ModifierKeyCodes.flag(for: code) == nil)
  }

  @Test("An ordinary letter key is not a standalone modifier")
  func letterKeyRejected() {
    #expect(!ModifierKeyCodes.isModifierOnly(0))  // 'A'
    #expect(ModifierKeyCodes.flag(for: 0) == nil)
  }

  // MARK: - Projections

  @Test("The Globe key displays with both names and no Left/Right qualifier")
  func globeVisibleLabel() {
    let label = KeySymbols.formatModifierOnly([], keyCode: ModifierKeyCodes.globe)
    #expect(label == "🌐 Globe (Fn)")
    #expect(!label.contains("Left"))
    #expect(!label.contains("Right"))
  }

  @Test("Existing keys keep their side-qualified visible labels")
  func existingVisibleLabelsUnchanged() {
    #expect(KeySymbols.formatModifierOnly([], keyCode: 61) == "Right ⌥")
    #expect(KeySymbols.formatModifierOnly([], keyCode: 58) == "Left ⌥")
    #expect(KeySymbols.formatModifierOnly([], keyCode: 55) == "Left ⌘")
  }

  /// The spoken value must not depend on a screen reader interpreting an emoji.
  @Test("The Globe key speaks as words, not as its visible emoji label")
  func globeSpokenLabel() {
    let spoken = KeySymbols.accessibilityDescription(
      keyCode: ModifierKeyCodes.globe, modifiers: [])
    #expect(spoken == "Globe or Function key")
    #expect(!spoken.contains("🌐"))
  }

  @Test("Every other key speaks exactly as it renders, so nothing else changed")
  func otherKeysSpeakAsRendered() {
    for (code, _) in Self.preExistingMappings {
      let spoken = KeySymbols.accessibilityDescription(keyCode: code, modifiers: [])
      let visible = KeySymbols.format(keyCode: code, modifiers: [])
      #expect(spoken == visible, "key code \(code) diverged between spoken and visible")
    }
  }
}
