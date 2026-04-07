After transcription and any text processing, EnviousWispr needs to deliver the text into whatever app you were using. This is surprisingly tricky on macOS: different apps handle input differently, and some (like Electron-based apps) report success without actually inserting text. EnviousWispr uses a multi-tier paste cascade to handle every case.

### Target Capture at Recording Start

The target app and focused input element are captured when you *start* recording, not when text is ready to paste. This is important because AI polish can take a few seconds, and you might switch apps in the meantime. EnviousWispr remembers where you were dictating and delivers text there.

### The Paste Cascade

#### Tier 1: AX Direct Insertion

The fastest and cleanest method. EnviousWispr uses the macOS Accessibility API to set text directly on the focused element. This does not touch your clipboard at all.

* Works with standard text fields, text areas, combo boxes, and search fields.
* Validates that the element is writable (not read-only).
* Verifies that text actually appeared by checking character count before and after. Some apps (notably Electron) report success but do not render the text.

If verification fails, EnviousWispr falls through to Tier 2.

#### Tier 2: Simulated Cmd+V

EnviousWispr activates your target app using the Accessibility API, places the text on the clipboard, and sends a simulated Cmd+V keystroke.

* Polls until the target app comes to the front (up to 1 second).
* Re-attempts activation every 300ms if the first attempt was absorbed by the window server.

#### Tier 2b: AppleScript Fallback

If keyboard-based activation times out (the app did not come to the front), EnviousWispr tries one more activation attempt, then uses AppleScript to click the Paste menu item in the target app's Edit menu.

#### Tier 3: Clipboard Only

If all active paste methods fail, the text is placed on your clipboard and you receive a notification. Your dictation is never lost.