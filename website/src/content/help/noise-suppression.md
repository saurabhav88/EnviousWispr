---
title: "Noise Suppression"
description: "There is no noise suppression setting, and what to do about a noisy room."
category: "audio-and-microphone"
section: "Audio Processing"
order: 3
keywords: ["noise", "background noise", "noisy room", "cafe", "fan", "noise cancelling", "suppression", "echo"]
related: ["voice-activity-detection-and-auto-stop"]
updated: 2026-09-05
---
EnviousWispr has no noise suppression setting. It records your microphone as it is and lets the speech model handle the audio directly.

### Why noise suppression was removed

Running the audio through a suppression filter before transcription hurt accuracy more than it helped, and it added a noticeable delay to every recording. The setting was removed in version 2.0.2, and switched off automatically when you updated.

### What the app does do about rumble

The step that finds where you were talking, so silence can be trimmed, works from a copy of your audio with the low rumble taken out, which is most of what a fan, an engine or an air conditioner produces. Your recording and the audio the speech engine transcribes are untouched. Read [_Voice Activity Detection and Auto-Stop_](/help/voice-activity-detection-and-auto-stop/).

### How to manage background noise

If sound around you is hurting your accuracy, change your physical setup rather than looking for a software filter. Move closer to your microphone, or switch to a headset microphone. You can test any change by dictating the same sentence both ways and comparing the results in **History**.
