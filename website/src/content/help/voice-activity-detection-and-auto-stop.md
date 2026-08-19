---
title: "Voice Activity Detection and Auto-Stop"
description: "Having a recording end by itself once you stop talking."
category: "audio-and-microphone"
section: "Audio Processing"
order: 4
keywords: ["auto stop", "stops on silence", "stops too early", "cuts me off", "pause", "silence", "vad", "keeps going after i stop", "waits too long"]
related: ["hands-free-mode-long-dictation", "first-word-gets-cut-off"]
updated: 2026-08-06
---
EnviousWispr can end a recording by itself once you stop talking, so you do not have to reach for your keybind again. This is off by default and has to be switched on before it does anything.

### Turning on auto-stop

Switch the feature on in settings to let EnviousWispr work out when you have finished speaking.

1. Go to **Settings** \> **Transcription**.
2. Switch on **Stop recording on silence**.
3. Use the slider to set how long a pause has to be, anywhere from half a second to three seconds. It arrives set to one and a half seconds.

A pause shorter than your setting is ignored, while a longer silence ends the recording. At the half-second setting, an ordinary pause for thought is often enough to stop it.

### Choosing a pause length

Different pause lengths suit different speaking habits.

| Setting | What it does |
| :--- | :--- |
| **Half a second** | Ends recordings quickly, but risks cutting you off mid-thought. |
| **One and a half seconds** | A reliable starting point for normal speech. |
| **Up to three seconds** | Suits speakers who pause often in the middle of a sentence. |

### Automatic trimming

Before your speech is transcribed, EnviousWispr looks for the parts of the recording where you were talking and sends only those to the engine. In a quiet or normal room that comes to the same thing as removing the silence at the start and the end. It is a stronger claim than that, though: anything the app does not recognise as speech can be left out, wherever it falls in the recording.

That recognition step now works from a copy of your audio with the low rumble taken out, which is most of what a fan, an engine or an air conditioner produces. Your recording and the audio your engine transcribes are untouched. Trimming happens whether or not you have auto-stop switched on, runs entirely on your Mac, and needs no configuration.

### If it stops at the wrong time

Move the slider. If EnviousWispr keeps ending the recording while you are still thinking, raise the setting to three seconds, or switch the feature off and end every recording yourself.
