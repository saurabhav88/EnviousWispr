---
title: "Stop Recording Automatically When You Stop Talking"
description: "Having a recording end by itself once you stop talking, and how to fix it stopping too early or too late."
category: "audio-and-microphone"
section: "Audio Processing"
order: 4
keywords: ["auto stop", "stops on silence", "stops too early", "cuts me off", "pause", "silence", "vad", "keeps going after i stop", "waits too long", "voice activity detection", "stop recording on silence", "pause duration", "stops mid sentence"]
related: ["hands-free-mode-long-dictation", "first-word-gets-cut-off"]
updated: 2026-11-05
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

EnviousWispr identifies speech so it can trim silence before a batch transcription. Fast can remove gaps between speech; All Languages can trim the beginning and end. When trimming would remove too much or has no usable speech range, the app can use the full recording instead. Faster Transcription processes audio while you speak, so it does not use the same trimming path.

This trimming happens whether or not auto-stop is switched on. It runs entirely on your Mac and needs no setup. It works from a copy of your audio with low rumble (fans, engines, air conditioners) taken out. That rumble filter is used only to detect speech. It is not applied to the audio the speech engine transcribes.

If a noisy room is the problem, read [_Noise Suppression_](/help/noise-suppression/).
