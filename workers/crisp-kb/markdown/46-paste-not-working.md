If transcribed text is not appearing in your target app, work through these checks in order.

### 1. Check Accessibility Permission

EnviousWispr requires Accessibility permission for both paste delivery (Simulated Cmd+V) and AX direct insertion.

* Open **System Settings > Privacy & Security > Accessibility**.
* Confirm EnviousWispr is listed and toggled on.
* Accessibility permission can be revoked at runtime. EnviousWispr monitors this with periodic polling and will show a warning if permission is lost.

Without Accessibility permission, Simulated keystrokes are sent but silently never delivered to the target app.

### 2. Electron Apps

Some Electron-based apps (VS Code, Slack desktop, Discord) report AX insertion as successful but do not render the text. EnviousWispr detects this by verifying the character count changed after insertion. If it did not, the cascade falls through to Tier 2 (Simulated Cmd+V), which works reliably in Electron apps.

If you still have issues in an Electron app, confirm the app is focused and the cursor is in a text input field when you start recording.

### 3. App Activation Failures

If you switched away from the target app during recording and polish, EnviousWispr will attempt to re-activate it. On macOS 14 and later, the standard activation API is ineffective for menu bar apps. EnviousWispr uses the Accessibility API to force-activate the target app, which requires Accessibility permission.

If the target app will not come to the front, the cascade falls to AppleScript (Tier 2b) and then to clipboard-only (Tier 3).

### 4. Text Lands in the Wrong App

EnviousWispr captures the target app and focused element at the moment you start recording. If you click into a different app or field before pressing the hotkey, text will go there instead. Make sure the cursor is in the correct field before starting your recording.

### 5. Clipboard-Only Fallback

If you see a notification that text was placed on your clipboard, all active paste methods failed. The text is safe on your clipboard and you can paste it manually with Cmd+V. Check the issues above and try again.