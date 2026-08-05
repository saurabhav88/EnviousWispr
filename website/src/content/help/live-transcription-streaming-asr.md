---
title: "Live transcription"
description: "Whether to have text written while you are still speaking."
category: "speech-engines"
section: "Transcription"
order: 4
keywords: ["live", "live text", "see words as i speak", "real time", "realtime", "streaming", "as you talk", "preview"]
seeAlso: "live-transcription-that-keeps-up-with-you"
updated: 2026-08-05
---
Normally EnviousWispr writes your text once you stop talking. Live transcription writes it while you are still speaking. It is off unless you turn it on.

**Leave it off on Parakeet. On WhisperKit, turn it on if you have picked a language and often dictate for more than a minute.**

### Turning it on

Open Settings, go to **Transcription**, and switch on **Live transcription**. The question mark beside it shows what changes for the engine you are on.

### Why we say leave it off on Parakeet

Parakeet writes your speech in overlapping pieces and joins them together. The joins are where mistakes appear, and the longer you talk the more joins there are.

Measured on 28 test recordings and a replay of 500 real dictations, against the same audio transcribed the normal way:

- Word errors went from 2.0% to 3.7%.
- Repeated or invented words went from 17 to 51.
- About 1 dictation in 24 lost its final words.

It also saves no time you would notice under a minute. It only gets ahead at around five minutes, which is where it makes the most mistakes.

### Why WhisperKit is different

WhisperKit keeps one continuous transcript instead of joining pieces together, so accuracy holds up better. It can still drop a final word now and then.

WhisperKit has to know your language before it can start. If your language is set to auto-detect, EnviousWispr ignores this setting and works the normal way, because guessing the language from the first moment of audio gets it wrong too often.
