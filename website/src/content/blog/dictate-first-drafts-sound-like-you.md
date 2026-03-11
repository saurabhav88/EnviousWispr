---
title: "Dictate First Drafts That Sound Like You"
description: "Most dictation tools strip your voice. Here's how to dictate first drafts that keep your writing style intact using custom prompts and per-app presets."
pubDate: 2026-03-11
tags: ["writing", "dictation", "workflow", "custom-prompts"]
draft: false
---

You dictate a paragraph. You look at the screen. It reads like a robot wrote it -- flat, lifeless, scrubbed of every quirk that makes your writing yours. The punctuation is wrong. The sentence rhythm is off. The filler words are gone but so is your voice.

This is the experience most writers have with dictation software, and it's why so many give up on voice-to-text entirely. They go back to typing, back to the blinking cursor, back to wrist pain and slow first drafts.

It doesn't have to work that way.

If you're new to EnviousWispr, the [getting started guide](/blog/getting-started-enviouswispr-under-2-minutes/) walks you through setup in under two minutes.

## Why Most Dictation Tools Strip Your Voice

Standard speech to text treats your words as data to be cleaned. The goal is "correct" text -- grammatically inoffensive, uniformly punctuated, utterly generic. That's fine for transcribing a meeting. It's terrible for writing.

Writers don't want correct. They want *theirs*. Short fragments for emphasis. Em dashes instead of semicolons. A specific way of handling dialogue tags, or paragraphs that breathe a certain way. The raw transcription from any Whisper-based model is a starting point, not a finished product -- and most tools don't give you any control over what happens between transcription and output.

That's the gap EnviousWispr fills.

## How EnviousWispr Keeps Your Voice Intact

EnviousWispr splits the work into two stages: transcription and post-processing. Transcription runs locally on your Mac using either Parakeet (fast, streaming English) or WhisperKit (multi-language via Apple's Whisper model) — both execute natively via Core ML. That gives you accurate raw text. Post-processing is where you shape it.

Here's what makes the difference for writers:

- **Custom prompts** -- you write the instructions for how your speech gets cleaned up. Want em dashes? Say so. Want sentence fragments preserved? Tell it. Want everything formatted as Markdown with H2 headings? Done.
- **Per-app presets** -- different processing rules for different apps. Your writing app gets full prose with your preferred style. Slack gets casual. Your notes app gets raw, unpolished stream of consciousness.

This isn't "smart adaptive context." It's a text field where you type what you want, and the post-processor follows your instructions. You're in control.

For a deeper look at how the transcription and post-processing pipeline connects, see the [How It Works](/how-it-works/) page.

## Step-by-Step: Setting Up a Dictation Writing Workflow

Here's how to go from zero to dictating first drafts that actually sound like your writing.

### Step 1: Install EnviousWispr

Download the latest `.dmg` from the [GitHub releases page](https://github.com/saurabhav88/EnviousWispr/releases). Drag it to Applications. On first launch, macOS will ask for microphone and accessibility permissions -- grant both.

No account. No API key. No subscription. It's free and open source.

### Step 2: Choose Your Whisper Model

Open EnviousWispr's settings and pick a model size. For writing, accuracy matters more than raw speed, so `large-v3-turbo` is a solid default. The first model download takes a few minutes. After that, you're done.

On Apple Silicon, even the larger models transcribe in a second or two. The Neural Engine handles the heavy lifting.

### Step 3: Write Your Custom Prompt

This is where it gets interesting. Open the post-processing settings and write a prompt that describes your writing style. Be specific. Here are some starting points:

**For a novelist who writes in short, punchy sentences:**
> Clean up filler words. Keep sentence fragments -- they're intentional. Use em dashes, not semicolons. Don't add words I didn't say. Preserve my paragraph breaks.

**For a blogger who writes conversationally:**
> Fix punctuation and capitalization. Keep contractions. Remove "um" and "uh" but leave casual phrasing intact. Format as Markdown with paragraph breaks. Don't formalize my tone.

**For a journalist drafting notes:**
> Minimal cleanup. Fix obvious transcription errors. Keep it rough -- I'll edit later. No formatting, no structure changes. Just accurate raw text.

The prompt runs through your local LLM of choice, so it stays on your Mac. Your writing style instructions, your raw dictation -- none of it leaves your device unless you explicitly configure an external API.

### Step 4: Set Up Per-App Presets

If you write in multiple apps, per-app presets save you from switching prompts manually. Open EnviousWispr's preset settings and create one for each app:

- **Ulysses / iA Writer / Scrivener** -- full prose mode with your custom style prompt, Markdown output
- **Slack / Messages** -- casual, short, no Markdown formatting
- **Notes / Obsidian** -- raw capture, minimal cleanup, preserve everything

When you dictate, EnviousWispr detects which app has focus and applies the right preset automatically. You speak into Ulysses one way and Slack another without touching a single setting.

### Step 5: Dictate Your First Draft

Hold your hotkey. Start talking. Don't edit in your head -- just speak. Release the hotkey when you're done with a thought. A second or two later on Apple Silicon, polished text lands in your writing app, styled the way you specified.

That's it. No copying and pasting. No switching apps. The text pastes into the app that has focus, formatted according to your preset.

## Real Workflows: What This Looks Like in Practice

### Morning Pages in Ulysses

You open Ulysses. You hold the hotkey. You talk for three minutes about whatever's on your mind -- messy, circular, half-formed. You release. The text appears in your editor with clean punctuation, your preferred em dash style, and paragraph breaks where you paused. The filler words are gone but your voice is still there. You didn't type a single character.

### Blog Drafting in iA Writer

You have an outline. You dictate each section, one hotkey press at a time. Your custom prompt formats everything as Markdown with H2 headings. Each dictation chunk lands in iA Writer ready to edit. By the time you've walked through your outline, you have a 1,200-word rough draft that took fifteen minutes instead of an hour.

### Quick Slack Replies Between Writing Sessions

You switch to Slack. Your per-app preset kicks in -- casual tone, no Markdown, short and direct. You dictate a reply to your editor. It reads like a quick message, not like a paragraph from your manuscript. Back to writing.

### Capturing Ideas on a Walk

You're away from your desk but your Mac is open at home with hands-free mode running. You come back, sit down, hold the hotkey, and dump every idea you had on your walk. The post-processor cleans it up according to your notes preset -- rough, barely formatted, but captured. You'll shape it later.

## Why Privacy Matters for Writers

Writers dictate sensitive material. Unpublished manuscripts. Client work under NDA. Personal essays. Journal entries. The idea of sending raw recordings of your creative process to a cloud server is, for many writers, a non-starter.

EnviousWispr processes everything on-device. Your recordings never leave your Mac. Transcription runs locally via WhisperKit and Core ML. Post-processing runs through your local LLM. There's no server receiving your audio, no vendor storing your transcripts, no account tied to your creative output.

If you're working on something sensitive, you can also pause processing entirely with a single click. When you unpause, everything picks back up where you left off. For a detailed look at how on-device processing compares to cloud alternatives, see our [on-device vs cloud dictation comparison](/blog/on-device-vs-cloud-dictation-privacy/).

## Getting Past the "Dictation Doesn't Work for Me" Wall

Most writers who've tried dictation and quit had one of three problems:

1. **The output didn't sound like them** -- solved by custom prompts that encode your style
2. **Switching between apps was tedious** -- solved by per-app presets that auto-detect context
3. **Privacy concerns with cloud tools** -- solved by on-device processing that never phones home

The first few sessions feel awkward. You'll over-explain, stumble, repeat yourself. That's normal. The post-processor catches most of it, and within a week you'll find a rhythm. Dictation isn't a replacement for writing -- it's a way to get your first draft out of your head faster so you can spend your energy on editing, which is where the real writing happens anyway.

## Get Started

EnviousWispr is free, open source, and yours to keep -- no strings.

1. Download the latest release from [GitHub](https://github.com/saurabhav88/EnviousWispr/releases)
2. Write a custom prompt that matches your voice
3. Dictate your next first draft

## Related Posts

- [Dictation for Writers: Skip the Blank Page](/blog/dictation-for-writers-skip-blank-page/) — how speaking your first draft bypasses writer's block entirely
- [Voice to Prose: A Realistic Writing Workflow](/blog/voice-to-prose-writing-workflow/) — a practical guide to building a full voice-to-prose session
- [On-Device vs Cloud Dictation: What Stays Private](/blog/on-device-vs-cloud-dictation-privacy/) — a fair comparison of where your recordings go

Your words, your style, your Mac. Nothing leaves the building.
