---
title: "Transcribe a File"
description: "Turn a voice memo, lecture, meeting or video you already have into clean text, on your Mac."
category: "features"
section: "Transcribe a File"
order: 8
keywords: ["transcribe a file", "import audio", "voice memo", "meeting recording", "lecture", "podcast", "mp3", "m4a", "video to text", "transcript", "file transcription", "audio to text"]
related: ["transcribe-a-file-speaker-labels", "transcript-history", "choosing-a-speech-engine-parakeet-vs-whisperkit", "choosing-an-ai-provider-none-apple-intelligence-ollama-openai-gemini", "ai-polish-and-cloud-data"]
updated: 2026-09-13
---
Transcribe a File takes an audio or video file you already have and gives you back clean, readable text. The recording never leaves your Mac. When the recording has more than one voice and the app can tell them apart and match the words to them, the transcript comes back as speaker turns; see [speaker labels](/help/transcribe-a-file-speaker-labels/).

### Opening it

There are two ways in.

- **From the sidebar.** Click the EnviousWispr icon in your menu bar, choose **Settings**, and click **Transcribe a File** in the sidebar.
- **From the menu bar.** Click the EnviousWispr icon and choose **Transcribe a File...**. It sits with the other ways to get words in, above the settings items.

### What files it takes

Click **Choose a file**, or drag a file onto the page. These formats work: **m4a, mp3, wav, aiff, caf, mp4, mov** and **flac**. For a video, only the sound is used.

The Review step estimates the time from the recording's length, so a two-hour recording is a longer wait, not a different process.

If the file cannot be used, the page says why: the file could not be opened, there is no sound in it, or no speech was found in it. If the app is busy with a dictation, an earlier take, or another file, or the engine you picked is not downloaded yet, the message says what to do.

### The six steps

The page walks you through six steps. The bar at the top shows where you are. Until the work starts you can go back to change a choice; after a run you can still go back to the engine and polisher steps, but choosing another file means starting a new transcription.

1. **Upload.** Pick the file.
2. **Transcription.** Pick the speech engine (below).
3. **Polish.** Pick how the text is cleaned up (below).
4. **Review.** Check the file, the engine and the polisher, read the time estimate, and click **Start transcription**.
5. **Working.** One card shows what is happening: **Preparing**, **Transcribing**, **Finding who said what**, then **Cleaning section 3 of 14** with a bar. Once a few sections are done it shows a rough time left, such as "about 3 minutes left". **Stop** is on the card. The footer says "Safe to leave this page": you can move to another page while it works.
6. **Done.** Your transcript, with everything you can do with it (below).

### Choosing the speech engine

Both engines run entirely on this Mac. **This choice also changes the engine your dictation uses**, so pick the one you want for both.

| | **Fast** (recommended) | **All Languages** |
|---|---|---|
| What the card says | "Best for everyday English and European recordings." | "Best for other languages or the toughest audio." |
| Model | Parakeet v3 | Whisper Large v3 Turbo |
| Languages | 25 European | 99+ |
| An hour of audio takes | About 7 seconds | About 2 minutes |

More on the two engines, including how their language counts compare, is in [choosing a speech engine](/help/choosing-a-speech-engine-parakeet-vs-whisperkit/). An engine that is not downloaded yet says so; get it in Transcription settings.

### Choosing the polisher

Two kinds of cleanup run on a file. The automatic fixes run first, whichever polisher you pick, including **None**: numbers and dates are written as figures, your custom words are applied when **Enable Dictionary** is on under **Settings** \> **Dictionary**, and filler words are removed when **Remove filler words** is on in Speech Engine settings (spoken emoji has its own switch there). With a polisher selected, it then rewrites the text for punctuation, capitalisation and flow, and lays out lists. **The polisher you choose here is separate from the one your dictation uses**, so you can clean files with one and dictations with another. When you have made a separate choice for files, a link on the step, **Use dictation's polish settings**, makes files follow your dictation choice again.

| Polisher | Where it runs | What the card says |
|---|---|---|
| **EG-1** | On this Mac | Our best model for cleanup and list-making. On an imported recording it removes about four times more filler than Apple Intelligence. |
| **Apple Intelligence** | On this Mac | Apple's on-device model. Needs macOS 26 or later. |
| **Ollama** | Depends on the model | Any model you run in Ollama. A model downloaded to your Mac sends nothing; a model that runs on Ollama's servers receives the text. The page says which kind your pick is when Ollama reports it. |
| **OpenAI** | Their servers, under your own key | Only the text is sent, never the audio. |
| **Gemini** | Their servers, under your own key | Only the text is sent, never the audio. |
| **Claude** | Their servers, under your own key | Only the text is sent, never the audio. |

If a polisher needs setting up (a key, a download, Ollama not running), the same setup box you see on the AI Polish page appears on this step, and **Continue** waits until it is ready. [Choosing an AI provider](/help/choosing-an-ai-provider-none-apple-intelligence-ollama-openai-gemini/) covers the trade-offs.

### The time estimate

The Review step shows an estimate such as "Ready in about 3 minutes" before you start. It is worked out from the length of your recording: the cleanup is what takes the time, about twelve seconds for every five hundred words, rounded to whole minutes. On the Working step, once a few sections have finished, the card shows a time left measured from how fast they actually went.

### Stopping

Press **Stop** on the Working card at any time. What you keep depends on how far it got: nothing if the words were not transcribed yet; the words with no labels if it was still finding the speakers; every speaker turn, with the original transcription under each name, if it was cleaning. The details are in [speaker labels](/help/transcribe-a-file-speaker-labels/). Once words exist, Stop never throws them away.

### What Done offers

The Done step shows your transcript with a row of chips above it: the word count, the length of the recording, whether it is saved to History, and the polish credit: **Polished by** and the polisher's name, **Partly polished by** when a turn was left unpolished, **No AI polish** when you chose **None**, or **No AI polish applied** when the polisher did not rewrite anything. **Change** next to the credit takes you back to the Polish step; **Clean it again** on the Review step then runs only the cleanup, without reading the file again.

- **Cleaned, Marked up, Original.** Three views of the same transcript, offered once at least one turn has been through the cleanup. **Cleaned** is the text after cleanup, with the automatic fixes and, where the polisher rewrote a turn, its rewrite. **Original** is the original transcription, the words as the speech engine heard them. **Marked up** shows the original with the cleanup drawn on it: a removed word is red and struck through, a changed or added word is highlighted, and the counts sit above the text, like "1,204 words removed · 318 changed".
- **Times.** When the transcript has speaker turns, this switch shows or hides the time each turn starts.
- **Copy everything.** Puts the text you are looking at on your clipboard. **Save as...** writes it to a plain text file. **Share...** opens the macOS share sheet, so you can send it to Messages, Mail, Notes, AirDrop or any app that accepts text. In the Marked up view the three buttons read Copy cleaned, Save cleaned as... and Share cleaned..., because they hand over the cleaned text, not the marks.
- **New transcription.** Clears the page for the next file. Check the chip first: **Saved to History** means it is kept; **This version is not saved** means copy or save it before you move on.

### Where it goes

A finished transcript is saved in [History](/help/transcript-history/); the **Saved to History** chip on the Done step confirms it was kept. If the save did not go through, the Done step says **This version is not saved** instead, and Copy, Save and Share still work on the text in front of you. Its row shows the first words of the transcript, the date it was made, and a tag with the name of the file it came from, so you can search for the recording by its file name. History labels each row as a **Dictation** (made with your keybind) or a **Transcript** (made here), and the **All**, **Dictations**, **Transcripts** buttons show one kind or both. You can search, copy, paste, rename speakers and delete from there.

### Where the recording goes

The recording stays on your Mac. Transcription and speaker detection always run locally, and so does the cleanup when you pick EG-1, Apple Intelligence or a downloaded Ollama model. If you pick OpenAI, Gemini, Claude or a hosted Ollama model, the text of the transcript goes to that provider for the cleanup and nothing else does; the page says so while the file is running and again when it is done. What each provider receives is in [AI polish and cloud data](/help/ai-polish-and-cloud-data/).
