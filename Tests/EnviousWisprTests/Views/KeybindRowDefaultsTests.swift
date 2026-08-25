import Foundation
import Testing

@testable import EnviousWisprServices

/// #2381 — every keybind row's Reset offers the value a fresh install actually gets.
///
/// When this fails the user presses Reset on a shortcut row and lands on a chord that is NOT the
/// default, so their "back to how it shipped" differs from a colleague's fresh install and from
/// every screenshot and support answer. It compiles, it looks right, and nothing else notices.
///
/// **The row's default is a LITERAL in the view and the real default is a constant in Services**,
/// with nothing linking the two. That is the shape of a claim that decays without anyone touching
/// the line: `SettingsDefaultValues` is where a default is CHANGED, and the view is where it is
/// OFFERED. This is a drift guard, not product coverage — it protects a property of the source,
/// so it reads the source.
///
/// Swept over all THREE rows rather than only the new one: the new row's author is the one person
/// certain to have checked theirs, and an entity sweep finds wrong statements while a member sweep
/// finds omissions.
@Suite("Keybind row defaults match the shipped defaults (#2381)", .tags(.driftGuard))
struct KeybindRowDefaultsTests {

  private static func viewSource() throws -> String {
    let url = RepoRoot.sourceURL(
      "Sources/EnviousWisprAppKit/Views/Settings/KeybindsSettingsView.swift")
    return try String(contentsOf: url, encoding: .utf8)
  }

  @Test("The Quick Add row binds the Quick Add setting, not a neighbour's")
  func quickAddRowBindsItsOwnSetting() throws {
    let source = try Self.viewSource()

    #expect(source.contains("keyCode: $settings.quickAddKeyCode"))
    #expect(source.contains("modifiers: $settings.quickAddModifiers"))
  }

  @Test("The Quick Add row's Reset offers the value a fresh install gets")
  func quickAddRowResetMatchesTheShippedDefault() throws {
    let source = try Self.viewSource()

    #expect(
      SettingsDefaultValues.quickAddKeyCode == 13,
      "the shipped default moved; the view literal below must move with it")
    #expect(
      source.contains("defaultKeyCode: 13"),
      "the row would reset to a chord no fresh install has")
    #expect(source.contains("defaultModifiers: [.control, .option]"))
  }

  @Test("Every keybind row appears exactly once, so no shortcut is edited from two places")
  func eachRowAppearsOnce() throws {
    let source = try Self.viewSource()

    for binding in ["$settings.toggleKeyCode", "$settings.cancelKeyCode", "$settings.quickAddKeyCode"] {
      #expect(
        source.components(separatedBy: "keyCode: \(binding)").count - 1 == 1,
        "\(binding) is bound by more than one row")
    }
  }

  @Test("The cancel row's Reset also matches its shipped default")
  func cancelRowResetMatchesTheShippedDefault() throws {
    // The paired existing case. Without it this suite would only ever have checked the row its
    // author wrote, which is the row least likely to be wrong.
    let source = try Self.viewSource()

    #expect(SettingsDefaultValues.cancelKeyCode == 53)
    #expect(source.contains("defaultKeyCode: 53"))
  }

  @Test("The record row's Reset reads the constant rather than repeating its number")
  func recordRowResetReadsTheConstant() throws {
    // The record row is the one shape that CANNOT drift, because it names the symbol instead of a
    // literal. Asserted so the pattern is visible as the better one, and so a later edit replacing
    // it with a number is a conscious act.
    let source = try Self.viewSource()

    #expect(source.contains("defaultKeyCode: ModifierKeyCodes.rightOption"))
    #expect(SettingsDefaultValues.toggleKeyCode == Int(ModifierKeyCodes.rightOption))
  }
}
