---
title: "First Word Gets Cut Off"
description: "Why the start of a dictation can go missing, and how to stop it."
category: "troubleshooting"
section: "Transcription Issues"
order: 4
keywords: ["first word", "cut off", "clipped", "missing the beginning", "loses the start", "chops the first word", "beginning missing"]
updated: 2026-08-05
---
EnviousWispr is a free dictation app for macOS. When the start of your speech goes missing, it is because the microphone was still waking up as you began to talk.

While the microphone is still awake from a recent dictation, EnviousWispr keeps the half second of audio from immediately before you pressed the key, so an early start is captured anyway. On a cold start there is no earlier audio to keep, and the first word or two can be lost.

### Keep the microphone awake for longer

Open EnviousWispr's settings, go to **Microphone**, and find **Microphone Readiness**:

- **Off.** The microphone shuts down straight away. Lowest power use, slowest start, and no earlier audio kept.
- **10 sec, 30 sec, 60 sec.** Stays ready for that long after each dictation. It arrives set to 30 seconds.
- **Always.** Keeps the microphone ready all the time. The macOS microphone indicator may stay visible, and power use may go up.

### When a word can still go missing

- Your first dictation after opening the app.
- The first one after Microphone Readiness has run out.
- The first one after connecting AirPods or another Bluetooth headset, which takes a moment to switch into microphone mode.

### What to do

- Pause for a beat after pressing the key, before you speak.
- Set Microphone Readiness to **60 sec** or **Always**.
- Use push-to-talk. Holding the key down starts waking the microphone while you are still drawing breath.

You will know it is fixed when your next few dictations open with the word you meant to say.
