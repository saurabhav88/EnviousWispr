---
title: "First Word Gets Cut Off"
description: "Why the start of a dictation can go missing, and how to stop it."
category: "troubleshooting"
section: "Transcription Issues"
order: 4
keywords: ["first word", "cut off", "clipped", "missing the beginning", "loses the start", "chops the first word", "beginning missing"]
updated: 2026-08-05
---
While the microphone is still awake from a recent dictation, EnviousWispr keeps the half second of audio before you press the key, so the start of your speech is captured even if you begin talking early. On a cold start there is no earlier audio to keep.

### Keeping the microphone awake for longer

Open Settings, go to **Microphone**, and look at **Microphone Readiness**:

- **Off.** The microphone shuts down straight away. Lowest power use, slowest start, and no earlier audio kept.
- **10 sec, 30 sec, 60 sec.** Stays ready for that long. It starts at 30 seconds.
- **Always.** Keeps the microphone ready. The macOS microphone indicator may stay visible, and power use may increase.

### When a word can still go missing

- Your first dictation after opening the app.
- The first one after Microphone Readiness has run out.
- The first one after connecting AirPods or another Bluetooth headset, which takes a moment to switch into microphone mode.

### What to do

- Pause for a beat after pressing the key, before you speak.
- Set Microphone Readiness to **60 sec** or **Always**.
- Use push-to-talk. Holding the key starts waking the microphone before you speak.
