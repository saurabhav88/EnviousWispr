import AppKit

/// Converts key codes and modifiers to human-readable symbols
enum KeySymbols {
    /// Convert modifier flags to symbol string (e.g., "⌘⌥⇧⌃")
    static func symbolsForModifiers(_ flags: NSEvent.ModifierFlags) -> String {
        var symbols = ""
        if flags.contains(.control) { symbols += "⌃" }
        if flags.contains(.option) { symbols += "⌥" }
        if flags.contains(.shift) { symbols += "⇧" }
        if flags.contains(.command) { symbols += "⌘" }
        return symbols
    }

    /// Convert key code to readable name
    static func nameForKeyCode(_ keyCode: UInt16) -> String {
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

    /// Format a complete hotkey as readable string (e.g., "⌥ Space")
    static func format(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> String {
        let modSymbols = symbolsForModifiers(modifiers)
        let keyName = nameForKeyCode(keyCode)
        if modSymbols.isEmpty {
            return keyName
        }
        return "\(modSymbols) \(keyName)"
    }

    /// Format just modifiers for push-to-talk display.
    /// When a keyCode is provided the label distinguishes left vs. right physical keys.
    static func formatModifierOnly(_ flags: NSEvent.ModifierFlags, keyCode: UInt16? = nil) -> String {
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
