---
title: "Paste Not Working?"
description: "What to check when your dictation does not appear in your app."
category: "pasting-your-text"
section: "Paste System"
order: 3
keywords: ["paste not working", "wont paste", "nothing pastes", "text not appearing", "goes to the wrong app", "vs code", "slack", "discord", "notion", "no text in my app"]
related: ["accessibility-permission-not-working", "how-text-gets-pasted-into-your-app"]
updated: 2026-08-05
---
Work through these in order.

### 1. Check Accessibility permission

This is the cause most of the time. Open **System Settings** \> **Privacy & Security** \> **Accessibility**. EnviousWispr should be listed and switched on. Without it, nothing can be typed into your apps.

If the switch already looks on, remove EnviousWispr with **-** and add it back.

### 2. Check your cursor was in a text box

EnviousWispr sends the text where your cursor was when you **started** recording. Click into the box first, then press the hotkey.

### 3. The text went to a different app

Same reason. If you switched apps during the dictation, the text still goes to the one you started in. That is on purpose.

### 4. VS Code, Slack, Discord and similar

These sometimes accept text and quietly ignore it. EnviousWispr checks for that and pastes a different way, so it should just work. If it does not, make sure the app is in front and your cursor is in the field before you record.

### 5. You were told the text is on your clipboard

Every delivery method failed. Your dictation is safe. Press Cmd+V to paste it, then work through the checks above.
