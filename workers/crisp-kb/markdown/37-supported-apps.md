EnviousWispr works with any macOS application that has a text input field. This includes native macOS apps, web browsers, Electron apps (VS Code, Slack, Discord, Notion), and any other app where you can type.

## Multi-Tier Paste for Maximum Compatibility

Different apps handle text input differently. EnviousWispr uses a cascading paste strategy to maximize compatibility:

1. **Tier 1 (AX Direct Insert):** Uses the macOS Accessibility API to insert text directly into the focused element. Works with standard text fields, text areas, combo boxes, and search fields. Zero clipboard involvement, zero focus change. Includes verification that text actually appeared.
2. **Tier 2 (Simulated Cmd+V):** Re-activates the target app and simulates a keyboard paste. Used when Tier 1 is unavailable or verification fails (common with Electron apps that report success but do not render the text).
3. **Tier 2b (AppleScript Paste):** Clicks Edit > Paste via AppleScript. Used when keyboard-based activation times out.
4. **Tier 3 (Clipboard Only):** Places text on the clipboard for manual paste. The absolute last resort. Your text is never lost.

## Clipboard Preservation

During Tier 2 and 2b paste, EnviousWispr saves your clipboard contents before pasting and restores them afterward. If a clipboard manager has advanced the clipboard in the meantime, restoration is skipped to avoid conflicts.