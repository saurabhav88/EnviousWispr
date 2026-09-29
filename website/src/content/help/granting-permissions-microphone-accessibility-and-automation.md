---
title: "Granting Permissions (Microphone, Accessibility, and Automation)"
description: "The macOS permissions EnviousWispr asks for, and what each one is used for."
category: "getting-started"
section: "Basics"
order: 5
keywords: ["permissions", "permission", "allow", "access", "microphone access", "accessibility", "privacy settings", "system settings", "grant", "it is asking for permission", "blocked", "denied", "request access"]
related: ["accessibility-permission-not-working", "paste-not-working"]
updated: 2026-09-29
deflection: "can_resolve"
---
EnviousWispr listens to your microphone and types into other apps, so macOS asks you to grant it permissions first. Microphone is required. Accessibility is strongly recommended, and Automation is needed only in rare cases. Setup asks for Microphone and Accessibility before the practice dictation at the end, so most people grant both there.

The **Permissions** page in EnviousWispr settings always shows the current status of each one. The same page also has the **Privacy** switches for usage data and crash reports. Those are EnviousWispr settings, not macOS permissions. See [_What Data Is Collected_](/help/what-data-is-collected/).

### EnviousWispr can't hear me: allow the microphone

This permission lets EnviousWispr hear your voice while you dictate. Setup asks for it. If you skipped the prompt, ask again from EnviousWispr:

1. Open **Settings** > **Permissions**.
2. Under **Microphone**, click **Request Access**. If you already said no, this button opens System Settings for you.
3. In **System Settings** > **Privacy & Security** > **Microphone**, switch EnviousWispr on.

You will know it worked when you hold your keybind and the meter on the recording bar moves as you speak. If it still stays flat, see [_Empty or Missing Transcription_](/help/empty-or-missing-transcription/).

### Text is not pasting: allow Accessibility

This permission lets EnviousWispr place the finished text directly into the app you are working in. Setup offers a **Grant** button for it. Otherwise:

1. Open **System Settings** > **Privacy & Security** > **Accessibility**.
2. Click **+** and add EnviousWispr from your Applications folder.
3. Make sure the switch beside it is on.

You will know it worked when your next dictation lands in the text box on its own.

Dictation still works without this permission. EnviousWispr copies your text to the clipboard instead and tells you it has done so, and you paste it yourself with Cmd+V. If the switch is on but nothing pastes, see [_Accessibility Permission Not Working_](/help/accessibility-permission-not-working/).

### macOS asks if EnviousWispr can control System Events

This is the Automation permission. It is a backup, requested only when the usual ways of pasting fail inside a particular app. Click **OK** to allow it. To change your answer later, open **System Settings** > **Privacy & Security** > **Automation**.

Declining is fine, because most apps never need it.

### Does my keybind need a permission?

No. The key you hold to record works everywhere on its own. Microphone lets EnviousWispr hear you, and Accessibility and Automation let it deliver your text.
