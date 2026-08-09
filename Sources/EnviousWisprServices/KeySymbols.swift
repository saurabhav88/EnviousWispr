import AppKit

/// Modifier key codes that can act as standalone hotkeys.
/// These are the physical key codes reported by NSEvent / Carbon for each modifier key.
public enum ModifierKeyCodes {
  public static let leftCommand: UInt16 = 55
  public static let rightCommand: UInt16 = 54
  public static let leftOption: UInt16 = 58
  public static let rightOption: UInt16 = 61
  public static let leftShift: UInt16 = 56
  public static let rightShift: UInt16 = 60
  public static let leftControl: UInt16 = 59
  public static let rightControl: UInt16 = 62
  /// The Globe / Fn key (`kVK_Function`). Measured on real hardware (#1987): it
  /// emits `.flagsChanged` with `.function` present on press and absent on
  /// release, seen by the same NSEvent monitors the other eight use.
  package static let globe: UInt16 = 63

  /// The ONE mapping of standalone modifier key code to the flag it sets while held.
  ///
  /// Membership and flag are the same fact, so they are stored once. Before #1987
  /// this fact lived in two private switches, one on the dispatch path and one on
  /// the capture view, plus a separately maintained membership list, so adding a
  /// key meant remembering all three. Deriving
  /// membership from the mapping makes "a member with no flag" unrepresentable
  /// rather than merely guarded: that state would make `flags.contains(flag)` true
  /// on release as well as press, so push-to-talk would start recording and never
  /// stop.
  private static let flagsByKeyCode: [UInt16: NSEvent.ModifierFlags] = [
    leftCommand: .command, rightCommand: .command,
    leftOption: .option, rightOption: .option,
    leftShift: .shift, rightShift: .shift,
    leftControl: .control, rightControl: .control,
    globe: .function,
  ]

  public static let all: Set<UInt16> = Set(flagsByKeyCode.keys)

  /// Returns true if the given key code is a standalone modifier key.
  public static func isModifierOnly(_ keyCode: UInt16) -> Bool {
    flagsByKeyCode[keyCode] != nil
  }

  /// The modifier flag this standalone key sets while held, or nil if the key code
  /// is not a standalone modifier.
  ///
  /// Optional by design. An empty-set return would be indistinguishable from a real
  /// flag to `OptionSet.contains`, which is a superset test: `anything.contains([])`
  /// is always true.
  package static func flag(for keyCode: UInt16) -> NSEvent.ModifierFlags? {
    flagsByKeyCode[keyCode]
  }

}

/// Converts key codes and modifiers to human-readable symbols
public enum KeySymbols {
  /// Convert modifier flags to symbol string (e.g., "⌘⌥⇧⌃")
  public static func symbolsForModifiers(_ flags: NSEvent.ModifierFlags) -> String {
    var symbols = ""
    if flags.contains(.control) { symbols += "⌃" }
    if flags.contains(.option) { symbols += "⌥" }
    if flags.contains(.shift) { symbols += "⇧" }
    if flags.contains(.command) { symbols += "⌘" }
    return symbols
  }

  /// Convert key code to readable name
  public static func nameForKeyCode(_ keyCode: UInt16) -> String {
    switch keyCode {
    case 0: return "A"
    case 1: return "S"
    case 2: return "D"
    case 3: return "F"
    case 4: return "H"
    case 5: return "G"
    case 6: return "Z"
    case 7: return "X"
    case 8: return "C"
    case 9: return "V"
    case 11: return "B"
    case 12: return "Q"
    case 13: return "W"
    case 14: return "E"
    case 15: return "R"
    case 16: return "Y"
    case 17: return "T"
    case 18: return "1"
    case 19: return "2"
    case 20: return "3"
    case 21: return "4"
    case 22: return "6"
    case 23: return "5"
    case 24: return "="
    case 25: return "9"
    case 26: return "7"
    case 27: return "-"
    case 28: return "8"
    case 29: return "0"
    case 30: return "]"
    case 31: return "O"
    case 32: return "U"
    case 33: return "["
    case 34: return "I"
    case 35: return "P"
    case 36: return "Return"
    case 37: return "L"
    case 38: return "J"
    case 39: return "'"
    case 40: return "K"
    case 41: return ";"
    case 42: return "\\"
    case 43: return ","
    case 44: return "/"
    case 45: return "N"
    case 46: return "M"
    case 47: return "."
    case 48: return "Tab"
    case 49: return "Space"
    case 50: return "`"
    case 51: return "Delete"
    case 53: return "Escape"
    case 96: return "F5"
    case 97: return "F6"
    case 98: return "F7"
    case 99: return "F3"
    case 100: return "F8"
    case 101: return "F9"
    case 103: return "F11"
    case 105: return "F13"
    case 107: return "F14"
    case 109: return "F10"
    case 111: return "F12"
    case 113: return "F15"
    case 118: return "F4"
    case 119: return "End"
    case 120: return "F2"
    case 121: return "Page Down"
    case 122: return "F1"
    case 123: return "←"
    case 124: return "→"
    case 125: return "↓"
    case 126: return "↑"
    default: return "Key \(keyCode)"
    }
  }

  /// Format a complete hotkey as readable string (e.g., "⌥ Space").
  ///
  /// When the keyCode is a modifier key and modifiers is empty the hotkey is
  /// treated as modifier-only and formatted via `formatModifierOnly`.
  public static func format(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> String {
    // Modifier-only hotkey: keyCode is itself a modifier key, no additional modifiers.
    if ModifierKeyCodes.isModifierOnly(keyCode) && modifiers.isEmpty {
      return formatModifierOnly(modifiers, keyCode: keyCode)
    }
    let modSymbols = symbolsForModifiers(modifiers)
    let keyName = nameForKeyCode(keyCode)
    if modSymbols.isEmpty {
      return keyName
    }
    return "\(modSymbols) \(keyName)"
  }

  /// Alias for `format` — used by HotkeyService for display strings.
  public static func formatHotkey(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> String {
    format(keyCode: keyCode, modifiers: modifiers)
  }

  /// Spoken projection of a shortcut, for accessibility VALUES only.
  ///
  /// Separate from `format` because the visible label leads with an emoji, and a
  /// screen reader announcing "globe showing Europe-Africa Globe (Fn)" is worse
  /// than useless to the person this key most helps. Presentation-only: nothing
  /// may key behaviour off the returned string.
  package static func accessibilityDescription(
    keyCode: UInt16,
    modifiers: NSEvent.ModifierFlags
  ) -> String {
    if keyCode == ModifierKeyCodes.globe {
      return "Globe or Function key"
    }
    return format(keyCode: keyCode, modifiers: modifiers)
  }

  /// Format just modifiers for push-to-talk display.
  /// When a keyCode is provided the label distinguishes left vs. right physical keys.
  public static func formatModifierOnly(_ flags: NSEvent.ModifierFlags, keyCode: UInt16? = nil)
    -> String
  {
    if let kc = keyCode {
      switch kc {
      case 55: return "Left ⌘"
      case 54: return "Right ⌘"
      case 58: return "Left ⌥"
      case 61: return "Right ⌥"
      case 56: return "Left ⇧"
      case 60: return "Right ⇧"
      case 59: return "Left ⌃"
      case 62: return "Right ⌃"
      // The Globe key is a single physical key, so unlike the eight above it
      // carries no Left/Right qualifier. Both names are deliberate: macOS System
      // Settings calls it the globe key and draws 🌐, which is what our setup
      // guidance tells the user to look for, while "Fn" is what is printed on the
      // keyboard and what users arrive saying from other dictation apps.
      case 63: return "🌐 Globe (Fn)"
      default: break
      }
    }
    // Fall through to side-blind display
    if flags.contains(.option) && flags.rawValue == NSEvent.ModifierFlags.option.rawValue {
      return "⌥ Option"
    }
    if flags.contains(.command) && flags.rawValue == NSEvent.ModifierFlags.command.rawValue {
      return "⌘ Command"
    }
    if flags.contains(.control) && flags.rawValue == NSEvent.ModifierFlags.control.rawValue {
      return "⌃ Control"
    }
    if flags.contains(.shift) && flags.rawValue == NSEvent.ModifierFlags.shift.rawValue {
      return "⇧ Shift"
    }
    return symbolsForModifiers(flags)
  }
}
