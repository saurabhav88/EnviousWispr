---
title: "Empty or Missing Transcription"
description: "What to check when your microphone is not working and no text appears."
category: "troubleshooting"
section: "Transcription Issues"
order: 3
keywords: ["nothing happens", "no text", "empty", "microphone not working", "mic not working", "not hearing me", "no output", "blank", "nothing appears", "not transcribing", "not working at all", "silent", "no sound"]
related: ["choosing-your-microphone", "granting-permissions-microphone-accessibility-and-automation"]
updated: 2026-08-06
---
When a recording finishes and no text appears, something between your microphone and the speech model did not deliver. These checks run from the most common cause to the least, so work through them in order.

### 1. Is the app hearing you?

Watch the recording bar on screen while you talk. Its meter moves with your voice. If the meter stays flat while you speak, your microphone is not reaching the app, and steps 2 to 4 are where to look.

### 2. Check the microphone permission

macOS requires explicit permission for an app to use your microphone. Open **System Settings**, click **Privacy & Security**, and click **Microphone**. EnviousWispr should be in the list with its switch turned on. If the app is not in the list at all, macOS has never been asked for permission. Record once and macOS will prompt you to allow access.

### 3. Check for a hardware mute

A physical mute switch stops your voice reaching the app even when everything else is set up correctly. Check the microphone itself, the cable, and any switch on a desk stand. Many headsets have a mute switch on the earcup or a button partway down the cable. A muted microphone still records, but it records only silence.

### 4. Check the right microphone is selected

EnviousWispr needs to listen to the device you are actually speaking into. Open EnviousWispr settings and go to **Microphone**. When set to Auto, EnviousWispr records from whatever input your Mac is using, which may not be the device at your mouth. Pick a specific device from the list to remove the ambiguity.

### 5. Is the speech model ready?

The app downloads its speech model on first launch. Until that download finishes, there is no model available to transcribe your voice. Progress is shown on screen.

### 6. Was the recording very short?

Very brief audio does not give the speech model enough to work with. A recording of well under a second may come back empty. Hold the keybind a moment longer, and pause for a beat before you start speaking.

### 7. Were you quiet, or far from the microphone?

Quiet audio can register with the speech model as background noise rather than speech. Speaking softly or sitting far from the microphone is a common reason a recording comes back looking silent. Move closer, or use a headset microphone.
