---
title: "Filler Word Removal"
description: "EnviousWispr removes um, uh and hmm from your dictation. Here is how to turn it off and what it leaves alone."
category: "features"
section: "Text Processing"
order: 2
keywords: ["um", "uh", "filler", "filler words", "remove um", "you know", "like", "stop words", "cleaner speech", "keep ums", "turn off filler removal", "er", "hmm", "false starts", "repeated words"]
updated: 2026-09-29
deflection: "can_resolve"
---
EnviousWispr removes spoken noises like "um", "uh", "hmm" and "er" from your dictated text before it reaches your app. This is on by default.

### Keep my ums and uhs in the text

Turn the setting off if you would rather keep your spoken hesitations.

1. Click the EnviousWispr menu bar icon and choose **Open EnviousWispr**.
2. Click **Dictation Settings**, then **Engine**.
3. Turn off **Remove filler words (um, uh, hmm...)**.

Your next dictation keeps every noise in the text.

### Does filler removal need AI or the internet?

No. It runs on your Mac against a fixed list of noises, with no AI model involved. It works with no internet connection, and it works even when AI Polish is switched off.

### Why was "um" inside a word left alone?

EnviousWispr removes these noises only when they stand on their own as separate words. The "um" inside "umbrella" stays.

### Why does it keep "er" or "um" in some languages?

Some of these sounds are real words in other languages, so EnviousWispr keeps them there. Every other noise on the list is still removed.

- **"er" stays** in German (it means "he"), Dutch ("there"), Danish and Norwegian ("is"), and Swedish.
- **"um" stays** in German, Portuguese, Slovenian and Croatian, where it is an ordinary word.

EnviousWispr works out the language of the dictation in one of these ways:

- The language you picked under **Dictation Settings** > **Engine**.
- On Auto-detect, the language the speech engine reports, or the language the app recognises from the text.

If the app can tell the dictation is not in English but cannot tell which language it is, it keeps all of these words to be safe.

### Remove false starts and repeated words too

A fixed list only catches those specific sounds. AI Polish goes further. It also removes false starts, repeated words and general hesitations that no list can anticipate. On a Mac running macOS 26 or later, AI Polish is on by default through Apple Intelligence. On earlier macOS versions, that step is skipped until you choose another option: open **Settings** > **AI Polish** and pick EG-1 or S1-mini.
