---
title: "Voice Activity Detection and Auto-Stop"
description: "Having a recording end by itself once you stop talking."
category: "audio-and-microphone"
section: "Audio Processing"
order: 4
keywords: ["auto stop", "stops on silence", "stops too early", "cuts me off", "pause", "silence", "vad", "keeps going after i stop", "waits too long"]
related: ["hands-free-mode-long-dictation", "first-word-gets-cut-off"]
updated: 2026-08-05
---
EnviousWispr can end a recording by itself once you stop talking. It is off unless you turn it on.

### Turning it on

1. Open Settings and go to **Transcription**.
2. Switch on **Stop recording on silence**.
3. Use the slider to set how long a pause has to be, between half a second and three seconds. It starts at one and a half.

A pause shorter than your setting is ignored. A longer silence ends the recording. At the half-second setting, an ordinary pause for thought is enough to stop it.

### Choosing a pause length

- **Half a second.** Ends quickly, and will cut you off mid-thought.
- **One and a half seconds.** A good starting point for normal speech.
- **Up to three seconds.** Best if you pause a lot mid-sentence.

### It also trims your recording

Silence at the start and end is removed before your speech is transcribed, whether or not you have auto-stop on. That happens on your Mac and needs no setting.

### If it stops too early or too late

Move the slider. If it keeps stopping while you think, try three seconds, or switch it off and stop recordings yourself.
