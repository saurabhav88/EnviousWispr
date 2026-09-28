---
title: "How to Get British Spelling When You Dictate on a Mac"
description: "Colour, not color. How to make dictation on your Mac write British spelling, what it changes, and the few words it leaves alone."
topic: tips-troubleshooting
pubDate: 2026-09-28
tags: ["dictation", "macos", "languages", "writing"]
draft: false
author: "Saurabh Vaish"
keywords:
  - "british spelling dictation mac"
  - "uk english dictation mac"
  - "dictation colour not color"
  - "voice to text british english"
  - "speech to text uk spelling"
faqs:
  - question: "How do I get British spelling from dictation on a Mac?"
    answer: "In EnviousWispr, a free dictation app for Mac, open Settings, Transcription, Language, switch off Auto-detect language, click Change and choose English (UK). Your next dictation writes colour, centre and organise instead of the American spellings."
  - question: "Why does my speech-to-text app spell colour as color?"
    answer: "The speech engines EnviousWispr runs, Parakeet and WhisperKit, both write English with American spelling. They hear you correctly; the spelling is the one they learned. A separate step after transcription is what turns it into British spelling."
  - question: "Does British spelling still work with AI polish on?"
    answer: "Yes. EnviousWispr changes the spelling before AI polish runs and checks it again after, which catches American spelling that a polish model puts back. It works with polish on or off, and in Transcribe a File too."
  - question: "Which words does it leave alone?"
    answer: "Words whose British spelling depends on meaning, such as program, check, practice, license, meter, story and tire, are left as you said them rather than guessed. Names in the middle of a sentence and anything in your Custom Words are also kept exactly as written."
---

If you write in British English, dictation has a small, constant annoyance built in. You say "colour" and it writes "color". You say "organisation" and get "organization". Each one is a two-second fix, and after a page of dictation there are twenty of them.

This post explains why that happens and how to make dictation on your Mac write British spelling from the start. It uses EnviousWispr, a free dictation app for Mac, which added an English (UK) option in version 2.5.1.

## Why dictation writes American spelling

Modern speech engines learn to write from huge amounts of text, and most of that text uses American spelling. So when you say "colour", the engine hears the word perfectly and then writes the spelling it has seen most often: "color".

The two engines EnviousWispr runs on your Mac, Parakeet and WhisperKit, both behave this way. Your accent has nothing to do with it. A speaker from Leeds and a speaker from Boston get the same spelling, because the spelling is a writing habit, not a listening one. The spelling differences themselves are well documented; [Wikipedia's page on them](https://en.wikipedia.org/wiki/American_and_British_English_spelling_differences) is a good overview.

## How to switch to British spelling

**Turn off auto-detect.** Click the EnviousWispr icon in your menu bar, choose **Settings**, go to **Transcription**, and under **Language** switch off **Auto-detect language**.

**Choose English (UK).** Click **Change** and pick **English (UK)**, directly under English. Its line reads "British spelling: colour, organise, centre".

**Dictate a test sentence.** Try "the colour of the organisation's centre". You will know it is working when the result says colour, organisation and centre.

That is the whole setup. It applies to live dictation and to [Transcribe a File](/features/file-transcription/), with AI polish on or off.

## What changes and what does not

The conversion covers the everyday spelling families: -our words (colour, favourite), -re words (centre), -ise words (organise), doubled consonants (travelled). Here is what to expect beyond that.

| Situation | What happens |
|---|---|
| AI polish is on | Spelling is changed before polish and checked again after, so a polish model cannot quietly put "color" back |
| A word whose spelling depends on meaning | Left as you said it: program, check, practice, license, meter, story and tire |
| A name in the middle of a sentence | Kept as written, so "Kennedy Center" stays "Center" |
| A word in your Custom Words | Kept exactly as you saved it |
| Vocabulary | Unchanged: "apartment" stays "apartment", it does not become "flat" |
| Auto-detect is on | American spelling, because British spelling needs English (UK) chosen |

The meaning-dependent words are left alone on purpose. "Program" is British for a computer program and "programme" for a television one, and the app cannot know which you meant, so it does not guess.

## Live Preview in British English

If you use Live Preview, the words that appear while you speak come from a separate preview engine. With the macOS preview engine, it uses the English (United Kingdom) language pack, which you may need to download on the **Live Preview** settings page first. The [Live Preview page](/features/live-preview/) shows how the preview works.

## Other languages and the app's own language

British spelling is one part of a wider set of language options. Parakeet recognises 25 European languages and works out which one you are speaking, and WhisperKit covers 99+. The app's own menus can also be shown in German. The [Languages page](/features/languages/) covers all of it, and the help article [Multi-Language Dictation](/help/multi-language-dictation/) has the step-by-step detail.

## The takeaway

Dictation writes American spelling because that is what speech engines learned, not because of how you speak. Choose English (UK) as your dictation language in EnviousWispr and it writes colour, centre and organise from the first word, including when AI polish is cleaning up the text.
