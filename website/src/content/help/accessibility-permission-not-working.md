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
EnviousWispr needs Accessibility permission to put text into your apps. Without it, nothing gets pasted.

### Granting it

1. Open **System Settings** \> **Privacy & Security** \> **Accessibility**.
2. Click **+** and add EnviousWispr from your Applications folder.
3. Make sure its switch is on.

You do not need to restart the app. It notices within a few seconds.

### If it was working and stopped

macOS lets permission be turned off while an app is running, and a system update can do it. EnviousWispr shows a warning when that happens. Switch it back on in the same place.

### If the switch looks on but nothing pastes

Remove EnviousWispr from the Accessibility list with the **-** button, then add it back and switch it on.

### Meanwhile

Your dictation is not lost. EnviousWispr copies it to the clipboard instead and tells you. Paste it with Cmd+V.
