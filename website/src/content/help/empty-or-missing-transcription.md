---
title: "Empty or Missing Transcription"
description: "What to check when you finish a recording and no text appears."
category: "troubleshooting"
section: "Transcription Issues"
order: 3
keywords: ["nothing happens", "no text", "empty", "microphone not working", "mic not working", "not hearing me", "no output", "blank", "nothing appears", "not transcribing", "not working at all", "silent", "no sound", "meter is flat", "cant hear me"]
related: ["choosing-your-microphone", "granting-permissions-microphone-accessibility-and-automation"]
updated: 2026-09-29
deflection: "show_but_always_send"
---
When a recording finishes and no text appears, something between your microphone and the speech model did not deliver. Work through these checks in order, from the most common cause to the least.

### Microphone not working: check that EnviousWispr can hear you

Watch the recording pill on screen while you talk. Its meter moves with your voice, and on a Mac that can show them, your words appear in the pill as you speak. If the meter stays flat and no words appear, your microphone is not reaching the app. Check the microphone permission under **Settings** > **Permissions**, any hardware mute switch, and the selected microphone under **Settings** > **Microphone**.

### Allow the microphone

macOS requires explicit permission for an app to use your microphone. Open **System Settings** > **Privacy & Security** > **Microphone**. EnviousWispr should be in the list with its switch on.

If EnviousWispr is not in the list, macOS has not been asked yet. Open **Settings** > **Permissions** in EnviousWispr and click **Request Access** under **Microphone**. macOS then asks you to allow access. See [_Granting Permissions_](/help/granting-permissions-microphone-accessibility-and-automation/).

### Check for a hardware mute

A physical mute switch stops your voice reaching the app even when everything else is set up correctly. Check the microphone itself, the cable, and any switch on a desk stand. Many headsets have a mute switch on the earcup or a button partway down the cable. A muted microphone still records, but it records only silence.

### Pick the right microphone

EnviousWispr needs to listen to the device you are actually speaking into. Open EnviousWispr settings and go to **Microphone**. When it is set to **Auto**, EnviousWispr records from whatever input your Mac is using, which may not be the device at your mouth. Pick a specific device from the list to remove the doubt.

If your Mac's default input is a virtual device, such as one installed by Krisp, Loopback, BlackHole, an aggregate device or a meeting app, **Auto** skips it and records from a real microphone, because a virtual device delivers only silence. A virtual device is still used when it is the only input on your Mac.

If you record through an audio interface with more than one input, such as a Focusrite Scarlett, also check the **Mic is on** control next to the device picker. EnviousWispr listens to Input 1 unless you pick another, and a microphone plugged into Input 2 records silence until you do. See [_Choosing Your Microphone_](/help/choosing-your-microphone/).

### Wait for the speech model to finish downloading

The app downloads its speech model on first launch. Until that download finishes, there is nothing to transcribe your voice with. Progress is shown on screen. If the speech model was not ready when you finished speaking, your recording is kept and given another go rather than lost.

### Recording was too short

Very brief audio does not give the speech model enough to work with. A recording of well under a second may come back empty. Hold the keybind a moment longer, and pause for a beat before you start speaking.

### Speaking quietly or far from the microphone

Quiet audio can register as background noise rather than speech. Speaking softly or sitting far from the microphone is a common reason a recording comes back looking silent. Move closer, or use a headset microphone.
