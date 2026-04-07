EnviousWispr captures the target app and the focused text element at the moment you **start** recording, not when text is pasted. This is intentional. AI polishing can take several seconds, during which you might switch to another app. By locking the target at recording start, the text goes where you were when you pressed the hotkey.

## How Paste Works

EnviousWispr uses a four-tier paste cascade:

1. **Tier 1 (AX Direct Insert):** Sets text directly on the focused element via the Accessibility API. No clipboard involvement, no focus change.
2. **Tier 2 (Simulated Cmd+V):** Re-activates the target app and sends a keyboard paste event. Clipboard is used but restored afterward.
3. **Tier 2b (AppleScript):** Falls back to clicking Edit > Paste via AppleScript if the app does not respond to keyboard events.
4. **Tier 3 (Clipboard Only):** Places text on the clipboard for you to paste manually. This is the last resort.

## If the Wrong App Receives Text

* Make sure the correct app and text field are focused **before** you start recording.
* If you need to switch apps during recording, the text will still go to the original app. This is by design.

## Clipboard Preservation

EnviousWispr saves your clipboard contents before pasting and restores them afterward. If a clipboard manager intercepts the change, restoration is skipped to avoid conflicts.