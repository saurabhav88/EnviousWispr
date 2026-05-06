---
title: "Dictate First Drafts That Sound Like You"
description: "Most dictation tools strip your voice. Here's how to dictate first drafts that keep your writing style intact using on-device polish and Custom prompts."
pubDate: 2026-03-14
updatedDate: 2026-04-04
tags: ["writing", "dictation", "workflow", "writing-style"]
draft: false
author: "Saurabh Vaish"
---

Every dictation tool on the market is lying to you about the same thing. They promise "natural-sounding text" and then hand you output that reads like it was written by a corporate chatbot. The filler words are gone, sure, but so is your voice, your rhythm, every stylistic choice that makes your writing yours.

The problem isn't speech-to-text accuracy. The problem is that most tools treat post-processing as "make it sound professional" instead of "make it sound like the person who said it."

That's a solvable problem, if the tool gives you control over what happens after transcription.

If you're new to EnviousWispr, the [getting started guide](/blog/getting-started-enviouswispr-under-2-minutes/) walks you through setup in under two minutes.

## Why Most Dictation Tools Strip Your Voice

Standard speech to text treats your words as data to be cleaned. The goal is "correct" text: grammatically inoffensive, uniformly punctuated, utterly generic. That's fine for transcribing a meeting. It's terrible for writing.

Writers don't want correct. They want *theirs*. Short fragments for emphasis. Em dashes instead of semicolons. A specific way of handling dialogue tags, or paragraphs that breathe a certain way. The raw transcription from any speech model is a starting point, not a finished product. Most tools don't give you any control over what happens between transcription and output.

That's the gap EnviousWispr fills.

## How EnviousWispr Keeps Your Voice Intact

EnviousWispr splits the work into two stages: transcription and post-processing. Transcription runs locally on your Mac using on-device speech recognition via Core ML. That gives you accurate raw text. Post-processing is where you shape it.

Here's what makes the difference for writers:

- **On-device polish that keeps your voice.** Your local LLM (Apple Intelligence, Ollama) or a cloud API (OpenAI, Gemini) cleans up the raw transcription: filler words go, punctuation gets fixed, structure tightens, but your contractions, sentence fragments, and rhythm stay intact. The default polish is tuned for natural-sounding output, not corporate sameness.
- **Custom prompts for explicit control.** When you want to lock in a specific style, write a Custom prompt and the polish step uses it for every dictation until you change it. Examples: "use em dashes, not semicolons", "keep sentence fragments, they're intentional", "format as Markdown with H2 headings".

You can change the Custom prompt as your task changes (drafting one minute, client-facing prose the next), and the polish step picks it up on your next dictation. You're in control.

For a deeper look at how the transcription and post-processing pipeline connects, see the [How It Works](/how-it-works/) page.

## Step-by-Step: Setting Up a Dictation Writing Workflow

Here's how to go from zero to dictating first drafts that actually sound like your writing.

### Step 1: Install EnviousWispr

Download the latest `.dmg` from the [GitHub releases page](https://github.com/saurabhav88/EnviousWispr/releases). Drag it to Applications. On first launch, macOS will ask for microphone and accessibility permissions; grant both.

No account. No API key. No subscription. It's free.

### Step 2: Set Up Polish (and a Custom Prompt If You Need One)

The speech model downloads automatically on first launch. Once that's done (a few minutes), open EnviousWispr's settings. The default polish is tuned to keep your voice intact while cleaning up filler words and punctuation. For most writing, that's the right starting point.

If you want to lock in a specific shape, write a Custom prompt. Pick whichever pattern matches what you're working on:

- "Keep my natural voice, contractions, and sentence rhythm. Don't formalize." For novels, blog drafts, freewriting.
- "Output clean, readable prose with light polish. Keep my voice." For newsletters and articles.
- "Tighten sentence structure, remove casual phrasing, produce polished prose." For academic papers, client deliverables.
- "Use em dashes instead of semicolons. Preserve sentence fragments when intentional." For specific style preferences.

The Custom prompt sticks until you change it.

Post-processing can run on-device (Apple Intelligence, Ollama) or through cloud APIs (OpenAI, Gemini). Your raw dictation never leaves your device unless you explicitly configure an external API.

### Step 3: Dictate Your First Draft

Hold your hotkey. Start talking. Don't edit in your head; just speak. Release the hotkey when you're done with a thought. A second or two later on Apple Silicon, polished text lands in your writing app, styled the way you specified.

That's it. No copying and pasting. No switching apps. The text pastes into the app that has focus, cleaned up according to your polish settings.

## What the Difference Actually Looks Like

Here's a concrete example. A writer dictating a blog intro:

**What you say:**
> okay so I want to start this piece by talking about how like most productivity advice is written by people who've never had a real creative block they just say write every day and do morning pages but that doesn't help when the problem isn't discipline it's that you're scared of writing something bad

**What gets pasted:**
> Most productivity advice is written by people who've never had a real creative block. "Write every day" and "do morning pages" sound reasonable, but they don't help when the problem isn't discipline. It's that you're scared of writing something bad.

The voice is the same. The mess is gone. And the writer didn't type a single character. The draft sounds like them, not like a template, not like an AI, but like the person who had the idea in the first place.

## Real Workflows: What This Looks Like in Practice

### Morning Pages in Ulysses

You open Ulysses. You hold the hotkey. You talk for three minutes about whatever's on your mind: messy, circular, half-formed. You release. The text appears in your editor with clean punctuation and paragraph breaks where you paused. The filler words are gone but your voice is still there. You didn't type a single character.

### Blog Drafting in iA Writer

You have an outline. You dictate each section, one hotkey press at a time. The polish step cleans up each chunk into prose that still sounds like you. Each dictation chunk lands in iA Writer ready to edit. By the time you've walked through your outline, you have a 1,200-word rough draft that took fifteen minutes instead of an hour.

### Quick Slack Replies Between Writing Sessions

You switch to Slack. The default polish keeps things conversational without over-formalizing. You dictate a reply to your editor. It reads like a quick message, not like a paragraph from your manuscript. Back to writing.

### Capturing Ideas on a Walk

You're away from your desk but your Mac Mini is running at home. You come back, sit down, double-press your hotkey to lock recording, and dump every idea you had on your walk. The post-processor cleans it up while keeping your natural phrasing: lightly polished, captured. You'll shape it later.

## Why Privacy Matters for Writers

Writers dictate sensitive material. Unpublished manuscripts. Client work under NDA. Personal essays. Journal entries. The idea of sending raw recordings of your creative process to a cloud server is, for many writers, a non-starter.

EnviousWispr processes everything on-device. Your recordings never leave your Mac. Transcription runs locally via on-device speech recognition and Core ML. Post-processing can run on-device as well. There's no server receiving your audio, no vendor storing your transcripts, no account tied to your creative output.

For a detailed look at how on-device processing compares to cloud alternatives, see our [on-device vs cloud dictation comparison](/blog/macos-dictation-offline-private/).

## Getting Past the "Dictation Doesn't Work for Me" Wall

Most writers who've tried dictation and quit had one of three problems:

1. **The output didn't sound like them.** Solved by an on-device polish step tuned to keep your voice, plus a Custom prompt for full control over processing instructions.
2. **Switching between contexts was tedious.** Edit the Custom prompt as your task changes; the polish step picks it up on your next dictation.
3. **Privacy concerns with cloud tools.** Solved by on-device processing that never phones home.

The first few sessions feel awkward. You'll over-explain, stumble, repeat yourself. That's normal. The post-processor catches most of it, and within a week you'll find a rhythm. Dictation isn't a replacement for writing; it's a way to get your first draft out of your head faster so you can spend your energy on editing, which is where the real writing happens anyway.

## Get Started

EnviousWispr is free and yours to keep. No strings.

1. [Download EnviousWispr free](/#download), or grab the latest release from [GitHub](https://github.com/saurabhav88/EnviousWispr/releases)
2. Leave polish on the default, or write a Custom prompt that matches your voice
3. Dictate your next first draft

## Related Posts

- [Dictation for Writers: Skip the Blank Page](/blog/dictation-for-writers-skip-blank-page/). How speaking your first draft bypasses writer's block entirely.
- [Voice to Prose: A Realistic Writing Workflow](/blog/voice-to-prose-writing-workflow/). A practical guide to building a full voice-to-prose session.
- [Dictate Meeting Notes to Polished Summaries on Mac](/blog/meeting-notes-polished-summaries/). Apply the same dictate-then-polish loop to post-meeting recaps and exec briefings.
- [On-Device vs Cloud Dictation: What Stays Private](/blog/macos-dictation-offline-private/). A fair comparison of where your recordings go.

Your words, your style, your Mac. Nothing leaves the building.

*Looking at other tools for writing? See [vs WisprFlow](/compare/wisprflow/), [vs VoiceInk](/compare/voiceink/), or [browse all comparisons](/compare/).*
