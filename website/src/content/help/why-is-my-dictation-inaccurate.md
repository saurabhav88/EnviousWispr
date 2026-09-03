---
title: "Why Is My Dictation Inaccurate?"
description: "The checks worth running when your dictation comes out wrong."
category: "troubleshooting"
section: "Transcription Issues"
order: 2
keywords: ["inaccurate", "wrong words", "typos", "bad accuracy", "not accurate", "gets my words wrong", "misheard", "poor quality", "garbled", "names spelled wrong", "improve accuracy"]
related: ["adding-custom-words", "choosing-your-microphone"]
updated: 2026-09-01
---
Dictation accuracy drops when the audio is weak, the input microphone is the wrong one, the language setting does not match your speech, or the engine meets an unfamiliar word. Work through these steps in order to improve accuracy.

### 1. Get closer to the microphone

Audio quality directly affects transcription accuracy. Try a headset microphone, or move nearer to your Mac. Dictate the same sentence both ways and compare the results in **History**.

### 2. Check which microphone is being used

**Select your input device.** Open EnviousWispr settings and go to **Microphone**. On Auto, EnviousWispr records from whatever input your Mac is set to, which may not be the one you are speaking into. Pick a device from the list to be sure. The picker then shows that device's name in place of Auto.

### 3. Teach it the words it keeps missing

Names, companies, and specialised words from your field are not in a general speech model.

**Add the missing words.** Open **Settings**, go to **Dictionary** \> **Your Words**, and add them. Each word appears in the list once you have added it. Then open **Vocabulary Packs** and switch on the packs that match your work. This is the fix for a colleague's name that comes out spelled wrong every single time.

### 4. Check your language

Parakeet, the transcription engine you start with, covers 25 European languages. For anything outside that, switch to WhisperKit under **Transcription** and pick your language. On WhisperKit, naming your language is more accurate than leaving it on auto-detect.

### 5. Turn Faster Transcription off

If you switched Faster Transcription on, switch it back off under **Transcription**. On Parakeet, Faster Transcription measurably increases mistakes.

### 6. Work out which half went wrong

**Review your history.** Open **History** and read the dictation back to work out where the error came from.

- **The words themselves are wrong.** That points at the audio or the speech engine. Go back to steps 1 to 5.
- **The words are right but the phrasing changed.** That means AI Polish rewrote your text. Set it to None under **AI Polish** and dictate again to confirm.

### Speak naturally

Speak at your normal pace. Slowing down or over-enunciating makes recognition worse, not better.
