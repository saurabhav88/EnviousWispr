---
title: "How to Take Lecture Notes by Speaking on Mac"
description: "Stop missing key points while typing. Use voice notes for students to capture lecture notes by speaking — free, private, and on-device."
pubDate: 2026-03-18
tags: ["students", "lecture-notes", "dictation", "how-to"]
draft: true
---

It's a 9 AM organic chemistry lecture. The professor is three slides ahead, rattling off the difference between SN1 and SN2 mechanisms while you're still trying to spell "nucleophilic." Your fingers are moving as fast as they can, but by the time you finish one sentence, you've missed the next two. You look at your notes after class and half of them are gibberish.

Here's the thing: you could have captured better notes by whispering them. Speaking is faster than typing, it keeps your eyes on the slides instead of the keyboard, and with the right tool, your spoken notes come back cleaned up and formatted -- for free.

Here's how to set that up with EnviousWispr, a free, open-source dictation app that runs entirely on your Mac.

## Step 1: Install EnviousWispr in five minutes

Download the `.dmg` from the [releases page](https://github.com/saurabhav88/EnviousWispr/releases) and drag the app to your Applications folder. On first launch, macOS will ask for microphone access — grant it. Then pick a Whisper model. We recommend `large-v3-turbo` for the best balance of speed and accuracy on Apple Silicon.

The app will download and compile the model locally. This takes a few minutes the first time and never again after that.

It's free. No account walls, no trial periods. You're a student — your budget matters, and EnviousWispr is open source.

<!-- TODO: Screenshot — Hands-free mode indicator: the recording overlay showing hands-free/locked mode active for continuous lecture capture -->

## Step 2: Turn on hands-free mode

For regular dictation, EnviousWispr uses a push-to-talk hotkey — hold to record, release to transcribe. That works great for quick notes, but during a lecture you don't want to hold down a key for 50 minutes.

Switch to **hands-free mode**. This tells EnviousWispr to transcribe continuously in the background. You speak, it listens and converts. No buttons, no interruptions. Just leave the app running and focus on the lecture.

Hands-free mode detects natural pauses in your speech, so each thought gets processed as its own chunk. You'll see transcribed text appear as you go.

<!-- TODO: Screenshot — Writing style presets: the settings UI showing Formal, Standard, and Friendly preset options -->

## Step 3: Pick the right writing style preset

Raw transcription is useful, but the real power for students is in post-processing. EnviousWispr runs your transcribed text through a local LLM that cleans it up — removing filler words like "um" and "uh," fixing punctuation, and producing polished output.

The app ships with three writing style presets — Formal, Standard, and Friendly. For lecture notes, **Standard** works well: it cleans up your speech into clear, well-punctuated prose without making it overly stiff.

Custom prompts — where you could tell the LLM to format output as bullet points, bold key terms, or organize by topic — are on the roadmap. Once that ships, you'll be able to tailor post-processing per class (chronological formatting for history, emphasis on formulas for science). For now, the built-in presets already turn your raw dictation into clean, readable notes without any manual formatting during the lecture.

## Step 4: Position your microphone and speak naturally

You don't need an external microphone. Your MacBook Air's built-in mic works fine in a lecture hall if you're speaking at a normal volume — which you should be doing anyway. Quiet dictation works. You're not giving a speech; you're murmuring your notes.

A few practical tips:

- **Sit where you can speak quietly without bothering anyone.** Back rows or corners work well. If your lecture hall is large, this is rarely an issue.
- **Speak in short, clear phrases.** You don't need to narrate everything the professor says. Capture the main point, then listen for the next one.
- **Paraphrase rather than transcribe verbatim.** Your own words stick in memory better, and the LLM cleanup handles the rest.
- **Don't worry about perfect speech.** That's what post-processing is for. Say "um" all you want — the LLM strips it out.

Here's what this looks like in practice — whispering notes during a chemistry lecture:

**What you say:**
> okay so SN1 reactions happen in two steps first the leaving group leaves and forms a carbocation intermediate and then the nucleophile attacks um it's favored by tertiary substrates and polar protic solvents and the rate only depends on the substrate concentration not the nucleophile

**What gets pasted:**
> **SN1 Reactions**
> - Two-step mechanism: leaving group departs first, forming a carbocation intermediate, then the nucleophile attacks
> - Favored by: tertiary substrates, polar protic solvents
> - Rate = first-order (depends only on substrate concentration, not nucleophile)

Ten seconds of whispering captured what would have taken a minute of frantic typing — and the LLM post-processing cleaned it up into study-ready notes automatically. Walking out of a lecture with complete, polished notes instead of a half-finished mess changes how you feel about the whole class.

## Step 5: Review and clean up after the lecture

Even with clean post-processing, your notes will benefit from a quick review. Here's an efficient post-lecture cleanup routine:

1. **Read through within 24 hours.** Research on memory consolidation says this matters. Your dictation lecture notes serve double duty — they're both a record and a review tool.
2. **Fix any transcription errors.** WhisperKit is accurate, but proper nouns and specialized terms sometimes get mangled. Correct them while the lecture is fresh.
3. **Add context you didn't dictate.** Diagrams from the board, slide numbers, or references the professor mentioned. Drop these in as annotations.
4. **Reorganize if needed.** The LLM cleanup handles the basics, but you might want to merge related points or reorder sections.
5. **Highlight what you don't understand.** Mark anything confusing now so you know what to ask about in office hours.

This review step takes 10-15 minutes and dramatically improves how much you retain.

## Why this beats typing (and other voice tools)

Taking lecture notes by speaking instead of typing keeps your attention where it belongs — on the lecture. You're listening and capturing simultaneously, instead of splitting focus between comprehension and keyboard mechanics.

And unlike cloud-based dictation tools, EnviousWispr processes everything on-device. Your recordings never leave your Mac. For students, this matters in two concrete ways:

- **No data concerns.** Your academic work, study notes, and spoken thoughts don't get uploaded to anyone's servers. Transcription runs locally using WhisperKit via Core ML.
- **No recurring cost.** Most cloud speech-to-text services charge per minute of audio or require a monthly subscription. EnviousWispr is free. You can learn more about [how the transcription pipeline works](/how-it-works/) if you're curious about the technical details.

## Getting started

If you're ready to try voice notes for students, the setup takes less than five minutes:

1. Download EnviousWispr from the [releases page](https://github.com/saurabhav88/EnviousWispr/releases)
2. Grant microphone access on first launch
3. Choose the `large-v3-turbo` model
4. Turn on hands-free mode
5. Pick a writing style preset
6. Start your next lecture

## Related Posts

- [Write Your Essay Outline by Talking It Out](/blog/essay-outline-by-talking-it-out/) — use dictation to turn a one-minute ramble into a structured essay outline
- [Getting Started with EnviousWispr in Under 2 Minutes](/blog/getting-started-enviouswispr-under-2-minutes/) — full setup walkthrough from download to first dictation
- [On-Device vs Cloud Dictation: What Stays Private](/blog/on-device-vs-cloud-dictation-privacy/) — why your academic work stays safer with on-device processing

That's it. No sign-up, no credit card, no trial period. Just a dictation tool that runs on your Mac — macOS Sonoma or later — and stays out of your way. Your notes will thank you.
