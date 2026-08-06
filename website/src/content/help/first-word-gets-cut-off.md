---
title: "First Word Gets Cut Off"
description: "Why the start of a dictation can go missing, and how to stop it."
category: "troubleshooting"
section: "Transcription Issues"
order: 4
keywords: ["first word", "cut off", "clipped", "missing the beginning", "loses the start", "chops the first word", "beginning missing"]
updated: 2026-08-06
---
When the start of your speech goes missing, it is because the microphone was still waking up as you began to talk.

While the microphone is still awake from a recent dictation, EnviousWispr keeps the half second of audio from immediately before you pressed the key, so an early start is captured anyway. On a cold start there is no earlier audio to keep, and the first word or two can be lost.

### Keep the microphone awake for longer

You can change how long the microphone stays active between dictations, which is what prevents a cold start. Open EnviousWispr settings, click **Microphone**, and find **Microphone Readiness**:

- **Off.** The microphone shuts down straight away. This setting gives the lowest power use, the slowest start, and no earlier audio kept.
- **10 sec, 30 sec, 60 sec.** The microphone stays ready for that long after each dictation. The app arrives set to 30 seconds.
- **Always.** The microphone stays ready all the time. The macOS microphone indicator may stay visible in your menu bar, and power use may go up.

### When a word can still go missing

Some situations need the microphone to wake from a completely inactive state, and those can still cost you a word:

- Your first dictation after opening the app.
- The first dictation after your Microphone Readiness timer has run out.
- The first dictation after connecting AirPods or another Bluetooth headset, which takes a moment to switch into microphone mode.

### What to do

If your speech keeps cutting off at the beginning, try these adjustments:

- **Pause briefly.** Pause for a beat after pressing your hotkey, before you begin to speak.
- **Change your readiness time.** Set Microphone Readiness to **60 sec** or **Always**.
- **Use push to talk.** Holding the key down starts waking the microphone while you are still drawing breath.

You will know the problem is fixed when your next few dictations open with the exact word you meant to say.
