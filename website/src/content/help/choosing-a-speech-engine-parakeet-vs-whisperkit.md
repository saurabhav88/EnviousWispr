---
title: "Choosing a Speech Engine: Parakeet vs WhisperKit"
description: "Which of the two speech engines to use, and when to switch."
category: "speech-engines"
section: "Transcription"
order: 1
keywords: ["parakeet", "whisperkit", "whisper", "which engine", "engine", "speech engine", "model", "accuracy vs speed", "switch engine", "transcription engine", "which is better", "fast engine", "all languages", "engine is slow", "wrong language", "download whisperkit model"]
related: ["multi-language-dictation", "why-is-my-dictation-inaccurate", "using-snippets"]
updated: 2026-09-29
deflection: "can_resolve"
---
Keep the **Fast** engine, which uses Parakeet. Switch to the **All Languages** engine, which uses WhisperKit, only if you dictate in a language Fast does not cover.

Both engines run entirely on your Mac. Neither sends your audio anywhere, and neither needs an internet connection once its model has been downloaded.

### Parakeet or WhisperKit: which should I use?

The **Engine** tab of **Dictation Settings** names the engines **Fast** and **All Languages**. This article uses those names with the model in brackets.

| | Fast (Parakeet) | All Languages (WhisperKit) |
| --- | --- | --- |
| Languages | 25 European | 99+ |
| Speed | Faster | Slower |
| Setup | Downloaded for you during setup | You download it, about 1.5 GB |
| Best for | Everyday dictation | Languages Fast does not cover |

Fast is the default, it is faster, and it covers 25 European languages. If your language is not one of them, use All Languages. See [Multi-Language Dictation](/help/multi-language-dictation/) for the language settings.

### Switch to another engine

1. **Open the engine settings.** Click the EnviousWispr icon in your menu bar, choose **Open EnviousWispr**, and go to **Dictation Settings** > **Engine**.
2. **Pick your engine.** Under **Transcription Engine**, click **Change**, then click the **Fast** card for Parakeet or the **All Languages** card for WhisperKit. Each card names the model it runs.
3. **Set up the model.** The first time you choose All Languages, the summary shows **Model not set up**. Click **Set up model**. The model does not download on its own, and it takes about 1.5 GB of storage.

The change applies to your next recording. If a dictation is in progress, the page says the change applies after it finishes.

### The wrong alphabet shows up in my dictation

On the Fast engine, you can stop stray letters from another alphabet, such as Greek or Cyrillic turning up in a German dictation. Lock your language under **Dictation Settings** > **Engine**. A lock cannot tell apart two languages that share one alphabet, such as German and Dutch. See [Multi-Language Dictation](/help/multi-language-dictation/).

### Dictation is slow or misses my language

If one engine feels slow or keeps missing your language, try the other. Speed depends on your Mac, the engine you chose, and how long you spoke. If a transcription fails, start another recording. If it keeps failing, see [App crashes or the speech engine stops](/help/app-crashes-or-asr-engine-crashes/).

### What happens between speaking and pasting

When you finish a recording, EnviousWispr does five things in order. Knowing the order helps you find where a delay or an unexpected change came from.

1. **Trim the audio.** EnviousWispr keeps the parts of the recording where you were talking. In a quiet or normal room, that is the same as trimming the silence at the start and the end.
2. **Transcribe the speech.** Your chosen engine reads the audio and writes out the text.
3. **Clean up the text.** A snippet you said is expanded first. Then your custom words are applied, filler words are removed, spoken emoji are converted, and numbers, dates and times are written the way you would type them. This step always runs, whatever your AI Polish setting is, and each part has its own setting.
4. **Polish the text.** If AI Polish is on, it runs on the cleaned-up text. Switch **Enable AI Polish** off under **Settings** > **AI Polish** to skip this step.
5. **Paste the result.** The finished text goes into the text box you were working in.

If your text came out different from what you said and AI Polish is off, the clean-up step changed it.
