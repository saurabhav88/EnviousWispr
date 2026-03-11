---
title: "How to Take Lecture Notes by Speaking"
description: "Stop missing key points while typing. Use voice notes for students to capture lecture notes by speaking — free, private, and on-device."
pubDate: 2026-03-11
tags: ["students", "lecture-notes", "dictation", "how-to"]
draft: false
---

You know the feeling. The professor is three slides ahead, rattling off distinctions between concepts you're still trying to spell correctly. Your fingers are moving as fast as they can, but by the time you finish one sentence, you've missed the next two. Typing during lectures is a losing game — your attention splits between what's being said and what you're writing, and both suffer.

There's a better approach: take lecture notes by speaking. Instead of typing, you dictate quietly into your laptop's microphone and let transcription software turn your spoken words into organized text. It's faster, it keeps your eyes on the professor, and with the right setup, it costs you nothing.

Here's how to do it with EnviousWispr — a free, open-source dictation app that runs entirely on your Mac.

## Step 1: Install EnviousWispr in five minutes

Download the `.dmg` from the [releases page](https://github.com/saurabhav88/EnviousWispr/releases) and drag the app to your Applications folder. On first launch, macOS will ask for microphone access — grant it. Then pick a Whisper model. We recommend `large-v3-turbo` for the best balance of speed and accuracy on Apple Silicon.

The app will download and compile the model locally. This takes a few minutes the first time and never again after that.

It's free. No account walls, no trial periods. You're a student — your budget matters, and EnviousWispr is open source.

## Step 2: Turn on hands-free mode

For regular dictation, EnviousWispr uses a push-to-talk hotkey — hold to record, release to transcribe. That works great for quick notes, but during a lecture you don't want to hold down a key for 50 minutes.

Switch to **hands-free mode**. This tells EnviousWispr to transcribe continuously in the background. You speak, it listens and converts. No buttons, no interruptions. Just leave the app running and focus on the lecture.

Hands-free mode detects natural pauses in your speech, so each thought gets processed as its own chunk. You'll see transcribed text appear as you go.

## Step 3: Set up a custom prompt for lecture notes

Raw transcription is useful, but the real power for students is in post-processing. EnviousWispr runs your transcribed text through a local LLM that cleans it up — removing filler words like "um" and "uh," fixing punctuation, and formatting the output however you tell it to.

Set a custom prompt like:

> Format as bullet points. Bold key terms and definitions. Remove filler words.

Or for a more structured approach:

> Organize into sections by topic. Use bullet points for details. Bold vocabulary terms. Add a "Key Takeaways" section at the end.

This turns your raw dictation into study-ready notes — without you doing any manual formatting during the lecture. The speech to text study workflow becomes almost automatic.

You can experiment with different prompts depending on the class. A history lecture might benefit from chronological formatting, while a science class might need emphasis on formulas and processes.

## Step 4: Position your microphone and speak naturally

You don't need an external microphone. Your MacBook's built-in mic works fine in a lecture hall if you're speaking at a normal volume — which you should be doing anyway. Quiet dictation works. You're not giving a speech; you're murmuring your notes.

A few practical tips:

- **Sit where you can speak quietly without bothering anyone.** Back rows or corners work well. If your lecture hall is large, this is rarely an issue.
- **Speak in short, clear phrases.** You don't need to narrate everything the professor says. Capture the main point, then listen for the next one.
- **Paraphrase rather than transcribe verbatim.** Your own words stick in memory better, and the LLM cleanup handles the rest.
- **Don't worry about perfect speech.** That's what post-processing is for. Say "um" all you want — the LLM strips it out.

## Step 5: Review and clean up after the lecture

Even with a good custom prompt, your notes will benefit from a quick review. Here's an efficient post-lecture cleanup routine:

1. **Read through within 24 hours.** Research on memory consolidation says this matters. Your dictation lecture notes serve double duty — they're both a record and a review tool.
2. **Fix any transcription errors.** WhisperKit is accurate, but proper nouns and specialized terms sometimes get mangled. Correct them while the lecture is fresh.
3. **Add context you didn't dictate.** Diagrams from the board, slide numbers, or references the professor mentioned. Drop these in as annotations.
4. **Reorganize if needed.** Your custom prompt does most of the formatting, but you might want to merge related points or reorder sections.
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
5. Set a custom prompt for lecture formatting
6. Start your next lecture

## Related Posts

- [Write Your Essay Outline by Talking It Out](/blog/essay-outline-by-talking-it-out/) — use dictation to turn a one-minute ramble into a structured essay outline
- [Getting Started with EnviousWispr in Under 2 Minutes](/blog/getting-started-enviouswispr-under-2-minutes/) — full setup walkthrough from download to first dictation
- [On-Device vs Cloud Dictation: What Stays Private](/blog/on-device-vs-cloud-dictation-privacy/) — why your academic work stays safer with on-device processing

That's it. No sign-up, no credit card, no trial period. Just a dictation tool that runs on your Mac and stays out of your way. Your notes will thank you.
