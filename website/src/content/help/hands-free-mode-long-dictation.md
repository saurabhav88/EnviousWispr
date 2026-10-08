---
title: "Hands-Free Mode (Long Dictation)"
description: "Lock recording on with a double press so you can keep talking without holding the key."
category: "recording-and-keybinds"
section: "Recording"
order: 2
keywords: ["hands free", "handsfree", "long dictation", "dont want to hold", "dont want to hold the key", "hold the key", "without holding", "let go", "keep recording", "long recording", "stop holding the key", "double press", "lock recording", "double tap", "record without holding"]
related: ["voice-activity-detection-and-auto-stop", "recording-won-t-stop-or-seems-stuck"]
updated: 2026-09-29
deflection: "can_resolve"
---
Hands-free mode locks recording on, so you can talk without holding the key. It suits anything longer than a sentence or two, such as a blog post, a long email, or meeting notes. It works when your recording mode is **Push to Talk**.

### How to record without holding the key

1. **Press and release.** Press your recording keybind and let go.
2. **Press again.** Press it a second time within half a second of the first press.

The recording bar changes to show that recording is locked on. If it does not change, the second press came too late, and the recording ends as usual. Try the second press a little quicker.

In **Toggle** mode you do not need this. One press starts recording and the next press stops it. See [Toggle Mode](/help/toggle-mode/).

### Stop a hands-free recording

- **Press your recording keybind once.** Recording stops and your text goes into the app you were working in.
- **Press Escape.** Recording stops and nothing is pasted. By default EnviousWispr keeps what you said and offers it back, which is [Escape Recovery](/help/escape-recovery/).
- **Click Cancel** in the main EnviousWispr window, next to **Stop**, to throw the recording away. The floating recording bar has no Cancel button.

A third quick press, within half a second of your first press, cancels the recording instead. Other presses in the half second right after it locks do nothing, so a bounce of your finger does not end the recording.

### How long can a hands-free recording be?

A single recording can last up to one hour. EnviousWispr warns you one minute before the limit. Then it stops on its own and writes out everything you said.

### Stop recording when I stop talking

You can have EnviousWispr end a recording after a pause in your speech. The [auto-stop guide](/help/voice-activity-detection-and-auto-stop/) covers it in full.

1. Click the EnviousWispr icon in your menu bar and choose **Open EnviousWispr**.
2. Open **Dictation Settings**, then **Engine**.
3. Under **Applies to both engines**, switch on **Stop recording on silence**. It is off by default.
4. Use the **Pause duration** slider to choose how long a pause ends the recording, from half a second to three seconds.
