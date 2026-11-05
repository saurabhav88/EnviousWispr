---
title: "Noise Suppression"
description: "There is no noise suppression setting, and what to do when a noisy room hurts your dictation."
category: "audio-and-microphone"
section: "Audio Processing"
order: 3
keywords: ["noise", "background noise", "noisy room", "cafe", "fan", "noise cancelling", "suppression", "echo", "inaccurate in noisy room", "air conditioner", "loud room"]
related: ["voice-activity-detection-and-auto-stop"]
updated: 2026-11-05
deflection: "show_but_always_send"
---
EnviousWispr has no noise suppression setting. It does not remove background noise from the audio your speech engine transcribes. Speech detection can still trim silence on some transcription paths; see [how silence trimming works](/help/voice-activity-detection-and-auto-stop/#silence-is-cut-out-of-my-dictation). If background noise hurts your accuracy, change your physical setup.

### Dictation is inaccurate in a noisy room

EnviousWispr has no noise suppression setting, so change what the microphone hears:

1. Move closer to your microphone.
2. Or switch to a headset microphone, which sits close to your mouth.
3. Dictate the same sentence both ways and compare the results in **History**.

### Is there a way to turn on noise suppression?

No. An older version had a noise suppression setting. It was removed because filtering the audio before transcription hurt accuracy more than it helped, and it added a noticeable delay to every recording. Nothing needs switching off after an update.

### Does EnviousWispr filter out fan or air conditioner rumble?

Only for one job. Speech detection works from a copy of your audio with low rumble reduced. That filter is not applied to the audio your speech engine transcribes. Read [_Stop Recording Automatically When You Stop Talking_](/help/voice-activity-detection-and-auto-stop/) for how trimming differs between transcription paths.
