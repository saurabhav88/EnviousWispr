### Required permissions

EnviousWispr can prompt for up to three macOS permissions:

#### 1. Microphone access

Required for recording your voice. macOS prompts you automatically on first use. If you missed the prompt:

1. Open **System Settings** > **Privacy & Security** > **Microphone**.
2. Find EnviousWispr in the list and enable it.

#### 2. Accessibility access

Required for pasting text into apps. EnviousWispr uses Accessibility APIs to insert text directly into text fields (Tier 1 paste), to activate the correct app window before pasting, and to dispatch a Cmd+V keystroke as a fallback (Tier 2 paste).

1. Open **System Settings** > **Privacy & Security** > **Accessibility**.
2. Click the **+** button and add EnviousWispr from your Applications folder.

If Accessibility is not granted, EnviousWispr falls back to clipboard-only mode: text is placed on your clipboard, and you paste manually with Cmd+V.

#### 3. Automation (Apple Events) access

Prompted only the first time EnviousWispr's AppleScript paste fallback fires (Tier 2b — used when both direct insertion and Cmd+V keystroke fail). macOS shows a dialog asking whether EnviousWispr can control "System Events." Click **OK** to allow.

1. To review or change later, open **System Settings** > **Privacy & Security** > **Automation**.
2. Find EnviousWispr in the list and toggle the **System Events** entry on or off.

If you decline this prompt, the paste cascade stops at Tier 2 (Cmd+V keystroke). For most apps, that's enough.

### Checking permission status

Open the EnviousWispr settings window and navigate to the **Permissions** tab. It shows the current status of each required permission.

### Note on hotkey registration

The global hotkey (used to start/stop recording) uses system-wide keyboard shortcuts, which work in any app without Accessibility permission. Accessibility is only needed for the text paste step.