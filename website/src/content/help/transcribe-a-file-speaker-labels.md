---
title: "Speaker labels in Transcribe a File"
description: "How Transcribe a File tells speakers apart, how to rename them, and what Both and Not fully polished mean."
category: "features"
section: "Transcribe a File"
order: 9
keywords: ["speaker labels", "speakers", "who said what", "Speaker 1", "Speaker 2", "rename speaker", "Both", "Not fully polished", "transcribe a file", "diarization", "two people", "interview", "meeting recording", "podcast", "no speaker labels", "couldn't add speaker labels", "speaker detection didn't finish"]
related: ["transcribe-a-file", "transcript-history", "choosing-a-speech-engine-parakeet-vs-whisperkit", "ai-polish-and-cloud-data"]
updated: 2026-09-29
deflection: "show_but_always_send"
---
When a recording has more than one voice, [Transcribe a File](/help/transcribe-a-file/) labels each turn with the person who said it, if the app can tell the voices apart and match the words to them. The labels start as **Speaker 1**, **Speaker 2** and so on, in the order the voices first appear. A recording with one voice comes back as plain text with no labels.

A turn also shows the time in the recording where it starts, when the app has a time for it and **Times** is on.

The speakers are found on your Mac, by the same app, before the cleanup runs. Nothing about the recording is sent anywhere to work out who is talking.

### How do I rename a speaker?

The numbers are placeholders. Give each one a real name and the whole transcript updates.

1. **Click the name.** On the Done step, click **Speaker 1** on any turn. A small box opens where you can type.
2. **Type the new name and press Return.** Every turn by that speaker now shows the name you typed. Press Escape to leave the name as it was.

The names are saved with the transcript, so the same names show when you open it later in [History](/help/transcript-history/). You can rename there too.

### What does "Both" mean on a turn?

**Both** marks words the app left unassigned to a single speaker after grouping nearby words. This can happen when word timings are missing or do not line up with the speaker stretches it found. A Both turn has no number and cannot be renamed.

Several Both turns mean several stretches remained unassigned to a single speaker. The label does not explain why. The words are still all there and still in order.

### What does "Not fully polished" mean?

Transcribe a File cleans the transcript one speaker turn at a time, so each person's words stay under their own name. First come the automatic fixes: numbers, your custom words, and filler removal when that setting is on. Then the polisher rewrites the turn for punctuation and capitalisation.

**Not fully polished** beneath a turn means the polisher's rewrite did not land on all of that turn. The part it could not complete keeps the words as they stood before the polisher: the transcription with the automatic fixes already applied, but no AI rewrite. A long turn is cleaned in pieces, so a marked turn can hold rewritten pieces beside an unrewritten one. The turns around it are cleaned as usual.

After **Stop**, the label sits on every turn and each shows the original transcription. If a turn still shows the label after a second try, its cleanup did not complete, and you can choose a different polisher and clean it again.

### How do I run the cleanup again?

Running the cleanup again does not read the recording again, and it keeps the speaker labels and any names you gave them.

1. **Click Change next to the polisher's name.** It is in the row of chips above the transcript, for example "Polished by EG-1 · Change". You land on the polisher step.
2. **Keep or change the polisher, complete any setup it asks for, then click Continue.** You land on the Review step.
3. **Click Clean it again.** Only the cleanup runs.

### What does Stop keep?

You can press **Stop** at any point while the file is being worked on.

- **Stop while the file is still being transcribed.** Nothing is kept, because no words exist yet. Choose the file again to start over.
- **Stop while the speakers are being found.** You get the transcript as one block of text, with no labels. It is saved to History, and the page offers **Try again** to find the speakers on the kept audio.
- **Stop while the cleanup is running.** You keep the speaker labels and every turn, and every turn shows its original transcription with **Not fully polished** beneath it, including the turns the cleanup had already reached. The page header reads **Stopped**, and the labelled transcript is saved to History. **Clean it again** runs the cleanup over all of them.

Once the words exist, Stop never throws them away. What was found is what you get.

### Do speaker labels work in every language?

Both speech engines give you speaker labels, because the labels are built from the time each word was spoken, which both engines report. **Fast** is recommended; its language count is compared with **All Languages** in [choosing a speech engine](/help/choosing-a-speech-engine-parakeet-vs-whisperkit/).

There is one exception. Some languages, such as Chinese, Japanese and Thai, are written without spaces between words. For these, the app matches the words to the engine's timings in 30-second stretches. When a stretch does not line up with its text, the words in that stretch get no timings, and the rest of the recording is unaffected.

If no words at all can be timed on a recording with more than one voice, speaker labels are unavailable. The transcript still comes back complete, as one block, and the page shows "Couldn't add speaker labels to this recording." without a Try again button, because trying again would give the same result.

### Why did my speaker labels not appear?

- **"Couldn't add speaker labels to this recording."** The app could not tell the voices apart, or could not attach the words it heard to them. Click **Try again** if it is offered. It is offered only while the app still holds what it needs to retry and no cleanup is running, and not when a retry could not change the result, such as a recording where no words could be timed. Your transcript is complete either way.
- **"Speaker detection didn't finish for this recording."** No speaker result was saved for this transcript. Click **Try again** if it is offered; it runs the speaker step on the kept audio without reading the file again. If it is not offered (for example after the app was quit), choose the file again.
- **No labels and no message.** A missing message on its own does not say how many voices the app heard. A recording it heard as one voice shows no labels and no message.

### Does my recording leave my Mac?

No. Transcription, finding the speakers and any on-device cleanup all run locally. If you chose a cloud polisher (your own OpenAI, Gemini or Claude key, or a hosted Ollama model), only the text of the transcript goes to that provider for the cleanup. The page says so while the file is running and again when it is done: "Your audio stayed on this Mac. Only the text went to OpenAI, under your own key." The full explanation is in [Transcribe a File](/help/transcribe-a-file/) and [AI polish and cloud data](/help/ai-polish-and-cloud-data/).
