---
title: "Faster Transcription"
description: "Whether to have text written while you are still speaking."
category: "speech-engines"
section: "Transcription"
order: 4
keywords: ["live transcription", "live", "live text", "real time", "realtime", "streaming", "as you talk", "write while i talk", "text appears while speaking", "faster transcription", "last words missing", "words repeated", "ending cut off"]
seeAlso: "live-transcription-that-keeps-up-with-you"
updated: 2026-09-29
deflection: "can_resolve"
---
Faster Transcription makes EnviousWispr turn your speech into text while you are still speaking, instead of all at once when you stop. The finished text is still pasted after you stop. It is off unless you turn it on. It was called Live transcription until recently.

**Leave it off on the Fast engine (Parakeet). On the All Languages engine (WhisperKit), turn it on if you have picked a language and you often dictate for more than a minute.**

### Turn Faster Transcription on or off

1. **Open EnviousWispr.** Click the EnviousWispr menu bar icon and select **Open EnviousWispr**.
2. **Go to Engine.** Click **Dictation Settings**, then **Engine**.
3. **Use the switch.** Switch **Faster Transcription** on or off. The question mark beside it explains what changes for the engine you are on.

Nothing looks different in your document while you record. Only the timing of the work changes. It can pause the Universal Live Preview engine while you speak.

### Faster Transcription seems to do nothing

On the Fast engine, it saves no time you would notice on a dictation under a minute. It only pulls ahead at around five minutes or longer.

On the All Languages engine, it does nothing while your language is set to **Auto-detect language**. Pick a language under **Settings** > **Transcription** > **Language** first.

If you want to see words on screen while you speak, that is a different setting: see [Live Preview](/help/live-preview-words-on-screen/).

### Why I should leave it off on the Fast engine

The Fast engine (Parakeet) transcribes overlapping pieces of your speech and joins them together. The joins are where mistakes appear, and the longer you talk, the more joins there are.

In our tests, the same audio came out with about twice as many wrong words when Faster Transcription was on: word errors went from 2.0% to 3.7%. Repeated or invented words went from 17 to 51. About 1 dictation in 24 lost its final words. The tests used 28 recordings and a replay of 500 real dictations.

### Why it works better on the All Languages engine

The All Languages engine (WhisperKit) keeps one continuous transcript instead of joining pieces together, so accuracy holds up better. It can still drop a final word now and then.

It has to know your language before it can start. If your language is set to auto-detect, EnviousWispr ignores Faster Transcription and works the normal way, because guessing the language from the first moment of audio gets it wrong too often.
