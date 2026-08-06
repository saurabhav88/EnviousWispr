---
title: "Accessibility Permission Not Working"
description: "Fixing the permission EnviousWispr needs to type into your apps."
category: "troubleshooting"
section: "Permissions"
order: 1
keywords: ["accessibility not working", "permission wont stick", "toggle keeps turning off", "already allowed but still broken", "granted but not working", "reset permission"]
related: ["granting-permissions-microphone-accessibility-and-automation", "paste-not-working"]
updated: 2026-08-05
---
EnviousWispr is a free dictation app for macOS, and it uses the Accessibility permission to put your finished text into whatever app you are working in. Without that permission, your words are transcribed but nothing is pasted.

### Grant it

1. Open **System Settings** \> **Privacy & Security** \> **Accessibility**.
2. Click **+** and add EnviousWispr from your Applications folder.
3. Make sure the switch beside it is on.

You do not need to restart EnviousWispr. It notices within a few seconds. You will know it worked when your next dictation lands in the text box on its own.

### If it was working and then stopped

macOS can turn a permission off while an app is running, and a system update sometimes does exactly that. EnviousWispr shows a warning when it happens. Switch the permission back on in the same place.

### If the switch looks on but nothing pastes

macOS occasionally holds on to a stale record of the app. Remove EnviousWispr from the Accessibility list with the **-** button, then add it back with **+** and switch it on again.

### Your dictation is not lost meanwhile

When EnviousWispr cannot paste, it copies your text to the clipboard instead and tells you it has done so. Press Cmd+V to put it in yourself.
