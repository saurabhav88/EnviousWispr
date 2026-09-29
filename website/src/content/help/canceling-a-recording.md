---
title: "Canceling a Recording"
description: "Stop a recording without pasting anything, and choose whether to keep what you said."
category: "recording-and-keybinds"
section: "Recording"
order: 5
keywords: ["cancel", "stop without pasting", "throw away", "discard", "escape", "abort", "undo", "didnt mean to record", "delete recording", "cancel recording", "started recording by accident", "cancel button", "triple press"]
related: ["recording-won-t-stop-or-seems-stuck", "escape-recovery"]
updated: 2026-09-29
deflection: "can_resolve"
---
To stop a recording without pasting anything, press your cancel keybind, Escape by default. EnviousWispr keeps what you said for 24 hours in case you want it back. To throw it away for good, click **Cancel** in the main EnviousWispr window.

### Cancel a recording I started by accident

Press **Escape** while the recording is running. The recording bar disappears and nothing is pasted. Your cursor is left untouched.

This works in **Push to Talk**, in **Toggle**, and in a hands-free recording. In each mode you have these options:

- **Push to Talk:** press Escape. Or, when you start a recording, press your recording keybind three times within half a second.
- **Toggle:** press Escape. Your recording keybind stops the recording and pastes the text.
- **Hands-free** (the double-press lock in Push to Talk): press Escape. A single press of your recording keybind stops the recording and pastes the text.

### Get back a recording I cancelled with Escape

By default, Escape keeps the recording. EnviousWispr finishes transcribing it and shows a **Dictation cancelled** notice with an **Undo** button. If you miss the notice, the text waits in your History for 24 hours.

This is a setting called **Escape Recovery**, and it is on from the start. [Escape Recovery](/help/escape-recovery/) explains it in full.

Because the recording is kept, a new recording cannot start until the old one finishes processing, the same as after any dictation. If you use a cloud provider for AI polish, that polish runs under your own key and counts towards your usage, as a normal dictation would.

### Throw a recording away for good

Click **Cancel** in the main EnviousWispr window, next to **Stop** under the recording timer. The recording is dropped right away. Nothing is transcribed, nothing is pasted, and nothing is saved to History.

This button always discards, whatever your settings say. The floating recording bar has no Cancel button.

### Make Escape discard the recording too

1. Click the EnviousWispr icon in your menu bar and choose **Settings**.
2. Open **Keybinds**.
3. Under **Cancel Recording**, switch **Escape Recovery** off.

After that, pressing Escape discards the recording immediately, the same as the **Cancel** button.

### Change the cancel key

1. Click the EnviousWispr icon in your menu bar and choose **Settings**.
2. Open **Keybinds**.
3. Under **Cancel Recording**, use the **Cancel keybind** row to choose a different key.
