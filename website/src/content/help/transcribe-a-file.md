---
title: "Transcribe a File"
description: "Turn a voice memo, lecture, meeting or video you already have into clean text on your Mac, and choose the speech engine and cleanup."
category: "features"
section: "Transcribe a File"
order: 8
keywords: ["transcribe a file", "import audio", "voice memo", "meeting recording", "lecture", "podcast", "mp3", "m4a", "video to text", "transcript", "file transcription", "audio to text", "file won't open", "no speech found", "no sound in file", "drag a file", "how long will it take"]
related: ["transcribe-a-file-speaker-labels", "transcript-history", "choosing-a-speech-engine-parakeet-vs-whisperkit", "choosing-an-ai-provider-none-apple-intelligence-ollama-openai-gemini", "ai-polish-and-cloud-data"]
updated: 2026-09-29
deflection: "can_resolve"
---
Transcribe a File takes an audio or video file you already have and gives you back clean, readable text. The recording never leaves your Mac. When the recording has more than one voice and the app can tell them apart and match the words to them, the transcript comes back as speaker turns; see [speaker labels](/help/transcribe-a-file-speaker-labels/).

### Open Transcribe a File

There are two ways in.

- **From the sidebar.** Click the EnviousWispr icon in your menu bar, choose **Open EnviousWispr**, and click **Transcribe a File** in the sidebar.
- **From the menu bar.** Click the EnviousWispr icon and choose **Transcribe a File...**. It sits right under **Start Recording**, the other way to get words in.

### Which files can I transcribe?

Click **Choose a file**, or drag a file onto the page. These formats work: **m4a, mp3, wav, aiff, caf, mp4, mov** and **flac**. For a video, only the sound is used.

### Why won't my file transcribe?

If the file cannot be used, the page says why: the file could not be opened, there is no sound in it, or no speech was found in it. If the app is busy with a dictation, an earlier take, or another file, or the engine you picked is not downloaded yet, the message says what to do.

### How does transcribing a file work?

The page walks you through six steps. The bar at the top shows where you are. Until the work starts you can go back to change a choice. After a run you can still go back to the engine and polisher steps, but choosing another file means starting a new transcription.

1. **Upload.** Pick the file.
2. **Transcription.** Pick the speech engine.
3. **Polish.** Pick how the text is cleaned up.
4. **Review.** Check the file, the engine and the polisher, read the time estimate, and click **Start transcription**.
5. **Working.** One card shows what is happening: **Preparing**, **Transcribing**, **Finding who said what**, then **Cleaning section 3 of 14** with a bar. Once a few sections are done it shows a rough time left, such as "about 3 minutes left". **Stop** is on the card. The footer says "Safe to leave this page": you can move to another page while it works.
6. **Done.** Your transcript, with everything you can do with it.

### Which speech engine should I pick?

Both engines run entirely on this Mac. **This choice also changes the engine your dictation uses**, so pick the one you want for both.

| | **Fast** (recommended) | **All Languages** |
|---|---|---|
| What the card says | "Best for everyday English and European recordings." | "Best for other languages or the toughest audio." |
| Model | Parakeet v3 | Whisper Large v3 Turbo |
| Languages | 25 European | 99+ |
| An hour of audio takes | About 7 seconds | About 2 minutes |

An engine that is not downloaded yet says so; get it in Transcription settings. More on the two engines, including how their language counts compare, is in [choosing a speech engine](/help/choosing-a-speech-engine-parakeet-vs-whisperkit/).

### Which polisher should I pick?

The polisher rewrites the text for punctuation, capitalisation and flow, and lays out lists. The Polish step shows six cards:

| Polisher | Where it runs | What the card says |
|---|---|---|
| **EG-1** | On this Mac | Our best model for cleanup and list-making. On an imported recording it removes about four times more filler than Apple Intelligence. |
| **Apple Intelligence** | On this Mac | Apple's on-device model. Needs macOS 26 or later. |
| **Ollama** | Depends on the model | Any model you run in Ollama. A model downloaded to your Mac sends nothing; a model that runs on Ollama's servers receives the text. The page says which kind your pick is when Ollama reports it. |
| **OpenAI** | Their servers, under your own key | Only the text is sent, never the audio. |
| **Gemini** | Their servers, under your own key | Only the text is sent, never the audio. |
| **Claude** | Their servers, under your own key | Only the text is sent, never the audio. |

There is no card for None or S1-mini. Until you click a card, files use the same polish choice as your dictation, including S1-mini or no polish. Once you click a card, the polisher for files is separate from the one your dictation uses, so you can clean files with one and dictations with another. A link on the step, **Use dictation's polish settings**, makes files follow your dictation choice again.

If a polisher needs setting up (a key, a download, Ollama not running), the same setup box you see on the AI Polish page appears on this step, and **Continue** waits until it is ready. [Choosing an AI provider](/help/choosing-an-ai-provider-none-apple-intelligence-ollama-openai-gemini/) covers the trade-offs.

### What cleanup runs if I choose no polisher?

The automatic fixes run first, whichever polisher you pick, including none:

- Numbers and dates are written as figures.
- Your custom words are applied when **Enable Dictionary** is on under **Settings** \> **Dictionary**.
- Filler words are removed when **Remove filler words** is on under **Settings** \> **Transcription**. Spoken emoji has its own switch there.

### How long will it take?

The Review step shows an estimate such as "Ready in about 3 minutes" before you start. It is worked out from the length of your recording and the engine you chose: about four seconds of work for every minute of audio with Fast, about six with All Languages, rounded to the nearest minute, or "under a minute" for a short file. A two-hour recording is a longer wait, not a different process.

On the Working step, once a few sections have finished, the card shows a time left measured from how fast they actually went.

### How do I stop a transcription?

Press **Stop** on the Working card at any time. What you keep depends on how far it got:

- **Still transcribing:** nothing, because no words exist yet.
- **Still finding the speakers:** the words with no labels.
- **Cleaning:** every speaker turn, with the original transcription under each name.

Once words exist, Stop never throws them away. The details are in [speaker labels](/help/transcribe-a-file-speaker-labels/).

### What can I do with the finished transcript?

The Done step shows your transcript with a row of chips above it:

- the word count
- the length of the recording
- whether it is saved to History
- the polish credit

The credit reads **Polished by** and the polisher's name whenever the polisher cleaned any of it. A turn it could not finish says **Not fully polished** beneath itself instead. It reads **No AI polish** when AI polish is off for the file, or **No AI polish applied** when the polisher did not rewrite anything. **Change** next to the credit takes you back to the Polish step; **Clean it again** on the Review step then runs only the cleanup, without reading the file again.

Below the chips you can:

- **Switch views: Cleaned, Marked up, Original.** These are offered once at least one turn has been through the cleanup. **Cleaned** is the text after cleanup, with the automatic fixes and, where the polisher rewrote a turn, its rewrite. **Original** is the original transcription, the words as the speech engine heard them. **Marked up** shows the original with the cleanup drawn on it: a removed word is red and struck through, a changed or added word is highlighted, and the counts sit above the text, like "1,204 words removed · 318 changed".
- **Show or hide times.** When the transcript has speaker turns, the **Times** switch shows or hides the time each turn starts.
- **Copy, save or share.** **Copy everything** puts the text you are looking at on your clipboard and says Copied for a moment. **Save as...** writes it to a plain text file. **Share...** opens the macOS share sheet, so you can send it to Messages, Mail, Notes, AirDrop or any app that accepts text. In the Marked up view the three buttons read Copy cleaned, Save cleaned as... and Share cleaned..., because they hand over the cleaned text, not the marks.
- **Start over.** **New transcription** clears the page for the next file. Check the chip first: **Saved to History** means it is kept; **This version is not saved** means copy or save it before you move on.

### Where is my finished transcript saved?

A finished transcript is saved in [History](/help/transcript-history/); the **Saved to History** chip on the Done step confirms it was kept. If the save did not go through, the Done step says **This version is not saved** instead, and Copy, Save and Share still work on the text in front of you.

In History, the row shows the first words of the transcript, the date it was made, and a tag with the name of the file it came from, so you can search for the recording by its file name. History labels each row as a **Dictation** (made with your keybind) or a **Transcript** (made here), and the **All**, **Dictations**, **Transcripts** buttons show one kind or both. You can search, copy, paste, rename speakers and delete from there.

### Does my recording leave my Mac?

The recording stays on your Mac. Transcription and speaker detection always run locally, and so does the cleanup when you pick EG-1, Apple Intelligence, S1-mini or a downloaded Ollama model. If you pick OpenAI, Gemini, Claude or a hosted Ollama model, the text of the transcript goes to that provider for the cleanup and nothing else does; the page says so while the file is running and again when it is done. What each provider receives is in [AI polish and cloud data](/help/ai-polish-and-cloud-data/).
