---
title: "Filler Word Removal"
description: "Cutting um, uh and hmm out of your dictation."
category: "features"
section: "Text Processing"
order: 2
keywords: ["um", "uh", "filler", "filler words", "remove um", "you know", "like", "stop words", "cleaner speech"]
updated: 2026-08-21
---
EnviousWispr automatically removes spoken noises like "um", "uh", "hmm", and "er" from your dictated text before it reaches your app. This is on by default.

### Turning it off

You can switch this off if you would rather keep your spoken hesitations in the final text.

**Open settings.** Click the EnviousWispr menu bar icon and select **Settings**, or press Cmd+,.

**Go to Transcription.** Click the **Transcription** tab.

**Switch off the setting.** Turn off **Remove filler words**. Your next dictation keeps every noise in the text.

### How it runs without AI

This runs on your Mac against a fixed list of noises, with no AI model involved. It works with no internet connection, and it works even when AI Polish is switched off.

### What it leaves alone

EnviousWispr only removes these noises when they stand on their own as separate words. The "um" inside the word "umbrella" is left alone.

Some of these sounds are also real words in other languages. If your language is locked to German, Dutch, Danish, or Norwegian in **Settings → Transcription**, EnviousWispr keeps them instead of removing them: "er" (German for "he"; Dutch for "there"; Danish and Norwegian for "is") and "um" (German for "at [a time]" or "in order to") stay in your dictated text. This only applies when your language is locked; on Auto-detect, the fixed list above still applies to every dictation.

### If you want more than this

A fixed list only catches those specific sounds. AI Polish, which is on by default, goes further and also removes false starts, repeated words, and general hesitations that no list can anticipate.
