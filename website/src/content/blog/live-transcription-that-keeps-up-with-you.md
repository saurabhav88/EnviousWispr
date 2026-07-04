---
title: "Live Transcription That Keeps Up With You"
description: "EnviousWispr now transcribes while you speak, so long dictations finish almost instantly when you stop. Here is how it works, and why Auto-detect waits."
pubDate: 2026-07-04
tags: ["dictation", "macos", "live-transcription", "whisper", "on-device"]
draft: false
author: "Saurabh Vaish"
keywords:
  - "live transcription mac"
  - "real time dictation macos"
  - "whisper streaming mac"
  - "on device live transcription"
  - "dictation without waiting"
faqs:
  - question: "Does live transcription send my audio to the cloud?"
    answer: "No. Live transcription runs entirely on your Mac, the same as regular transcription. The audio never leaves your device in either mode. The only difference is when the work happens: while you speak instead of after you stop."
  - question: "Why does live transcription turn off when Auto-detect language is on?"
    answer: "Live transcription has to commit to one language within the first second or two of your recording, which is not enough audio to detect a language reliably. With Auto-detect on, EnviousWispr waits and decides the language from your whole recording instead, which is far more accurate. Pick a specific language in Settings to stream live."
  - question: "Does live transcription work with the Fast engine too?"
    answer: "Yes. The Fast engine has transcribed live for a while. What is new is that the All Languages engine, the one that covers 99 languages and the toughest audio, now does it too."
  - question: "Is live transcription less accurate?"
    answer: "For most dictation it produces the same text. A word is only committed once two consecutive passes over the audio agree on it. On very long recordings, transcribing everything at the end can still read slightly cleaner, which is why the toggle is there."
---

The slowest part of dictation is not the talking. It is the moment after you stop, when you are waiting for your words to show up.

Until now, EnviousWispr's All Languages engine handled that moment the traditional way: it collected your audio while you spoke, and when you released the key, it transcribed the whole thing in one pass. That works, and it is accurate. But the wait grows with the length of the dictation. Talk for two minutes and you wait for two minutes of audio to be processed. Talk through a whole idea, the way [an hour-long session](/blog/you-can-now-dictate-for-a-full-hour/) invites you to, and the pause at the end starts to pull you out of your flow.

In the latest update, the All Languages engine transcribes while you speak. When you stop, there is almost nothing left to do, so your text lands almost immediately, whether you spoke for ten seconds or ten minutes.

## How it works

While you are talking, the engine quietly transcribes the audio it has so far, over and over, every couple of seconds. Each new pass hears a little more than the last one.

Here is the part I find genuinely elegant. A word is only committed once two consecutive passes agree on it. If the engine hears "let's meet at the" on one pass and the next pass hears the same thing, those words are locked in. If the passes disagree, the words stay tentative, and the engine simply waits for more audio to make up its mind. As full sentences get confirmed, they are set aside as finished, so each new pass only works on the recent, still-open part of your speech and stays fast no matter how long you talk.

This approach comes from a research group at Charles University that studies live speech translation, where the same problem shows up in a harder form. Their method, called [whisper_streaming](https://github.com/ufal/whisper_streaming), is the design we adapted. We benchmarked it against other candidates on real dictation before picking it; it won on both speed and text quality.

By the time you release the key, nearly everything you said is already confirmed. The engine finishes the last unconfirmed words, and that is it. The end-of-dictation wait stops scaling with how long you spoke.

And if anything goes wrong mid-recording, the engine keeps your full audio on the side and falls back to transcribing it in one pass, the traditional way. You always get your text. The fast path is never allowed to put your words at risk.

## What Auto-detect language changes

There is one setting that turns this off on purpose: Auto-detect language.

Live transcription has to commit to a language on its very first pass, a second or two into your recording. That is almost no audio to judge from. If it guessed wrong there, every confirmed word after that would be in the wrong language, and confirmed words cannot be taken back.

So with Auto-detect on, EnviousWispr does the careful thing instead: it waits until you finish, listens to the whole recording, and decides the language with all the evidence in hand. You get the traditional end-of-recording wait, and in exchange you get the right language essentially every time. The app notes this right under the toggle, so it is never a mystery.

If you dictate in one language, the fix is simple: pick it. Settings, Transcription, Language. Locked to a specific language, the All Languages engine streams live.

Here is the full picture:

| Live transcription | Language setting | What you get |
|---|---|---|
| On | A specific language | Transcribes while you speak, near-instant finish |
| On | Auto-detect | Transcribes at the end, best language accuracy |
| Off | Either | Transcribes at the end |

## Why you might still turn it off

The toggle exists for a reason. On very long recordings, a single pass over the finished audio can produce slightly cleaner text, because the engine gets to hear everything with full context before writing anything down. If you regularly dictate long-form and care about every comma, try both and see which reads better for you. For everyday dictation, live transcription produces the same text and gives you the time back.

## Still on your Mac, in both modes

None of this changes where the work happens. Live or not, transcription runs entirely on your device, [with no upload, no server, and no account](/blog/macos-dictation-offline-private/). The audio from the microphone goes to the model running on your Mac's own chip and nowhere else. Live transcription changes when the work happens, not where.

If you have ever wondered why we care so much about squeezing speed out of local models, from [moving Whisper onto the GPU](/blog/whisperkit-neural-engine-to-gpu/) to this, it is because on-device is only a real alternative to the cloud if it also feels instant. This is one more piece of that.

Update to the latest version, or [download EnviousWispr free](https://enviouswispr.com/) if you have not tried it. Hold the key, talk as long as you like, and watch how little you wait.
