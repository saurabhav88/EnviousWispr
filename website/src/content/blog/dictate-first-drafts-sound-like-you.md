---
title: "Dictate First Drafts That Sound Like You"
description: "Most dictation tools strip your voice. Here's how to dictate first drafts that keep your writing style intact using writing style presets and LLM post-processing."
pubDate: 2026-03-14
tags: ["writing", "dictation", "workflow", "writing-style"]
draft: false
---

Every dictation tool on the market is lying to you about the same thing. They promise "natural-sounding text" and then hand you output that reads like it was written by a corporate chatbot. The filler words are gone, sure -- but so is your voice, your rhythm, every stylistic choice that makes your writing yours.

The problem isn't speech-to-text accuracy. The problem is that most tools treat post-processing as "make it sound professional" instead of "make it sound like the person who said it."

That's a solvable problem -- if the tool gives you control over what happens after transcription.

If you're new to EnviousWispr, the [getting started guide](/blog/getting-started-enviouswispr-under-2-minutes/) walks you through setup in under two minutes.

## Why Most Dictation Tools Strip Your Voice

Standard speech to text treats your words as data to be cleaned. The goal is "correct" text -- grammatically inoffensive, uniformly punctuated, utterly generic. That's fine for transcribing a meeting. It's terrible for writing.

Writers don't want correct. They want *theirs*. Short fragments for emphasis. Em dashes instead of semicolons. A specific way of handling dialogue tags, or paragraphs that breathe a certain way. The raw transcription from any Whisper-based model is a starting point, not a finished product -- and most tools don't give you any control over what happens between transcription and output.

That's the gap EnviousWispr fills.

## How EnviousWispr Keeps Your Voice Intact

EnviousWispr splits the work into two stages: transcription and post-processing. Transcription runs locally on your Mac using either Parakeet (fast, streaming English) or WhisperKit (multi-language via Apple's Whisper model) — both execute natively via Core ML. That gives you accurate raw text. Post-processing is where you shape it.

Here's what makes the difference for writers:

- **Writing style presets** -- three built-in modes that shape how the LLM cleans up your dictation. **Friendly** keeps your natural voice and conversational rhythm intact -- contractions, sentence fragments, the way you actually talk. **Standard** gives you clean, balanced prose. **Formal** tightens everything up for professional or academic contexts.
- **LLM post-processing** -- your local LLM (or an external API if you choose) handles the cleanup. It strips filler words, fixes punctuation, and reshapes the text according to whichever preset you've selected. The result sounds like you wrote it, not like a template.

Switching presets takes one click, so you can move between freewriting and polished output without changing how you speak. You're in control.

> **On the roadmap:** Custom prompts will let you write your own post-processing instructions -- things like "use em dashes, not semicolons" or "format as Markdown with H2 headings." And per-app presets will auto-detect which app has focus and apply different rules automatically, so your writing app gets full prose while Slack gets casual short-form text.

For a deeper look at how the transcription and post-processing pipeline connects, see the [How It Works](/how-it-works/) page.

## Step-by-Step: Setting Up a Dictation Writing Workflow

Here's how to go from zero to dictating first drafts that actually sound like your writing.

### Step 1: Install EnviousWispr

Download the latest `.dmg` from the [GitHub releases page](https://github.com/saurabhav88/EnviousWispr/releases). Drag it to Applications. On first launch, macOS will ask for microphone and accessibility permissions -- grant both.

No account. No API key. No subscription. It's free and open source.

### Step 2: Choose Your Whisper Model

Open EnviousWispr's settings and pick a model size. For writing, accuracy matters more than raw speed, so `large-v3-turbo` is a solid default. The first model download takes a few minutes. After that, you're done.

On Apple Silicon, even the larger models transcribe in a second or two — I've tested this on both an M2 MacBook Air and an M3 MacBook Pro with near-identical speed. The Neural Engine handles the heavy lifting.

### Step 3: Pick Your Writing Style Preset

<!-- TODO: Screenshot — Writing style presets: the settings UI showing Formal, Standard, and Friendly preset options -->

This is where it gets interesting. Open EnviousWispr's settings and choose the writing style preset that matches what you're working on:

**Friendly** -- for novelists, bloggers, and freewriters who want their natural voice preserved. Filler words go away, but contractions, casual phrasing, and your sentence rhythm stay intact.

**Standard** -- the balanced middle ground. Clean, readable prose that works for newsletters, articles, and general drafting. Your voice comes through, just a bit more polished.

**Formal** -- for academic papers, client deliverables, and professional correspondence. Tighter sentence structure, no casual phrasing, polished output.

All processing runs through your local LLM of choice, so it stays on your Mac. Your raw dictation never leaves your device unless you explicitly configure an external API.

> **Coming soon:** Custom prompts will let you write your own post-processing instructions for even finer control -- things like "use em dashes, not semicolons" or "keep sentence fragments, they're intentional." And per-app presets will auto-detect which app has focus and apply different rules automatically, so Ulysses gets your prose style while Slack gets casual short-form text.

### Step 4: Dictate Your First Draft

Hold your hotkey. Start talking. Don't edit in your head -- just speak. Release the hotkey when you're done with a thought. A second or two later on Apple Silicon, polished text lands in your writing app, styled the way you specified.

That's it. No copying and pasting. No switching apps. The text pastes into the app that has focus, cleaned up according to your chosen writing style.

## What the Difference Actually Looks Like

Here's a concrete example. A writer dictating a blog intro:

**What you say:**
> okay so I want to start this piece by talking about how like most productivity advice is written by people who've never had a real creative block they just say write every day and do morning pages but that doesn't help when the problem isn't discipline it's that you're scared of writing something bad

**What gets pasted:**
> Most productivity advice is written by people who've never had a real creative block. "Write every day" and "do morning pages" sound reasonable -- but they don't help when the problem isn't discipline. It's that you're scared of writing something bad.

The voice is the same. The mess is gone. And the writer didn't type a single character. The draft sounds like them -- not like a template, not like an AI, but like the person who had the idea in the first place.

## Real Workflows: What This Looks Like in Practice

### Morning Pages in Ulysses

You open Ulysses. You hold the hotkey. You talk for three minutes about whatever's on your mind -- messy, circular, half-formed. You release. The text appears in your editor with clean punctuation and paragraph breaks where you paused. The filler words are gone but your voice is still there. You didn't type a single character.

### Blog Drafting in iA Writer

You have an outline. You dictate each section, one hotkey press at a time. Your writing style preset cleans up each chunk into polished prose. Each dictation chunk lands in iA Writer ready to edit. By the time you've walked through your outline, you have a 1,200-word rough draft that took fifteen minutes instead of an hour.

### Quick Slack Replies Between Writing Sessions

You switch to Slack. You flip your preset to Friendly -- casual tone, natural phrasing. You dictate a reply to your editor. It reads like a quick message, not like a paragraph from your manuscript. Back to writing. One click to switch presets, no friction.

### Capturing Ideas on a Walk

You're away from your desk but your Mac Mini is running at home with hands-free mode on. You come back, sit down, hold the hotkey, and dump every idea you had on your walk. The post-processor cleans it up with your Friendly preset -- natural, lightly polished, captured. You'll shape it later.

## Why Privacy Matters for Writers

Writers dictate sensitive material. Unpublished manuscripts. Client work under NDA. Personal essays. Journal entries. The idea of sending raw recordings of your creative process to a cloud server is, for many writers, a non-starter.

EnviousWispr processes everything on-device. Your recordings never leave your Mac. Transcription runs locally via WhisperKit and Core ML. Post-processing runs through your local LLM. There's no server receiving your audio, no vendor storing your transcripts, no account tied to your creative output.

For a detailed look at how on-device processing compares to cloud alternatives, see our [on-device vs cloud dictation comparison](/blog/macos-dictation-offline-private/).

## Getting Past the "Dictation Doesn't Work for Me" Wall

Most writers who've tried dictation and quit had one of three problems:

1. **The output didn't sound like them** -- solved by writing style presets that match your tone (and custom prompts are coming soon for even finer control)
2. **Switching between contexts was tedious** -- one-click preset switching makes it fast today, and per-app presets on the roadmap will make it automatic
3. **Privacy concerns with cloud tools** -- solved by on-device processing that never phones home

The first few sessions feel awkward. You'll over-explain, stumble, repeat yourself. That's normal. The post-processor catches most of it, and within a week you'll find a rhythm. Dictation isn't a replacement for writing -- it's a way to get your first draft out of your head faster so you can spend your energy on editing, which is where the real writing happens anyway.

## Get Started

EnviousWispr is free, open source, and yours to keep -- no strings.

1. Download the latest release from [GitHub](https://github.com/saurabhav88/EnviousWispr/releases)
2. Pick the writing style preset that matches your voice -- Friendly, Standard, or Formal
3. Dictate your next first draft

## Related Posts

- [Dictation for Writers: Skip the Blank Page](/blog/dictation-for-writers-skip-blank-page/) — how speaking your first draft bypasses writer's block entirely
- [Voice to Prose: A Realistic Writing Workflow](/blog/voice-to-prose-writing-workflow/) — a practical guide to building a full voice-to-prose session
- [On-Device vs Cloud Dictation: What Stays Private](/blog/macos-dictation-offline-private/) — a fair comparison of where your recordings go

Your words, your style, your Mac. Nothing leaves the building.
