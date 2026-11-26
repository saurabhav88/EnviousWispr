---
title: "Model Downloads and Management"
description: "How the speech models are downloaded, and how to free the memory and disk they use."
category: "speech-engines"
section: "Transcription"
order: 3
keywords: ["download model", "model download", "stuck downloading", "download failed", "try again", "resume download", "how big", "disk space", "gb", "storage", "redownload", "model files", "where are the models", "unload model", "free memory", "remove model"]
related: ["uninstalling-enviouswispr"]
updated: 2026-11-05
deflection: "can_resolve"
---
EnviousWispr keeps its speech models on your own Mac rather than on a server, which is what lets your audio stay on the device. The trade is a download the first time and some disk space to manage afterwards.

Each download is checked before it is used, so a broken or half-finished file is never loaded.

### How big are the speech model downloads?

- **Fast engine (Parakeet Ultra).** EnviousWispr downloads it for you during setup, and you watch the progress as it goes. It is about 632 MB.
- **All Languages engine (Whisper).** EnviousWispr does not download it for you. If you switch to it, go to **Dictation Settings** > **Engine**, click **Change**, choose **All Languages**, then click **Set up model**. It is about 886 MB.
- **If you used All Languages before.** Older versions ran All Languages on WhisperKit with a larger model. If All Languages was your engine when you updated to the current version, EnviousWispr downloads the new model by itself and deletes the old one it had downloaded. Until the download finishes, a recording tells you the model is not downloaded yet. If you cancel the download, start it again under **Dictation Settings** > **Engine**.

### A model download is stuck or failed

EnviousWispr retries some temporary network problems by itself. Anything else stops and gives you a button.

1. **Open settings.** Go to **Dictation Settings** > **Engine**.
2. **Find the download.** The download status and its buttons show under **Transcription Engine**, beside the summary of the engine you selected.
3. **Use the button.** Click **Try Again** after a failure, or **Resume** after a pause. **Cancel** stops a download that is running.

### AI polish download in the menu bar

While your AI polish model downloads after setup, the EnviousWispr menu shows **AI polish downloading · NN%**. After setup, once the download finishes and the model is ready, EnviousWispr can show **AI polish download complete** once.

The download continues only while EnviousWispr is open. If you quit before it finishes, the download is paused and its progress is kept. The menu then shows **AI polish download paused · Resume**; click it to continue from where it stopped.

### Other downloads

The [Self-Learning Dictionary](/help/self-learning-dictionary/) has models of its own, downloaded after setup: one that spots your corrections, and a word check that uses the words you taught it. That article lists their sizes. **Settings** > **Dictionary** > **Learn from...** shows whether each is downloading, ready or needs a retry.

[EnviousMeet](/help/enviousmeet-record-a-meeting/) downloads **Speaker labels** in two parts of about 199 MB each: one for live speaker labels and one for finished calls. Finishing EnviousMeet setup starts the download. Its **Download**, **Cancel** and **Remove** buttons are on the **Models** tab of the **EnviousMeet** page.

### Free up memory

The speech model stays in your Mac's memory between dictations, so there is nothing to load next time. To get the memory back, go to **Dictation Settings** > **Engine** and change **Unload model after**.

It is set to **Never** by default, so the model stays loaded. The other choices unload it after 2, 5, 10 or 15 minutes or 1 hour of not being used, or **Immediately** after every recording. Each one costs a short wait the next time you dictate.

The on-Mac AI polish models, EG-1 and S1-mini, have their own choice: **Unload polish model after** in **Settings** > **AI Polish**. It is also **Never** by default. Your next dictation loads the model again, so the first one may take a moment longer.

### Free up disk space

You can remove local models you no longer need and download them again later.

- **Remove a speech engine.** Open **Dictation Settings** > **Engine**, click **Change**, and click **Remove** on the Parakeet or Whisper card. The same **Remove** is on **EnviousMeet** > **Models**. You can remove either engine, including the one you use; removing the engine you dictate or record meetings with asks you first. A removed engine never downloads again on its own: click **Set up model** on its card to bring it back. If a removal stops part-way, the card offers **Remove leftover files**.
- **Remove the Universal preview model.** Open **Dictation Settings** > **Live Preview**, click **Change**, and click **Remove** on the Universal card. Choosing Universal again downloads it again.
- **Remove an older WhisperKit copy.** Some older versions left a copy of the old All Languages model in a folder other apps share. [Uninstalling EnviousWispr](/help/uninstalling-enviouswispr/) shows how to find and remove it.
- **Remove an EG-1 size.** EG-1 is the polish model EnviousWispr built, in three sizes: EG-1, EG-1 Mini and EG-1 Micro. Open **AI Polish**, and click **Remove** on the card of the size you want to remove. Each installed size has its own **Remove**, so you can keep one size and remove another. If an upgrade of EG-1 was paused, its card shows **Resume upgrade** or **Finish upgrade** instead.
- **Remove S1-mini.** S1-mini is the small polish model made by Superwhisper. Its card on the **AI Polish** page has a **Remove** button once it is installed and ready.
- **Remove Ollama models.** Local Ollama models are removed from the same **AI Polish** page. Hosted Ollama models cannot be removed, because there is nothing on your Mac to remove.

### Dictation is slow to start

How quickly a dictation starts is a separate setting, on the **Microphone** tab of **Dictation Settings**. See [First Word Gets Cut Off](/help/first-word-gets-cut-off/).
