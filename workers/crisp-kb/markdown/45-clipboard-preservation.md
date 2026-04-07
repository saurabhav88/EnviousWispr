When EnviousWispr uses Tier 2 or Tier 2b to paste (methods that use the clipboard), it saves your existing clipboard contents first and restores them afterward.

### How It Works

1. **Snapshot**: Before placing transcribed text on the clipboard, EnviousWispr captures a full snapshot of all clipboard items with all type representations (not just plain text).
2. **Paste**: The transcribed text is placed on the clipboard and the paste keystroke is sent.
3. **Wait**: A configurable delay gives the target app time to read the paste from the clipboard.
4. **Restore**: The original clipboard contents are restored from the snapshot.

### Change Count Guard

Before restoring, EnviousWispr checks the clipboard's change count. If another app (such as a clipboard manager) has modified the clipboard since the paste, the restore is skipped to avoid overwriting that app's changes.

### Tier 1 Bypasses the Clipboard

When Tier 1 (AX Direct Insertion) succeeds, the clipboard is never touched at all. Your clipboard contents remain exactly as they were.