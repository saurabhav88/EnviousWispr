---
title: "Model Downloads and Management"
description: "How the speech models are downloaded, and how to free the memory and disk they use."
category: "speech-engines"
section: "Transcription"
order: 3
keywords: ["download model", "model download", "stuck downloading", "how big", "disk space", "gb", "storage", "redownload", "model files", "where are the models"]
related: ["uninstalling-enviouswispr"]
updated: 2026-08-05
---
Parakeet, the engine you start with, is downloaded for you during setup. You see the progress. It is about 480 MB.

WhisperKit is not downloaded for you. If you switch to it, open Settings, go to **Transcription**, and click **Download WhisperKit Model**. It is about 1.5 GB.

Each download is checked before it is used, so a broken or half-finished file is never loaded.

### If a download fails

EnviousWispr retries some temporary network problems by itself. Anything else stops and offers you a button to try again.

### Freeing up memory

The model stays in memory between dictations, so there is nothing to load next time. If you would rather have the memory back, open Settings, go to **Transcription**, and change **Unload model after**.

It starts on **Never**, so the model stays loaded. The other choices unload it after 2, 5, 10, 15 or 60 minutes of not being used, or right after every recording. Each one costs you a short wait next time.

### Freeing up disk space

For WhisperKit, open **Transcription** and use **Remove Model**. For EG-1, open **AI Polish** and use the remove button there. Ollama models are removed from the same AI Polish page.

You can download any of them again later.

### The other speed setting

How quickly a dictation _starts_ is a different setting, under **Microphone**. See [[_First Word Gets Cut Off_](/help/first-word-gets-cut-off/)](/help/first-word-gets-cut-off/).
