---
title: "Hands-Free Mode (Long Dictation)"
description: "Lock recording on with a double press, or by pressing Space while you hold the key, so you can keep talking without holding it."
category: "recording-and-keybinds"
section: "Recording"
order: 2
keywords: ["hands free", "handsfree", "long dictation", "dont want to hold", "dont want to hold the key", "hold the key", "without holding", "let go", "keep recording", "long recording", "stop holding the key", "double press", "lock recording", "double tap", "record without holding", "press space", "space while holding", "lock while holding", "already holding the key", "switch to hands free"]
related: ["voice-activity-detection-and-auto-stop", "recording-won-t-stop-or-seems-stuck"]
updated: 2026-10-12
deflection: "can_resolve"
---
Hands-free mode locks recording on, so you can talk without holding the key. It suits anything longer than a sentence or two, such as a blog post, a long email, or meeting notes. It works when your recording mode is **Push to Talk**.

### How to record without holding the key

1. **Press and release.** Press your recording keybind and let go.
2. **Press again.** Press it a second time within half a second of the first press.

The recording bar changes to show that recording is locked on. If it does not change, the second press came too late, and the recording ends as usual. Try the second press a little quicker.

### Lock a recording you are already holding

Already holding your recording keybind and want to let go? Keep holding it and press **Space**. The recording bar changes to show that recording is locked on, and you can let go of the keybind. The Space press is used to lock the recording, so it is normally not typed into your app.

- It works at any point while you hold the keybind, including the first second.
- It works in **Push to Talk** when your keybind is a modifier key used on its own, such as the right Option key, which is the default.
- Press Space with only your keybind held. If you hold another modifier key too, EnviousWispr does not treat it as a lock.
- It does not work when your keybind is a combination of keys, or in **Toggle** mode. It also does not work while macOS Secure Input is on, which some password fields turn on, because EnviousWispr cannot see the Space then.
- Some macOS shortcuts also use Space with a modifier key, such as Command+Space for Spotlight. If your keybind is that modifier key, macOS may react to the Space as well. If that happens, choose another keybind, or change that macOS shortcut in **System Settings** > **Keyboard** > **Keyboard Shortcuts**.
- If the lock does not take, the recording ends when you let go, as it always does in Push to Talk.

In **Toggle** mode you do not need this. One press starts recording and the next press stops it. See [Toggle Mode](/help/toggle-mode/).

### Stop a hands-free recording

- **Press your recording keybind once.** Recording stops and your text goes into the app you were working in.
- **Press Escape.** Recording stops and nothing is pasted. By default EnviousWispr keeps what you said and offers it back, which is [Escape Recovery](/help/escape-recovery/).
- **Click Cancel** in the main EnviousWispr window, next to **Stop**, to throw the recording away. The floating recording bar has no Cancel button.

A third quick press, within half a second of your first press, cancels a recording you locked with a double press. After either kind of lock, other presses in the half second right after it locks do nothing, so a bounce of your finger does not end the recording.

### How long can a hands-free recording be?

A single recording can last up to one hour. EnviousWispr warns you one minute before the limit. Then it stops on its own and writes out everything you said.

### Stop recording when I stop talking

You can have EnviousWispr end a recording after a pause in your speech. The [auto-stop guide](/help/voice-activity-detection-and-auto-stop/) covers it in full.

1. Click the EnviousWispr icon in your menu bar and choose **Open EnviousWispr**.
2. Open **Dictation Settings**, then **Engine**.
3. Under **Applies to both engines**, switch on **Stop recording on silence**. It is off by default.
4. Use the **Pause duration** slider to choose how long a pause ends the recording, from half a second to three seconds.
