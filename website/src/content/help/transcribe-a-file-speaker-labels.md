---
title: "Speaker labels in Transcribe a File"
description: "How Transcribe a File tells speakers apart, how to rename them, and what Both and Not fully polished mean."
category: "features"
section: "Transcribe a File"
order: 9
keywords: ["speaker labels", "speakers", "who said what", "Speaker 1", "Speaker 2", "rename speaker", "Both", "Not fully polished", "transcribe a file", "diarization", "two people", "interview", "meeting recording", "podcast"]
related: ["transcribe-a-file", "transcript-history", "choosing-a-speech-engine-parakeet-vs-whisperkit", "ai-polish-and-cloud-data"]
updated: 2026-09-13
---
When you put a recording with more than one voice through [Transcribe a File](/help/transcribe-a-file/) and the app can tell the voices apart and match the words to them, the finished transcript comes back as turns, and each turn is labelled with the person who said it. The labels start as **Speaker 1**, **Speaker 2** and so on, in the order the voices first appear. A turn also shows the time in the recording where it starts, when the app has a time for it. A recording with one voice comes back as plain text with no labels.

The speakers are found on your Mac, by the same app, before the cleanup runs. Nothing about the recording is sent anywhere to work out who is talking.

### Renaming a speaker

The numbers are placeholders. Give each one a real name and the whole transcript updates.

- **Click the name.** On the Done step, click **Speaker 1** on any turn. A small box opens where you can type.
- **Type the new name and press Return.** Every turn by that speaker now shows the name you typed. Press Escape to leave the name as it was.
- **It stays renamed.** The names are saved with the transcript, so the same names show when you open it later in [History](/help/transcript-history/). You can rename there too.

### What "Both" means

**Both** marks words the app left unassigned to a single speaker after grouping nearby words. This can happen when word timings are missing or do not line up with the speaker stretches it found. A Both turn has no number and cannot be renamed.

Several Both turns mean several stretches remained unassigned to a single speaker. The label does not explain why. The words are still all there and still in order.

### What "Not fully polished" means

Transcribe a File cleans the transcript one speaker turn at a time: it removes filler, fixes punctuation and capitalisation, and leaves each person's words under their own name. When the cleanup could not be completed for one turn, that turn keeps the original transcription, the words as the speech engine heard them, and shows **Not fully polished** beneath it. The turns around it are cleaned as usual.

To run the cleanup again:

- **Click Change next to the polisher's name.** It is in the row of chips above the transcript, for example "Polished by EG-1 · Change". You land on the polisher step.
- **Keep or change the polisher, then click Continue.** You land on the Review step.
- **Click Clean it again.** Only the cleanup runs. The recording is not read again, and the speaker labels and any names you gave them are kept.

If the turn still shows **Not fully polished**, its cleanup did not complete. You can choose a different polisher on the polisher step and clean it again.

### What Stop keeps

You can press **Stop** at any point while the file is being worked on.

- **Stop while the file is still being transcribed.** Nothing is kept, because no words exist yet. Choose the file again to start over.
- **Stop while the speakers are being found.** You get the transcript as one block of text, with no labels. It is saved to History, and the page offers **Try again** to find the speakers on the kept audio.
- **Stop while the cleanup is running.** You keep the speaker labels and every turn, and every turn shows its original transcription with **Not fully polished** beneath it, including the turns the cleanup had already reached. The page header reads **Stopped**, and the labelled transcript is saved to History. **Clean it again** runs the cleanup over all of them.

Once the words exist, Stop never throws them away. What was found is what you get.

### Where the recording goes

The recording never leaves your Mac. Transcription, finding the speakers and any on-device cleanup all run locally. The sentence at the bottom of the page changes with the step and with the polisher you chose.

If you chose a cloud polisher (your own OpenAI, Gemini or Claude key, or a hosted Ollama model), the text of the transcript goes to that provider for the cleanup and nothing else does. The page says so while the file is running and again when it is done: "Your audio stayed on this Mac. Only the text went to OpenAI, under your own key." How that works and what each provider receives is in [AI polish and cloud data](/help/ai-polish-and-cloud-data/).

### Fast versus All Languages

Both speech engines give you speaker labels. The labels are built from the time each word was spoken, which both engines report.

| Engine | Speaker labels | Note |
|---|---|---|
| **Fast** | Yes | Recommended. Its language count is compared with All Languages in [choosing a speech engine](/help/choosing-a-speech-engine-parakeet-vs-whisperkit/). |
| **All Languages** | Yes | Every language the engine supports, with one exception below. |

**Text written without spaces between words** (for example Chinese, Japanese and Thai) can prevent the app from matching the transcript's words to the engine's timings. When usable timings are unavailable, speaker labels are unavailable too: the transcript still comes back complete, as one block, and the page shows "Couldn't add speaker labels to this recording." without a Try again button, because trying again would give the same result.

### If the labels did not appear

- **"Couldn't add speaker labels to this recording."** The app could not tell the voices apart, or could not attach the words it heard to them. Click **Try again** if it is offered. It is offered only while the app still holds what it needs to retry and no cleanup is running; when a retry could not change the result (see the language note above) it is not offered. Your transcript is complete either way.
- **"Speaker detection didn't finish for this recording."** No speaker result was saved for this transcript. Click **Try again** if it is offered; it runs the speaker step on the kept audio without reading the file again. If it is not offered (for example after the app was quit), choose the file again.
- **No labels and no message.** A missing message on its own does not say how many voices the app heard. A recording it heard as one voice shows no labels and no message.
