---
title: "Multi-Language Dictation"
description: "Dictating in languages other than English."
category: "speech-engines"
section: "Transcription"
order: 2
keywords: ["language", "languages", "spanish", "french", "german", "hindi", "not english", "foreign language", "bilingual", "multilingual", "change language", "accent"]
related: ["choosing-a-speech-engine-parakeet-vs-whisperkit", "filler-word-removal", "live-preview-words-on-screen"]
updated: 2026-09-05
---
EnviousWispr handles dozens of languages without asking you to change a setting before every session. Parakeet, the transcription engine you start with, recognises 25 European languages and detects which one you are speaking on its own.

### Telling it your language

Both engines let you lock a language under **Settings** \> **Transcription** \> **Language**, or leave it on **Auto-detect language**.

On Parakeet, locking a language narrows what the engine produces to your own alphabet, so a German dictation stops coming back with stray Greek or Cyrillic characters in it. It cannot separate two languages that share an alphabet, so it will not tell German from Dutch. On WhisperKit, locking a language gives higher accuracy than auto-detect.

### Switching to WhisperKit for more languages

If your spoken language is not among the 25 Parakeet covers, switch to the WhisperKit engine, which supports 99+ languages.

**Open settings.** Click the EnviousWispr icon in your menu bar, choose **Settings**, and go to **Transcription**.

**Select WhisperKit.** Choose **WhisperKit** from the transcription engine options. If you have not downloaded the engine yet, click **Download WhisperKit Model**.

**Choose your language.** Pick your language from the list, or leave the setting on auto-detect.

You will know the setup is working when your next dictation comes back in the language you spoke.

### Tips for the best results

- **Name your language rather than auto-detecting.** Choosing your language in settings gives higher accuracy than leaving it on auto-detect.
- **Keep to one language per sentence.** Auto-detect handles one language at a time and struggles when you switch languages mid-sentence.
- **Expect correction, not translation.** AI Polish cleans up grammar and filler words, but it does not translate. Dictating in French returns French text.
- **Filler words are removed with your language in mind.** The step that strips ums and uhs reads the language you are dictating in. It leaves "er" alone in German, Dutch, Danish and Norwegian, and "um" in German, because those are real words there. Read [_Filler Word Removal_](/help/filler-word-removal/).
- **Live Preview has its own language setting.** The words shown in the pill while you speak come from a separate engine, and you pick its language on the **Live Preview** page. Some languages need a language pack from macOS or the Universal engine. Read [_Live Preview_](/help/live-preview-words-on-screen/).
