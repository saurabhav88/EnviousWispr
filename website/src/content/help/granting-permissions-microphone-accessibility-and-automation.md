---
title: "Granting Permissions (Microphone, Accessibility, and Automation)"
description: "The macOS permissions EnviousWispr asks for, and what each one is used for."
category: "getting-started"
section: "Basics"
order: 5
keywords: ["permissions", "permission", "allow", "access", "microphone access", "accessibility", "privacy settings", "system settings", "grant", "it is asking for permission", "blocked", "denied"]
related: ["accessibility-permission-not-working", "paste-not-working"]
updated: 2026-08-05
---
EnviousWispr needs two permissions, and a third only in rare cases. The **Permissions** page in Settings always shows where you stand.

### Microphone

Needed to hear you. macOS asks the first time you record.

If you missed the prompt, open **System Settings** \> **Privacy & Security** \> **Microphone** and switch EnviousWispr on.

### Accessibility

Needed to put the text into your app for you.

Open **System Settings** \> **Privacy & Security** \> **Accessibility**, click **+**, and add EnviousWispr from your Applications folder.

Without it, dictation still works. EnviousWispr copies your text to the clipboard instead and tells you, so you can paste it with Cmd+V.

### Automation

Asked for only if the usual ways of pasting do not work in a particular app. macOS asks whether EnviousWispr can control "System Events". Click **OK**.

To change it later, open **System Settings** \> **Privacy & Security** \> **Automation**.

Declining is fine. Most apps never need it.

### Your hotkey needs no permission

The recording hotkey works everywhere on its own. These permissions are only about hearing you and delivering the text.
