---
title: "Noise Suppression"
description: "There is no noise suppression setting, and what to do when a noisy room hurts your dictation."
category: "audio-and-microphone"
section: "Audio Processing"
order: 3
keywords: ["noise", "background noise", "noisy room", "cafe", "fan", "noise cancelling", "suppression", "echo", "inaccurate in noisy room", "air conditioner", "loud room"]
related: ["voice-activity-detection-and-auto-stop"]
updated: 2026-09-29
deflection: "show_but_always_send"
---
EnviousWispr has no noise suppression setting. It records your microphone as it is and gives that audio straight to the speech model. If background noise hurts your accuracy, change your physical setup.

### Dictation is inaccurate in a noisy room

EnviousWispr has no noise suppression setting, so change what the microphone hears:

1. Move closer to your microphone.
2. Or switch to a headset microphone, which sits close to your mouth.
3. Dictate the same sentence both ways and compare the results in **History**.

### Is there a way to turn on noise suppression?

No. An older version had a noise suppression setting. It was removed because filtering the audio before transcription hurt accuracy more than it helped, and it added a noticeable delay to every recording. Nothing needs switching off after an update.

### Does EnviousWispr filter out fan or air conditioner rumble?

Only for one job. The step that finds where you were talking, so silence can be trimmed, works from a copy of your audio with the low rumble taken out. That is most of what a fan, an engine or an air conditioner produces. Your recording and the audio the speech engine transcribes are untouched. Read [_Stop Recording Automatically When You Stop Talking_](/help/voice-activity-detection-and-auto-stop/).
