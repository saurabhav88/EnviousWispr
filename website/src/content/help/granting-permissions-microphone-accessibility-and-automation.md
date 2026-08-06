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
EnviousWispr is a free dictation app for macOS. Because it listens to your microphone and types into other apps, macOS makes you grant it permission first. Two permissions are needed, and a third only in rare cases. The **Permissions** page in EnviousWispr's settings always shows where each one stands.

### Microphone

This one lets EnviousWispr hear you while you dictate.

macOS asks the first time you record. If you missed the prompt, open **System Settings** \> **Privacy & Security** \> **Microphone** and switch EnviousWispr on.

You will know it worked when you hold your hotkey and the meter on the recording bar moves as you speak.

### Accessibility

This one lets EnviousWispr put the finished text into your app for you.

Open **System Settings** \> **Privacy & Security** \> **Accessibility**, click **+**, and add EnviousWispr from your Applications folder.

You will know it worked when your next dictation lands in the text box on its own.

Without this permission, dictation still works. EnviousWispr copies your text to the clipboard instead and tells you it has done so, and you paste it yourself with Cmd+V.

### Automation

This one is a fallback, asked for only when the usual ways of pasting fail in a particular app.

macOS asks whether EnviousWispr can control "System Events". Click **OK**. To change your answer later, open **System Settings** \> **Privacy & Security** \> **Automation**.

Declining is fine. Most apps never need it.

### Your hotkey needs no permission

The key you hold to record works everywhere on its own. These permissions are only about hearing you and delivering the text.
