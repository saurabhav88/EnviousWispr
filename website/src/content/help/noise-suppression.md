---
title: "Noise Suppression"
description: "There is no noise suppression setting, and what to do about a noisy room."
category: "audio-and-microphone"
section: "Audio Processing"
order: 3
keywords: ["noise", "background noise", "noisy room", "cafe", "fan", "noise cancelling", "suppression", "echo"]
updated: 2026-08-06
---
EnviousWispr has no noise suppression setting. It records your microphone as it is and lets the speech model handle the audio directly.

### Why noise suppression was removed

Running the audio through a suppression filter before transcription hurt accuracy more than it helped, and it added a noticeable delay to every recording. The setting was removed in version 2.0.2, and switched off automatically when you updated.

### How to manage background noise

If sound around you is hurting your accuracy, change your physical setup rather than looking for a software filter. Move closer to your microphone, or switch to a headset microphone. You can test any change by dictating the same sentence both ways and comparing the results in **History**.
