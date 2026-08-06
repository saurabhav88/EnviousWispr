---
title: "Why Is My Dictation Inaccurate?"
description: "The checks worth running when your dictation comes out wrong."
category: "troubleshooting"
section: "Transcription Issues"
order: 2
keywords: ["inaccurate", "wrong words", "typos", "bad accuracy", "not accurate", "gets my words wrong", "misheard", "poor quality", "garbled", "names spelled wrong", "improve accuracy"]
related: ["adding-custom-words", "choosing-your-microphone"]
updated: 2026-08-05
---
EnviousWispr is a free dictation app for macOS. When it gets your words wrong, the cause is nearly always weak audio, the wrong microphone, a language it is not set to, or a word it has never met. Work through these in order.

### 1. Get closer to the microphone

Try a headset microphone, or move nearer to your Mac. Dictate the same sentence both ways and compare the results in **History**.

### 2. Check which microphone is being used

Open EnviousWispr's settings and go to **Microphone**. On Auto, EnviousWispr records from whatever input your Mac is set to, which may not be the one you are speaking into. Pick a device from the list to be sure. The picker then shows that device's name in place of Auto.

### 3. Teach it the words it keeps missing

Names, companies and terms from your field are not in a general speech model. Open settings, go to **Your Words**, and add them. Each word appears in the list once you have added it. Switch on the vocabulary packs that match your work. This is the fix for "it always spells my colleague's name wrong".

### 4. Check your language

Parakeet, the engine you start with, covers 25 European languages. For anything outside that, switch to WhisperKit under **Transcription** and pick your language. On WhisperKit, naming your language is more accurate than leaving it on auto-detect.

### 5. Turn Live transcription off

If you switched it on, switch it back off under **Transcription**. On Parakeet it measurably increases mistakes.

### 6. Work out which half went wrong

Open **History** and read the dictation back.

- **The words themselves are wrong.** That is the audio or the speech engine. Go back to steps 1 to 5.
- **The words are right but the phrasing changed.** That is AI Polish rewriting you. Set it to None under **AI Polish** and dictate again to confirm.

### One more thing

Speak naturally, at your normal pace. Slowing down or over-enunciating makes recognition worse, not better.
