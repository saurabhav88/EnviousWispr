---
title: "Stop Recording Automatically When You Stop Talking"
description: "Having a recording end by itself once you stop talking, and how to fix it stopping too early or too late."
category: "audio-and-microphone"
section: "Audio Processing"
order: 4
keywords: ["auto stop", "stops on silence", "stops too early", "cuts me off", "pause", "silence", "vad", "keeps going after i stop", "waits too long", "voice activity detection", "stop recording on silence", "pause duration", "stops mid sentence"]
related: ["hands-free-mode-long-dictation", "first-word-gets-cut-off"]
updated: 2026-10-17
deflection: "show_but_always_send"
---
EnviousWispr can end a recording by itself once you stop talking, so you do not have to press your keybind again. This is off by default. Switch it on first.

### Turn on auto-stop

1. Go to **Dictation Settings** \> **Engine**.
2. Under **Applies to both engines**, switch on **Stop recording on silence**.
3. Use the **Pause duration** slider to set how long a pause has to be, from half a second to three seconds. The default is one and a half seconds.

A pause shorter than your setting is ignored. A longer silence ends the recording.

### Choose a pause length

| Setting | What it does |
| :--- | :--- |
| **Half a second** | Ends recordings quickly, but an ordinary pause for thought is often enough to stop it. |
| **One and a half seconds** | A reliable starting point for normal speech. |
| **Up to three seconds** | Suits speakers who pause often in the middle of a sentence. |

### Recording stops while I am still thinking

Raise **Pause duration** on the **Engine** tab of **Dictation Settings**, up to three seconds. Or switch **Stop recording on silence** off and end every recording yourself with your keybind.

### Recording does not stop by itself

Check that **Stop recording on silence** is switched on. It is off by default. If it is on and recordings still run long, lower **Pause duration**, or end the recording with your keybind.

### Silence is cut out of my dictation

Before your speech is transcribed, EnviousWispr finds the parts of the recording where you were talking. What happens next depends on your engine:

- **Fast (Parakeet).** Only the parts where you were talking go to the engine. In a quiet or normal room that comes to the same thing as removing the silence at the start and the end. Anything the app does not recognise as speech can be left out, wherever it falls in the recording. With **Faster Transcription** on, the engine transcribes your audio as it arrives instead, and the trimmed audio is used only if that comes back empty or fails.
- **All Languages (Whisper).** The engine receives the whole recording and is told where your speech is.

If trimming would leave too little audio, or could cut a soft first word from a short dictation, EnviousWispr keeps the original audio instead.

This happens whether or not auto-stop is switched on. It runs entirely on your Mac and needs no setup. The step that finds your speech works from a copy of your audio with low rumble (fans, engines, air conditioners) taken out. That filter is not applied to your recording or to the audio the engine transcribes.

If a noisy room is the problem, read [_Noise Suppression_](/help/noise-suppression/).
