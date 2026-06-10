import Testing

@testable import EnviousWisprServices

// #729 Tier 2c: the language-agnostic Edit > Paste matcher. The AX menu-bar
// traversal (`findPasteMenuItem`) is live-only like the other AX primitives
// (`captureFocusedElement`, `forceActivateApp`) and is exercised by Live UAT;
// the pure matching predicate is unit-tested here.
@Suite("PasteService.isPasteShortcut")
struct PasteMenuProbeTests {

  @Test("⌘V (cmdChar v, no extra modifiers) matches")
  func commandVMatches() {
    #expect(PasteService.isPasteShortcut(cmdChar: "v", modifiers: 0))
  }

  @Test("uppercase V from AXMenuItemCmdChar still matches (case-insensitive)")
  func uppercaseVMatches() {
    #expect(PasteService.isPasteShortcut(cmdChar: "V", modifiers: 0))
  }

  @Test("⇧⌘V (Shift bit set) does NOT match — that's Paste and Match Style")
  func shiftCommandVRejected() {
    // kAXMenuItemModifierShift = 1 << 0
    #expect(!PasteService.isPasteShortcut(cmdChar: "v", modifiers: 1))
  }

  @Test("⌥⌘V (Option bit set) does NOT match")
  func optionCommandVRejected() {
    // kAXMenuItemModifierOption = 1 << 1
    #expect(!PasteService.isPasteShortcut(cmdChar: "v", modifiers: 2))
  }

  @Test("NoCommand bit set (1<<3) does NOT match — that shortcut has no ⌘")
  func noCommandRejected() {
    // kAXMenuItemModifierNoCommand = 1 << 3 = 8
    #expect(!PasteService.isPasteShortcut(cmdChar: "v", modifiers: 8))
  }

  @Test("a different command key (⌘C) does NOT match")
  func commandCRejected() {
    #expect(!PasteService.isPasteShortcut(cmdChar: "c", modifiers: 0))
  }

  @Test("nil cmdChar (item has no shortcut) does NOT match")
  func nilCmdCharRejected() {
    #expect(!PasteService.isPasteShortcut(cmdChar: nil, modifiers: 0))
  }

  @Test("missing-modifiers sentinel (-1) does NOT match")
  func missingModifiersRejected() {
    #expect(!PasteService.isPasteShortcut(cmdChar: "v", modifiers: -1))
  }

  @Test("matches on shortcut alone — title is never consulted (localization-proof)")
  func matchesRegardlessOfLocale() {
    // A localized menu would title this "Coller" / "貼り付け" etc.; the matcher
    // never sees the title, only the ⌘V shortcut, so it matches identically.
    #expect(PasteService.isPasteShortcut(cmdChar: "v", modifiers: 0))
  }
}
