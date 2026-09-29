---
title: "Why Is My Dictation Inaccurate?"
description: "The checks worth running when your dictation comes out wrong."
category: "troubleshooting"
section: "Transcription Issues"
order: 2
keywords: ["inaccurate", "wrong words", "typos", "bad accuracy", "not accurate", "gets my words wrong", "misheard", "poor quality", "garbled", "names spelled wrong", "improve accuracy", "wrong language", "words changed", "rewrote my text"]
related: ["adding-custom-words", "choosing-your-microphone"]
updated: 2026-09-29
deflection: "show_but_always_send"
---
Dictation gets less accurate when the audio is weak, the wrong microphone is in use, the language setting does not match your speech, or the speech engine meets an unfamiliar word. Start with the fix that matches what you see.

### The words are wrong, or the phrasing changed

First find out which half went wrong. Open **History** and read the dictation back.

- **The words themselves are wrong.** That points at the audio, the language setting or the speech engine. Check the microphone, your language setting and your custom words.
- **The words are right but the phrasing changed.** AI Polish rewrote your text. Go to **Settings** > **AI Polish**, switch **Enable AI Polish** off, and dictate again to confirm.

### Get closer to the microphone

Weak audio lowers accuracy. Try a headset microphone, or move nearer to your Mac. Dictate the same sentence both ways and compare the results in **History**. Speak at your normal pace: slowing down or over-enunciating makes recognition worse.

### It is using the wrong microphone

1. **Open the microphone settings.** Open EnviousWispr **Settings** and go to **Microphone**.
2. **Pick your device.** The **Input device** list starts on **Auto**, which records from whatever input your Mac is set to. That may not be the one you are speaking into. Pick your microphone from the list. The picker then shows its name in place of Auto.

### The same name or word comes out wrong every time

Names, companies and specialised words from your field are not in a general speech model. Teach them to EnviousWispr.

1. **Add the words.** Open **Settings**, go to **Dictionary** > **Your Words**, and add them. Each word appears in the list once you have added it.
2. **Switch on vocabulary packs.** Open **Vocabulary Packs** and switch on the packs that match your work.

This is the fix for a colleague's name that is spelled wrong every single time. See [Adding Custom Words](/help/adding-custom-words/).

### My language comes out wrong

The **Fast** engine (Parakeet), which you start with, covers 25 European languages. For any other language, go to **Settings** > **Transcription**, click the **All Languages** card (WhisperKit), and pick your language. On All Languages, naming your language is more accurate than leaving it on auto-detect. See [Multi-Language Dictation](/help/multi-language-dictation/).

### Faster Transcription is making mistakes

If you switched **Faster Transcription** on, switch it back off under **Settings** > **Transcription**. On the Fast engine, it roughly doubled the number of wrong words in our tests. See [Faster Transcription](/help/live-transcription-streaming-asr/).
