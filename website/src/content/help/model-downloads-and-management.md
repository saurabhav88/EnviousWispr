---
title: "Model Downloads and Management"
description: "How the speech models are downloaded, and how to free the memory and disk they use."
category: "speech-engines"
section: "Transcription"
order: 3
keywords: ["download model", "model download", "stuck downloading", "how big", "disk space", "gb", "storage", "redownload", "model files", "where are the models"]
related: ["uninstalling-enviouswispr"]
updated: 2026-08-06
---
EnviousWispr keeps its speech models on your own Mac rather than on a server, which is what lets your audio stay on the device. The trade for that is a download the first time and some disk space to manage afterwards.

### The two downloads

**Parakeet.** This engine is downloaded for you during setup, and you watch the progress as it goes. It is about 480 MB.

**WhisperKit.** This engine is not downloaded for you. If you switch to it, go to **Settings** \> **Transcription** and click **Download WhisperKit Model**. It is about 1.5 GB.

Each download is checked before it is used, so a broken or half-finished file is never loaded.

### If a download fails

EnviousWispr retries some temporary network problems by itself. Anything else stops and gives you a button to try again.

### Freeing up memory

The model stays in your Mac's memory between dictations so there is nothing to load next time. If you would rather have the memory back, go to **Settings** \> **Transcription** and change **Unload model after**.

It arrives set to **Never**, so the model stays loaded. The other choices unload it after 2, 5, 10, 15 or 60 minutes of not being used, or straight after every recording. Each one costs you a short wait the next time you dictate.

### Freeing up disk space

You can remove models you no longer need to recover storage, and you can download any of them again later.

**Remove a WhisperKit model.** Open **Transcription** and use **Remove Model**.

**Remove EG-1.** EG-1 is the polish model EnviousWispr built. Open **AI Polish** and use the remove button there.

**Remove Ollama models.** Ollama models are removed from that same **AI Polish** page.

### The other speed setting

How quickly a dictation starts is a different setting, under **Microphone**. See [_First Word Gets Cut Off_](/help/first-word-gets-cut-off/).
