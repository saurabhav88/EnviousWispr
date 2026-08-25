import AppKit
import Foundation
import Testing

@testable import EnviousWisprServices

/// #2381 — every keybind row's Reset offers the value a fresh install actually gets.
///
/// When this fails the user presses Reset on a shortcut row and lands on a chord that is NOT the
/// default, so their "back to how it shipped" stops matching a colleague's fresh install, every
/// screenshot, and every support answer. It compiles, it looks right, and nothing goes red.
///
/// **The first version of this suite was a guard over three hard-coded literals in the view.** It
/// worked, and it was the wrong shape: a guard fires after the mistake is made, and it left three
/// unlinked copies of one value in place. `ShortcutRole.defaultBinding` now owns the value and the
/// view, the service and `SettingsDefaultValues` all read it, so the drift is unwriteable rather
/// than detected. What survives here is what a constant cannot do for itself: pin the VALUES so
/// changing one is a conscious act, and keep a literal from creeping back into a row.
///
/// Swept over all THREE rows, not just the new one — an entity sweep finds wrong statements, a
/// member sweep finds omissions, and the new row is the one its author is certain to have checked.
@Suite("Keybind defaults have one owner (#2381)", .tags(.driftGuard))
struct KeybindRowDefaultsTests {

  // MARK: - The values themselves

  @Test("The shipped shortcut for each role is the founder-ratified one")
  func shippedShortcutsAreTheRatifiedOnes() {
    #expect(
      ShortcutRole.record.defaultBinding
        == .keyboard(keyCode: ModifierKeyCodes.rightOption, modifiers: []))
    #expect(ShortcutRole.cancel.defaultBinding == .keyboard(keyCode: 53, modifiers: []))
    #expect(
      ShortcutRole.quickAdd.defaultBinding
        == .keyboard(keyCode: 13, modifiers: [.control, .option]))
  }

  @Test("Quick Add ships as a CHORD, which is what keeps it out of an unsuspecting user's way")
  func quickAddShipsAsAChord() {
    // Not a property of the number: a bare modifier would take the NSEvent path AND be reachable by
    // anyone who rests a finger on it. The persona review's hard requirement is that someone who
    // has never heard of this feature never triggers it.
    #expect(ShortcutRole.quickAdd.defaultBinding.isBareModifier == false)
    #expect(ShortcutRole.quickAdd.defaultBinding.isCarbonRegistrable)
    // The paired case: record ships as a bare modifier, so this is not a check that passes for
    // every role.
    #expect(ShortcutRole.record.defaultBinding.isBareModifier)
  }

  // MARK: - Everyone reads the owner

  @Test("What a fresh install stores is what the owner says, for all three roles")
  func storedDefaultsMatchTheOwner() {
    // True by construction now. Pinned because "by construction" is a property of today's code, and
    // a future edit that re-inlines a number here would be silent.
    #expect(SettingsDefaultValues.toggleKeyCode == Int(ShortcutRole.record.defaultKeyCode))
    #expect(SettingsDefaultValues.toggleModifiersRaw == ShortcutRole.record.defaultModifiers.rawValue)
    #expect(SettingsDefaultValues.cancelKeyCode == Int(ShortcutRole.cancel.defaultKeyCode))
    #expect(SettingsDefaultValues.cancelModifiersRaw == ShortcutRole.cancel.defaultModifiers.rawValue)
    #expect(SettingsDefaultValues.quickAddKeyCode == Int(ShortcutRole.quickAdd.defaultKeyCode))
    #expect(
      SettingsDefaultValues.quickAddModifiersRaw == ShortcutRole.quickAdd.defaultModifiers.rawValue)
  }

  // `@MainActor` on this case alone rather than the suite: `SettingsManager` is main-actor isolated
  // and the source-reading cases below are not, so hoisting it would isolate tests that do not need
  // it.
  @MainActor
  @Test("A fresh install's live settings are the shipped shortcuts")
  func aFreshInstallGetsTheShippedShortcuts() {
    // The end-to-end version of the above, through the object the app actually reads. Ephemeral
    // suite so nothing touches the host process.
    let name = "ew.keybindDefaultsTest." + UUID().uuidString
    let suite = UserDefaults(suiteName: name)!
    suite.removePersistentDomain(forName: name)
    let settings = SettingsManager(defaults: suite)

    #expect(settings.toggleKeyCode == ShortcutRole.record.defaultKeyCode)
    #expect(settings.cancelKeyCode == ShortcutRole.cancel.defaultKeyCode)
    #expect(settings.quickAddKeyCode == ShortcutRole.quickAdd.defaultKeyCode)
    #expect(settings.quickAddModifiers == ShortcutRole.quickAdd.defaultModifiers)
  }

  // MARK: - No literal creeps back into a row

  /// Each row's own source block, keyed by its accessibility label.
  ///
  /// Scoped per ROW rather than searched whole-file: a whole-file `contains` passes when a token
  /// moves to the WRONG row, which is the defect a location-insensitive guard is least able to see
  /// and the one that puts the wrong Reset on the wrong shortcut.
  private static func rowBlock(labelled label: String) throws -> String {
    let url = RepoRoot.sourceURL(
      "Sources/EnviousWisprAppKit/Views/Settings/KeybindsSettingsView.swift")
    let source = try String(contentsOf: url, encoding: .utf8)
    let blocks = source.components(separatedBy: "ProminentHotkeyRow(").dropFirst()
    guard let block = blocks.first(where: { $0.contains("accessibilityLabel: \"\(label)\"") }) else {
      Issue.record(Comment(rawValue: "no ProminentHotkeyRow labelled '\(label)'"))
      return ""
    }
    return block
  }

  @Test(
    "Every row reads its role's default rather than repeating the number",
    arguments: [
      ("Recording keybind", "record"),
      ("Cancel keybind", "cancel"),
      ("Add-a-word keybind", "quickAdd"),
    ])
  func everyRowReadsTheOwner(label: String, role: String) throws {
    let block = try Self.rowBlock(labelled: label)

    #expect(block.contains("defaultKeyCode: ShortcutRole.\(role).defaultKeyCode"))
    #expect(block.contains("defaultModifiers: ShortcutRole.\(role).defaultModifiers"))
  }

  @Test("Every row binds its own setting, so no shortcut is edited from two rows")
  func everyRowBindsItsOwnSetting() throws {
    for (label, setting) in [
      ("Recording keybind", "toggle"), ("Cancel keybind", "cancel"),
      ("Add-a-word keybind", "quickAdd"),
    ] {
      let block = try Self.rowBlock(labelled: label)
      #expect(block.contains("keyCode: $settings.\(setting)KeyCode"))
      #expect(block.contains("modifiers: $settings.\(setting)Modifiers"))
    }
  }
}
