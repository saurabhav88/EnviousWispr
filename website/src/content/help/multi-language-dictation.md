---
title: "Multi-Language Dictation"
description: "Dictating in languages other than English."
category: "speech-engines"
section: "Transcription"
order: 2
keywords: ["language", "languages", "spanish", "french", "german", "hindi", "not english", "foreign language", "bilingual", "multilingual", "change language", "accent", "british english", "british spelling", "uk english", "english uk", "colour", "organise", "american spelling", "wrong language", "greek letters", "cyrillic", "lock language"]
related: ["choosing-a-speech-engine-parakeet-vs-whisperkit", "filler-word-removal", "live-preview-words-on-screen"]
updated: 2026-09-29
deflection: "can_resolve"
---
EnviousWispr handles dozens of languages. The **Fast** engine (Parakeet), which you start with, recognizes 25 European languages and detects which one you are speaking on its own. For other languages, switch to the **All Languages** engine (WhisperKit), which supports 99+.

### Lock or auto-detect my language

Under **Settings** > **Transcription** > **Language**, you can lock one language or leave **Auto-detect language** on. Both engines offer this. This is the language you speak. The language of EnviousWispr's own menus is a separate setting: see [the app's language](/help/sounds-and-appearance/).

- **On Fast (Parakeet)**, locking a language narrows the text to your own alphabet. A German dictation stops coming back with stray Greek or Cyrillic characters. A lock cannot tell apart two languages that share an alphabet, so it will not separate German from Dutch.
- **On All Languages (WhisperKit)**, locking a language is more accurate than auto-detect.

To lock a language, switch off **Auto-detect language**, then click **Change** and pick your language. On All Languages, the language section appears once its model has finished downloading.

### Dictate in a language Fast does not cover

If your language is not one of the 25 the Fast engine covers, switch to All Languages.

1. **Open settings.** Click the EnviousWispr icon in your menu bar, choose **Settings**, and go to **Transcription**.
2. **Select All Languages.** Click the **All Languages** card. If you have not downloaded its model yet, click **Download WhisperKit Model**.
3. **Choose your language.** Switch off **Auto-detect language**, then click **Change** and pick your language. You can also leave auto-detect on.

Your next dictation should come back in the language you spoke.

### Write English with British spelling

Both engines write English with American spelling, so "organisation" comes out as "organization". Choose **English (UK)** to get British spelling instead: colour, centre, organise, travelled, favourite. It applies to dictation and to Transcribe a File, with AI Polish on or off.

1. **Turn off auto-detect.** Go to **Settings** > **Transcription** > **Language** and switch off **Auto-detect language**.
2. **Choose English (UK).** Click **Change** and pick **English (UK)**, directly under **English**. Its line reads "British spelling: colour, organise, centre".

Your next dictation says "colour" where it used to say "color".

What to expect:

- **It works with AI Polish on or off.** The spelling is changed before AI Polish runs and checked again after it, which catches American spelling that AI Polish puts back.
- **Words whose spelling depends on meaning are left as you said them.** "Program", "check", "practice", "license", "meter", "story" and "tire" each have a British spelling in only some of their meanings, so the app does not guess.
- **Names and your own words are kept.** A name in the middle of a sentence, such as "Kennedy Center", and anything in your custom words stays as written. A name at the very start of a sentence or list item can still be changed.
- **It changes spelling, not vocabulary.** "Apartment" stays "apartment". Your accent does not matter, and the engine still listens for English.
- **Auto-detect keeps American spelling.** The app converts to British spelling only while **English (UK)** is chosen.
- **Live Preview shows British spelling too.** With the Apple preview engine, Live Preview uses the English (United Kingdom) language pack. You may need to download it on the **Live Preview** page first.

### Mix languages, translate, and other limits

- **Keep to one language per sentence.** Auto-detect handles one language at a time and struggles when you switch languages in the middle of a sentence.
- **Dictation is not translation.** AI Polish cleans up grammar and filler words, but it does not translate. Dictating in French returns French text.

### Filler words in other languages

The step that removes "um" and "uh" reads the language you are dictating in. It leaves some words alone because they are real words in that language:

- "er" stays in German, Dutch, Danish, Norwegian and Swedish.
- "um" stays in German, Portuguese, Slovenian and Croatian.

See [Filler Word Removal](/help/filler-word-removal/).

### Live Preview shows another language

The words shown in the pill while you speak come from a separate engine with its own language setting. You pick its language on the **Live Preview** page. Some languages need a language pack from macOS or the Universal engine. See [Live Preview](/help/live-preview-words-on-screen/).
