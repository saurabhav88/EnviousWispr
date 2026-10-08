---
title: "Model Downloads and Management"
description: "How the speech models are downloaded, and how to free the memory and disk they use."
category: "speech-engines"
section: "Transcription"
order: 3
keywords: ["download model", "model download", "stuck downloading", "download failed", "try again", "resume download", "how big", "disk space", "gb", "storage", "redownload", "model files", "where are the models", "unload model", "free memory", "remove model"]
related: ["uninstalling-enviouswispr"]
updated: 2026-09-29
deflection: "can_resolve"
---
EnviousWispr keeps its speech models on your own Mac rather than on a server, which is what lets your audio stay on the device. The trade is a download the first time and some disk space to manage afterwards.

Each download is checked before it is used, so a broken or half-finished file is never loaded.

### How big are the speech model downloads?

- **Fast engine (Parakeet).** EnviousWispr downloads it for you during setup, and you watch the progress as it goes. It is about 480 MB.
- **All Languages engine (WhisperKit).** EnviousWispr does not download it for you. If you switch to it, go to **Dictation Settings** > **Engine**, click **Change**, choose **All Languages**, then click **Set up model**. It is about 1.5 GB.

### A model download is stuck or failed

EnviousWispr retries some temporary network problems by itself. Anything else stops and gives you a button.

1. **Open settings.** Go to **Dictation Settings** > **Engine**.
2. **Find the download.** The download status and its buttons show under **Transcription Engine**, beside the summary of the engine you selected.
3. **Use the button.** Click **Try Again** after a failure, or **Resume** after a pause. **Cancel** stops a download that is running.

### Other downloads

The [Self-Learning Dictionary](/help/self-learning-dictionary/) has models of its own, downloaded after setup: one that spots your corrections, and a word check that uses the words you taught it. That article lists their sizes. **Settings** > **Dictionary** > **Learn from...** shows whether each is downloading, ready or needs a retry.

### Free up memory

The speech model stays in your Mac's memory between dictations, so there is nothing to load next time. To get the memory back, go to **Dictation Settings** > **Engine** and change **Unload model after**.

It is set to **Never** by default, so the model stays loaded. The other choices unload it after 2, 5, 10 or 15 minutes or 1 hour of not being used, or **Immediately** after every recording. Each one costs a short wait the next time you dictate.

### Free up disk space

You can remove local models you no longer need and download them again later.

- **Remove a WhisperKit model.** Open **Dictation Settings** > **Engine** and click **Remove Model**.
- **Remove EG-1.** EG-1 is the polish model EnviousWispr built. Open **AI Polish** and use the remove button there. The button appears once EG-1 is installed and ready. If a newer EG-1 is waiting to install, that row offers the upgrade instead, and the remove button comes back once the upgrade finishes.
- **Remove S1-mini.** S1-mini is the small polish model made by Superwhisper. It has the same card on the **AI Polish** page as EG-1, with the same remove button once it is installed and ready.
- **Remove Ollama models.** Local Ollama models are removed from the same **AI Polish** page. Hosted Ollama models cannot be removed, because there is nothing on your Mac to remove.

### Dictation is slow to start

How quickly a dictation starts is a separate setting, on the **Microphone** tab of **Dictation Settings**. See [First Word Gets Cut Off](/help/first-word-gets-cut-off/).
