---
title: "Multi-Language Dictation"
description: "Dictating in languages other than English."
category: "speech-engines"
section: "Transcription"
order: 2
keywords: ["language", "languages", "spanish", "french", "german", "hindi", "not english", "foreign language", "bilingual", "multilingual", "change language", "accent", "british english", "british spelling", "uk english", "english uk", "colour", "organise", "american spelling"]
related: ["choosing-a-speech-engine-parakeet-vs-whisperkit", "filler-word-removal", "live-preview-words-on-screen"]
updated: 2026-09-24
---
EnviousWispr handles dozens of languages without asking you to change a setting before every session. Parakeet, the transcription engine you start with, recognises 25 European languages and detects which one you are speaking on its own.

### Telling it your language

Both engines let you lock a language under **Settings** \> **Transcription** \> **Language**, or leave it on **Auto-detect language**.

On Parakeet, locking a language narrows what the engine produces to your own alphabet, so a German dictation stops coming back with stray Greek or Cyrillic characters in it. It cannot separate two languages that share an alphabet, so it will not tell German from Dutch. On WhisperKit, locking a language gives higher accuracy than auto-detect.

### British spelling: English (UK)

Both engines write English with American spelling. They hear you correctly and spell "organisation" as "organization". Choose **English (UK)** and the app gives you British spelling instead: colour, centre, organise, travelled, favourite.

**Turn off auto-detect.** Go to **Settings** \> **Transcription** \> **Language** and switch off **Auto-detect language**.

**Choose English (UK).** Click **Change** and pick **English (UK)**, directly under **English**. Its line reads "British spelling: colour, organise, centre".

You will know it is working when your next dictation says "colour" where it used to say "color".

What to expect:

- **It works with AI Polish on or off.** The spelling is changed before AI Polish runs and checked again after it, which catches American spelling that AI Polish puts back.
- **Words whose spelling depends on meaning are left as you said them.** "Program", "check", "practice", "license", "meter", "story" and "tire" each have a British spelling in only some of their meanings, so the app does not guess.
- **Names and your own words are kept.** A name in the middle of a sentence, such as "Kennedy Center", and anything in your Custom Words stays exactly as written. A name at the very start of a sentence or list item can still be changed.
- **It changes spelling, not vocabulary.** "Apartment" stays "apartment". Your accent does not matter, and the engine still listens for English.
- **Auto-detect keeps American spelling in your dictation.** The app converts to British spelling only while **English (UK)** is chosen.
- **Live Preview shows British spelling too.** With the macOS preview engine, Live Preview uses the English (United Kingdom) language pack, which you may need to download on the **Live Preview** page first.

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
