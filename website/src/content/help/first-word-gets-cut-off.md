---
title: "First Word Gets Cut Off"
description: "Why the start of a dictation can go missing, and how to stop it."
category: "troubleshooting"
section: "Transcription Issues"
order: 4
keywords: ["first word", "cut off", "clipped", "missing the beginning", "loses the start", "chops the first word", "beginning missing", "first word missing", "start of sentence missing", "microphone readiness", "airpods first word"]
updated: 2026-09-29
deflection: "can_resolve"
---
When the start of your speech goes missing, the microphone was still waking up as you began to talk. Two fixes work: pause briefly after pressing your keybind, or keep the microphone awake for longer.

### The first word is missing from my dictation

1. **Pause briefly.** Wait a beat after pressing your keybind before you begin to speak.
2. **Keep the microphone awake for longer.** Go to **Settings** \> **Microphone** and set **Microphone readiness** to **60 sec** or **Always**.

You will know it worked when your next few dictations open with the exact word you meant to say.

### What Microphone readiness does

**Microphone readiness** sets how long the microphone stays active after each dictation. While it is active, EnviousWispr also keeps the half second of audio from right before you pressed the key, so an early start is still captured. Once the microphone has shut down, there is no earlier audio to keep, and the first word or two can be lost.

- **Off.** The microphone shuts down straight away. This gives the lowest power use, the slowest start, and no earlier audio kept.
- **10 sec, 30 sec, 60 sec.** The microphone stays ready for that long after each dictation. The default is 30 sec.
- **Always.** The microphone stays ready all the time. The macOS microphone indicator may stay visible in your menu bar, and power use may go up.

### When a word can still go missing

Some situations need the microphone to wake from a completely inactive state, and those can still cost you a word:

- Your first dictation after opening the app.
- The first dictation after your **Microphone readiness** time has run out.
- The first dictation after connecting AirPods or another Bluetooth headset, which takes a moment to switch into microphone mode. Read [_Bluetooth and AirPods_](/help/bluetooth-and-airpods/).
