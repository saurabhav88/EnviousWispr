---
title: "Choosing a Speech Engine: Parakeet vs WhisperKit"
description: "Which of the two speech engines to use, and when to switch."
category: "speech-engines"
section: "Transcription"
order: 1
keywords: ["parakeet", "whisperkit", "whisper", "which engine", "engine", "speech engine", "model", "accuracy vs speed", "switch engine", "transcription engine", "which is better"]
related: ["multi-language-dictation", "why-is-my-dictation-inaccurate"]
updated: 2026-08-06
---
You can choose between two speech engines for transcription, Parakeet or WhisperKit. Both run entirely on your Mac. Neither sends your audio anywhere, and neither needs an internet connection once its model has been downloaded.

### Comparison of the two engines

| Feature | Parakeet | WhisperKit |
| --- | --- | --- |
| Languages | 25 European | 99+ |
| Speed | Faster | Slower |
| Setup | Downloaded for you during setup | You download it, about 1.5 GB |
| Best for | Everyday dictation | Languages Parakeet does not cover |

### Choosing an engine

Keep Parakeet. It is the default engine, it is faster than WhisperKit, and it covers 25 European languages. Switch to WhisperKit only if you dictate in a language Parakeet does not cover.

To change your engine, follow these steps.

**Open settings.** Click the EnviousWispr icon in your menu bar, choose **Settings**, and go to **Transcription**.

**Pick your engine.** Select either Parakeet or WhisperKit.

**Download the model.** The first time you choose WhisperKit, click **Download WhisperKit Model**. The model does not download on its own, and it takes about 1.5 GB of storage.

The change applies to your next recording.

### What happens when you dictate

Knowing the sequence helps you work out where a delay or an unexpected change came from. When you finish a recording, EnviousWispr does five things in order.

**Trim the audio.** EnviousWispr finds the parts of the recording where you were talking and keeps those. In a quiet or normal room that is the same as trimming the silence at the start and the end.

**Transcribe the speech.** Your chosen engine reads the audio and writes out the text.

**Clean up the text.** Your custom words are applied, filler words are removed, spoken emoji are converted, and numbers, dates and times are written the way you would type them. This stage always runs, whatever you have AI Polish set to, and each part of it has its own setting.

**Polish the text.** Any AI polish you have switched on runs against the cleaned-up text. This stage is optional, and setting AI Polish to None skips it entirely.

**Paste the result.** The finished text is pasted into the text box you were working in.

That split matters when you are troubleshooting. If your text came out different from what you said and AI Polish is switched off, the clean-up stage is what changed it.

Transcription speed depends on your Mac, the engine you selected, and how long you spoke. If one engine feels slow or keeps missing your language, try the other. If speech recognition fails for any reason, EnviousWispr stays open. Start another recording and it recovers on its own.
