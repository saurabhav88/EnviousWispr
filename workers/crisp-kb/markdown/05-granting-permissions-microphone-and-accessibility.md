### Required permissions

EnviousWispr needs two macOS permissions to function:

#### 1. Microphone access

Required for recording your voice. macOS prompts you automatically on first use. If you missed the prompt:

1. Open **System Settings** > **Privacy & Security** > **Microphone**.
2. Find EnviousWispr in the list and enable it.

#### 2. Accessibility access

Required for pasting text into apps. EnviousWispr uses Accessibility APIs to insert text directly into text fields (Tier 1 paste) and to activate the correct app window before pasting.

1. Open **System Settings** > **Privacy & Security** > **Accessibility**.
2. Click the **+** button and add EnviousWispr from your Applications folder.

If Accessibility is not granted, EnviousWispr falls back to clipboard-only mode: text is placed on your clipboard, and you paste manually with Cmd+V.

### Checking permission status

Open the EnviousWispr settings window and navigate to the **Permissions** tab. It shows the current status of each required permission.

### Note on hotkey registration

The global hotkey (used to start/stop recording) uses system-wide keyboard shortcuts, which work in any app without Accessibility permission. Accessibility is only needed for the text paste step.