---
title: "Accessibility Permission Not Working"
description: "How to fix the Accessibility permission EnviousWispr needs to type into your apps."
category: "troubleshooting"
section: "Permissions"
order: 1
keywords: ["accessibility not working", "permission wont stick", "toggle keeps turning off", "already allowed but still broken", "granted but not working", "reset permission", "auto-paste needs accessibility", "accessibility warning", "switch is on but nothing pastes"]
related: ["granting-permissions-microphone-accessibility-and-automation", "paste-not-working"]
updated: 2026-10-09
deflection: "show_but_always_send"
---
EnviousWispr uses the Accessibility permission to recognize a modifier key used on its own as a keybind, such as Right Option or Globe, and to put your finished text into whatever app you are working in. Without it, such a keybind does not respond, and with any other keybind your words are transcribed but nothing is pasted.

### Turn on the Accessibility permission

1. Open **System Settings** > **Privacy & Security** > **Accessibility**.
2. Click **+** and add EnviousWispr from your Applications folder.
3. Make sure the switch beside it is on.

You do not need to restart EnviousWispr. The app notices within a few seconds. You will know it worked when your keybind starts a recording and your next dictation lands in the text box on its own.

### Accessibility stopped working after it was on

macOS can turn a permission off while an app is running, and a system update sometimes does exactly that. EnviousWispr notices the next time you dictate and warns you (for example with **Auto-paste needs Accessibility**). Switch EnviousWispr back on under **System Settings** > **Privacy & Security** > **Accessibility**.

### The switch is on but nothing pastes

macOS occasionally holds on to a stale record of the app. Remove EnviousWispr from the Accessibility list with the **-** button, then add it back with **+** and switch it on again.

### Where my text goes when it cannot paste

When EnviousWispr cannot paste, it copies your text to the clipboard instead and tells you it has done so. Press Cmd+V to put the text into your document yourself. Your dictation is not lost.
