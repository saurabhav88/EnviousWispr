---
title: "Customizing Your Keybind"
description: "Change the keys that start, stop and cancel dictation, and fix a keybind that does not work."
category: "recording-and-keybinds"
section: "Recording"
order: 4
keywords: ["keybind", "dictation stopped when i typed", "other key cancels", "secure input", "keybinds", "hotkey", "shortcut", "keyboard shortcut", "change the key", "how do i change the key", "key combo", "keybinding", "remap", "different key", "globe key", "fn key", "caps lock", "conflicts with another app", "quick add shortcut", "control shift w", "paste last dictation", "copy last dictation", "control command v", "control command c", "keybind not working", "not active", "key already in use"]
related: ["adding-a-word-from-your-selection", "escape-recovery", "transcript-history"]
updated: 2026-10-09
deflection: "can_resolve"
---
Your keybind is the key you hold or press to record, and you can change it to whatever suits your hands. EnviousWispr arrives set to the right Option key.

### Change the key that starts dictation

1. **Open Keybinds.** Click the EnviousWispr icon in your menu bar, choose **Open EnviousWispr**, and go to **Keybinds**.
2. **Select the keybind box.** Click the keys field in the **Start / stop recording** row.
3. **Press your new keys.** Press the keys you want to use.

The new combination saves immediately and appears in the box. Click into any text field and try it to confirm it works.

### Which keys can I use?

You can choose almost any combination that fits how you work.

- **A key with modifiers.** Any key, with or without Command, Option, Control or Shift.
- **A modifier on its own.** A modifier key by itself, such as Option alone or Control alone. Your hand never has to leave the keys it already rests on.
- **The Globe key on its own.** The 🌐 Globe key, labelled Fn on some keyboards, can be your recording keybind. Choose it on its own: press Globe by itself, not Globe together with another key.

### Use the Globe key without macOS interfering

macOS may already use the Globe key to switch keyboard languages, open the emoji picker or start its own dictation. If that happens while you dictate, open **System Settings**, go to **Keyboard**, click the **Press 🌐 key to** menu and choose **Do Nothing**.

Your Globe key stays set as your dictation keybind either way. This only stops macOS doing its own thing at the same time.

### Does the key change between push to talk and toggle mode?

No. The recording keybind stays the same in [push to talk](/help/push-to-talk-mode/) and [toggle mode](/help/toggle-mode/). Switching modes changes what a press does to your recording, never which key you press.

If holding a key down is uncomfortable, toggle mode asks less of your hand. One press starts recording and the next press stops it, so nothing has to be held.

### Pressing another key right after your keybind

In push to talk, if you press another key within the first second after your keybind goes down, EnviousWispr treats it as typing, not dictation. It throws that recording away: nothing is pasted and nothing is kept, even with Escape Recovery on. This lets you keep using a modifier such as Option for typing special characters or for other shortcuts.

After the first second, extra keys are ignored and your dictation carries on as usual. A locked dictation (double tap) and toggle mode are not affected.

If another key is already down when you press your keybind, no dictation starts. Let go of the other key and press your keybind again.

When macOS Secure Input is on, often because a password field is active, EnviousWispr cannot see other keys, so this rule pauses. A short notice in the recording panel tells you, and your dictation still works.

### Change the cancel key

Pressing Escape ends the current recording without pasting anything. To use a different cancel key, open **Keybinds** and change the **Cancel recording** row.

**Escape Recovery** is on unless you switch it off. With it on, your cancel keybind keeps the recording and offers to paste it back rather than discarding it. Keep that in mind before you reassign the key. See [Escape Recovery](/help/escape-recovery/).

### Change the Quick Add key

The **Keybinds** page has an **Add selected word to Dictionary** row under **Shortcuts**. Highlight a misheard word anywhere on your Mac, press it, and a small panel offers to add the right spelling to your dictionary. It is **Control Shift W** unless you change it. See [Adding a Word From Your Selection](/help/adding-a-word-from-your-selection/).

### Paste or copy my last dictation

Two more keybinds sit under **Shortcuts**: **Paste last dictation** and **Copy last dictation**. They reuse the last thing you dictated, so you never have to say it twice.

- **Paste last dictation** is **Control Command V** unless you change it. It pastes into the app you were in when you pressed the keys.
- **Copy last dictation** is **Control Command C** unless you change it. It puts your last dictation on your clipboard, ready for Cmd+V anywhere.

The menu bar menu has the same paste as **Paste Last Dictation**, with the start of the text shown under it. See [History](/help/transcript-history/) for which dictation counts as the last one.

While EnviousWispr is running, pressing either combination usually runs EnviousWispr's action rather than the other app's. In Terminal, Control Command V is normally Paste Escaped Text, and some apps, such as Final Cut Pro, use Control Command C. If you rely on those, choose different keys here.

### Why a key combination will not save

A keybind box refuses two kinds of combination:

- **Keys another keybind on the page already uses.**
- **Standard Mac shortcuts** such as Cmd+C, Cmd+V and Cmd+Q, so a new keybind cannot break copying, saving or quitting.

Choose a combination that is not reserved and is not already used by another EnviousWispr keybind.

### A keybind says Not active

A box also refuses a combination that includes a single key a more important keybind uses on its own. For example, you set your recording keybind to Right Command, and another row's combination includes Command. Both Last Dictation defaults use Command.

The recording keybind wins. The other row then says **Not active** and names the keybind that took its keys. Choose another combination for that row.

### My keybind does nothing

If **Keybinds** warns that macOS reports your combination as already taken, pick a different combination there.

If a keybind does nothing and no warning appears, another app or a macOS feature may be using the same combination. Try a different one.

A modifier key used on its own as a keybind, such as Right Option or Globe, also needs the Accessibility permission. If it does nothing, see [_Accessibility Permission Not Working_](/help/accessibility-permission-not-working/).
