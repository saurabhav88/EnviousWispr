---
title: "Welcome to EnviousWispr"
description: "Introducing EnviousWispr — private AI dictation for macOS. Learn what makes it different."
pubDate: 2026-03-21
tags: ["announcement", "privacy", "dictation"]
draft: false
---

What if you didn't have to choose between fast dictation and private dictation? What if a single tool could give you both -- cloud-quality transcription speed with the guarantee that your recordings never leave your Mac?

That's the question we kept asking, and it's why we built EnviousWispr.

EnviousWispr runs entirely on your Mac. Your voice recordings never leave your device. Transcription happens locally using [WhisperKit](https://github.com/argmaxinc/WhisperKit), which runs Apple's Whisper model natively via Core ML. Post-processing — correcting punctuation, cleaning up filler words, adjusting tone — also runs on-device via your local LLM of choice. From microphone to clipboard, nothing touches the internet unless you explicitly configure an external API.

## What it does

The workflow is intentionally simple: hold a hotkey, speak, release. EnviousWispr records your audio, transcribes it, runs it through the post-processing pipeline, and places polished text on your clipboard — or pastes it directly into whatever app has focus. The whole cycle takes a second or two on Apple Silicon.

Here's what that looks like:

**What you say:**
> hey just wanted to follow up on the design review from this morning um the team agreed to go with the simplified navigation and we're cutting the sidebar for now Alex is going to update the mockups by Thursday and I'll schedule a final review for Friday afternoon

**What gets pasted:**
> Following up on this morning's design review. The team agreed to go with simplified navigation — the sidebar is cut for now. Alex will update the mockups by Thursday, and I'll schedule a final review for Friday afternoon.

Spoken in ten seconds. Polished, structured, ready to send — and your audio never left your Mac.

<!-- TODO: Screenshot — Recording state: the menu bar icon and recording overlay showing EnviousWispr actively transcribing speech -->

A few things that make it worth using day-to-day:

- **Hands-free mode** — set it to transcribe continuously in the background, no hotkey required
- **Writing style presets** — choose between Formal, Standard, and Friendly to control the tone of your output
- **Custom prompts** (coming soon) — tell the post-processor to write in your style, translate on the fly, or format output as bullet points
- **Per-app presets** (coming soon) — different rules for Slack vs. Terminal vs. Notes.app vs. your writing app, applied automatically

## Getting started

Download the `.dmg` from the [releases page](https://github.com/saurabhav88/EnviousWispr/releases), open it, and drag EnviousWispr to your Applications folder. On first launch you'll grant microphone access and choose a Whisper model — we recommend `large-v3-turbo` for the best balance of speed and accuracy on any M-series Mac running macOS Sonoma or later. The app will download and compile the model locally; this takes a few minutes once and never again.

For a step-by-step walkthrough, see our [Getting Started in Under 2 Minutes](/blog/getting-started-enviouswispr-under-2-minutes/) guide. And if you want to understand why on-device processing matters, read our [On-Device vs Cloud Dictation comparison](/blog/macos-dictation-offline-private/).

That's it. No account, no API key, no subscription. EnviousWispr is free and open source. If you run into issues or have ideas, open an issue on GitHub — we read everything.