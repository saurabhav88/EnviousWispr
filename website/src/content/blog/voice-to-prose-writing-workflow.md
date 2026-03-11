---
title: "Voice to Prose: A Realistic Writing Workflow"
description: "A practical guide to building a voice-to-prose workflow with on-device dictation. Real examples, honest limitations, and setup tips for writers."
pubDate: 2026-03-11
tags: ["writing", "workflow", "dictation", "custom-prompts"]
draft: false
---

Here's what a real voice-to-prose session looks like. Not the polished demo version -- the actual experience of drafting a blog post by talking to your Mac at 9am with coffee in hand.

You open your writing app. You hold a hotkey. You start talking -- half-formed thoughts, run-on sentences, the occasional "um" and "wait, scratch that." You release the hotkey. A second or two later, a cleaned-up paragraph appears in your editor. You read it, tweak a few words, and hit the hotkey again for the next section.

That's it. No elaborate setup ritual, no cloud account, no waiting for a server to respond. Just speech turning into a workable first draft, one chunk at a time.

## How the pipeline works

Understanding what happens between your voice and the finished text helps you get better results. EnviousWispr runs a three-stage pipeline, entirely on your Mac:

1. **Record** -- hold the hotkey, speak, release. The app captures raw audio from your microphone.
2. **Transcribe** -- your speech is converted to text locally via Core ML, using either Parakeet for fast English dictation or WhisperKit for multi-language support. This is a literal transcription -- every filler word, false start, and repeated phrase comes through.
3. **Post-process** -- a local LLM cleans up the raw transcription. It strips filler words, fixes punctuation, corrects grammar, and reshapes the text according to your custom prompt.

The third step is where the writing happens. Raw transcription is messy. Post-processing is what turns "so basically what I'm trying to say is that like the pipeline has three steps and each one does a different thing" into a coherent sentence. You can read more about the technical details on the [How It Works](/how-it-works/) page.

The whole cycle takes a second or two on Apple Silicon. Fast enough that you don't lose your train of thought waiting for output.

## Setting up custom prompts for prose

The default post-processing prompt does a solid job: it removes filler words, fixes punctuation, and produces clean sentences. But writers need more control. That's what custom prompts are for.

A custom prompt tells the local LLM how to handle your transcription. You're not limited to cleanup -- you can shape the output to match your writing style, voice, and intent.

### A prompt for blog drafting

Here's a prompt that works well for first-draft blog content:

> Clean up this dictation for a blog post. Remove filler words and false starts. Fix punctuation and grammar. Keep my natural voice and sentence rhythm -- don't make it sound corporate or formal. Preserve my word choices where they work. Break into paragraphs at natural topic shifts. Do not add information I didn't say.

That last instruction matters. You don't want the LLM inventing points you didn't make. A good prompt constrains the cleanup to what you actually said.

### A prompt for fiction dialogue

If you're drafting dialogue for a story:

> This is dictated fiction dialogue. Preserve the speaking patterns, contractions, and sentence fragments -- they're intentional. Fix only obvious transcription errors. Add dialogue punctuation (em-dashes for interruptions, ellipses for trailing off). Keep each character's lines on separate paragraphs.

### A prompt for journaling

For freewriting sessions where you want minimal interference:

> Light cleanup only. Remove "um", "uh", and obvious repetitions. Fix punctuation. Do not restructure sentences or change word choices. Keep the raw, conversational feel.

The point is this: you dictate once, but you can shape the output in completely different ways depending on the prompt. If you use [per-app presets](/how-it-works/), you can assign different prompts to different apps -- so dictation into Ulysses gets your blog prompt while dictation into a notes app gets the light-cleanup version.

## A realistic example: before and after

Here's what this actually looks like in practice. The following is a raw transcription of someone dictating a section about morning routines:

### Raw transcription (what you actually said)

> So I've been thinking about like morning routines and how um most of the advice out there is kind of the same stuff right like wake up early meditate journal exercise and I'm not saying that's wrong but the thing is what works for one person might not work for someone else and I think the the real key is actually figuring out what makes you feel ready for the day rather than just copying what some CEO does because like their life is completely different from yours and uh yeah I think people should experiment more and not feel bad if they don't want to wake up at five am

### After post-processing (what lands in your editor)

> I've been thinking about morning routines and how most of the advice out there covers the same territory -- wake up early, meditate, journal, exercise. I'm not saying that's wrong. But what works for one person might not work for someone else.
>
> The real key is figuring out what makes you feel ready for the day, rather than copying what some CEO does. Their life is completely different from yours. People should experiment more and not feel bad if they don't want to wake up at 5am.

That's roughly 500 words of dictation compressed into a tight, readable paragraph pair. The voice is preserved. The filler is gone. The structure is cleaner. And you didn't type a single character.

This is what makes dictation practical for real writing work -- the post-processing step bridges the gap between how people talk and how people write.

## Building a session rhythm

Once the pipeline feels natural, the real productivity comes from how you structure your sessions. Here's what works:

### Think in chunks, not full articles

Don't try to dictate an entire 1,500-word post in one take. Dictate a section at a time -- a single argument, one anecdote, a few related points. Review what the LLM gave you. Adjust if needed. Then dictate the next chunk.

This mirrors how most writers actually work. The hotkey-based flow supports it naturally: hold, speak a section, release, review, repeat.

### Use hands-free mode for freewriting

When you're brainstorming or working through ideas, switch to hands-free mode. It transcribes continuously in the background without you holding any keys. Pace around the room, talk through your argument, let the ideas come without stopping to check output.

Come back later and edit the transcript into something usable. This is especially good for working through writer's block -- it's harder to stare at a blank page when words are appearing on screen as you think out loud.

### Edit after, not during

Resist the urge to fix every sentence as it appears. Dictate your full section first, then go back and edit. The point of voice drafting is to separate generation from editing. If you stop to rephrase after every paragraph, you lose the speed advantage.

## When dictation works -- and when it doesn't

Honest take: dictation is not better than typing for everything. Here's where each one wins.

### Dictation wins when

- **You're generating first drafts.** Getting ideas out of your head and onto the page is dramatically faster by voice. Most people speak 3-4x faster than they type.
- **You're working through arguments.** Talking through a point helps clarify thinking in a way that staring at a cursor doesn't.
- **Your hands hurt.** RSI is real. Dictation gives your wrists a break without stopping your output. We wrote a full guide on [voice input for RSI](/blog/voice-input-rsi-keyboard-free-workflow/) if that's your situation.
- **You're away from the keyboard.** Pacing, standing, stretching -- you can keep working without being chained to a desk.

### Typing wins when

- **You're doing precise editing.** Moving sentences around, swapping individual words, adjusting formatting -- this is mouse-and-keyboard territory.
- **You're writing code or technical syntax.** Even with per-app presets, dictating variable names and brackets is slower than typing them.
- **You're in a noisy environment.** Background noise degrades transcription accuracy. A quiet room produces much better results.
- **You need exact formatting.** Tables, nested lists, specific markdown structures -- speak the content, type the formatting.

The best workflow uses both. Dictate the rough draft. Type the edits. That's the combination that saves the most time for most writers.

## Getting started

Download EnviousWispr from the [releases page](https://github.com/saurabhav88/EnviousWispr/releases). It's free, open source, and takes a couple minutes to set up. On first launch, grant microphone access and pick a Whisper model -- `large-v3-turbo` gives you the best balance of speed and accuracy on Apple Silicon.

Then try this: open whatever you're working on, hold the hotkey, and talk through your next paragraph. See what comes back. Adjust your custom prompt until the output matches how you write.

## Related Posts

- [Dictate First Drafts That Sound Like You](/blog/dictate-first-drafts-sound-like-you/) — how custom prompts preserve your writing voice during dictation
- [Dictation for Writers: Skip the Blank Page](/blog/dictation-for-writers-skip-blank-page/) — why speaking bypasses writer's block
- [Getting Started with EnviousWispr in Under 2 Minutes](/blog/getting-started-enviouswispr-under-2-minutes/) — full setup walkthrough from download to first dictation

You might be surprised how quickly it becomes part of how you draft. Not a replacement for typing -- just a faster way to get the first version out of your head and onto the page.
