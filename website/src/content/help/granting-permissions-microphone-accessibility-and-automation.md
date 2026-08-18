---
title: "Granting Permissions (Microphone, Accessibility, and Automation)"
description: "The macOS permissions EnviousWispr asks for, and what each one is used for."
category: "getting-started"
section: "Basics"
order: 5
keywords: ["permissions", "permission", "allow", "access", "microphone access", "accessibility", "privacy settings", "system settings", "grant", "it is asking for permission", "blocked", "denied"]
related: ["accessibility-permission-not-working", "paste-not-working"]
updated: 2026-08-06
---
Because EnviousWispr listens to your microphone and types into other apps, macOS requires you to grant specific permissions first. Two permissions are always needed, and a third is required only in rare cases. The **Permissions** page in EnviousWispr settings always shows the current status of each one.

### Microphone

This permission allows EnviousWispr to hear your voice while you dictate.

**Grant permission.** macOS asks the first time you record. If you missed the prompt, open **System Settings**, select **Privacy & Security**, click **Microphone**, and switch EnviousWispr on.

You will know it worked when you hold your keybind and the meter on the recording bar moves as you speak.

### Accessibility

This permission allows EnviousWispr to place the finished text directly into the app you are working in.

**Grant permission.** Open **System Settings**, select **Privacy & Security**, click **Accessibility**, click the plus button, and add EnviousWispr from your Applications folder.

You will know it worked when your next dictation lands in the text box on its own.

Without this permission, dictation still works. EnviousWispr copies your text to the clipboard instead and tells you it has done so, and you paste it yourself with Cmd+V.

### Automation

This permission is a fallback, requested only when the usual ways of pasting fail inside a particular application.

**Grant permission.** macOS asks whether EnviousWispr can control System Events. Click **OK**. To change your answer later, open **System Settings**, select **Privacy & Security**, and click **Automation**.

Declining this permission is fine, because most applications never require it.

### Your keybind needs no permission

The key you hold to record works everywhere on its own. These permissions are strictly about hearing your voice and delivering the text.
