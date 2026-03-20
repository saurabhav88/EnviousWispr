---
title: "EnviousWispr: Free Private AI Dictation for macOS"
description: "EnviousWispr is free on-device AI dictation for macOS. No cloud, no account — hold a hotkey, speak, and polished text lands on your clipboard in ~2 seconds."
pubDate: 2026-03-25
tags: ["announcement", "privacy", "dictation"]
draft: true
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

For a step-by-step walkthrough, see our [Getting Started in Under 2 Minutes](/blog/getting-started-enviouswispr-under-2-minutes/) guide. And if you want to understand why on-device processing matters, read our [on-device vs. cloud dictation comparison](/blog/on-device-vs-cloud-dictation-privacy/).

That's it. No account, no API key, no subscription. EnviousWispr is free and open source. If you run into issues or have ideas, open an issue on GitHub — we read everything.

## Why on-device matters

Most dictation tools send your audio to a server. The server runs a speech recognition model, returns the text, and your recording sits in someone else's infrastructure during that process. Retention policies vary. Some providers keep recordings for model training unless you explicitly opt out.

On-device dictation works differently. The speech recognition model runs entirely on your Mac's Neural Engine using [WhisperKit](https://github.com/argmaxinc/WhisperKit) and Core ML. Your audio is processed locally and discarded. There's no server to breach, no retention policy to read, no third-party subprocessor to trust.

This isn't a privacy promise buried in a terms-of-service document. It's an architectural fact: the pipeline has nowhere to send your audio. It works offline, on a plane, with Wi-Fi turned off.

The accuracy gap between local and cloud transcription has largely closed. Whisper large-v3, released by OpenAI in 2022 and now running natively on Apple Silicon via Core ML, achieves word error rates competitive with major cloud speech APIs. You're not trading quality for privacy anymore. For a full breakdown, read [how on-device dictation compares to cloud services](/blog/on-device-vs-cloud-dictation-privacy/).

## How it works

The pipeline has four steps, and they run in parallel on Apple Silicon — which is what makes the end-to-end time roughly two seconds:

1. **Record** — hold the global hotkey (configurable), speak, release. EnviousWispr captures audio from your microphone.
2. **Transcribe** — WhisperKit runs the Whisper model natively via Core ML on your Mac's Neural Engine. For English, the Parakeet pipeline (Apple Speech) is the primary option — optimized for speed. For multi-language or accent-heavy content, WhisperKit handles it.
3. **Polish** — a local LLM (or your choice of OpenAI, Gemini, Ollama, or Apple Intelligence) removes filler words, fixes punctuation, and shapes the output to your selected writing style (Formal, Standard, or Friendly).
4. **Paste** — the polished text lands on your clipboard and pastes directly into whatever app has keyboard focus via macOS accessibility APIs.

See [how the transcription pipeline works in detail](/how-it-works/) if you want to go deeper on any of these steps.

## Who it's for

EnviousWispr is built for macOS users on Apple Silicon who produce a lot of text and want to do it faster — without sending their audio to a cloud service.

**Developers** dictate PR descriptions, review comments, and Slack messages without breaking their flow. Proprietary code context never touches a cloud API.

**Writers** get first drafts out of their heads faster. Speaking is roughly three to five times faster than typing for most people. The post-processing step means the output is closer to ready-to-publish than raw transcription.

**Knowledge workers** — remote teams, product managers, researchers — use it for email, meeting notes, and async communication. Any text field in any macOS app works: Gmail, Notion, Slack, your IDE, your terminal.

**Privacy-sensitive professions** — legal, medical, finance — dictate confidential content knowing it never leaves the device. No cloud policy to trust, no audit to worry about.

**RSI and accessibility users** reduce keyboard load without giving up productivity. The hands-free mode lets you lock into continuous transcription without holding any key — useful for longer sessions or when holding a hotkey isn't an option.

The one hard requirement: an Apple Silicon Mac (M1 or later) running macOS Sonoma 14+. The Neural Engine is what makes local transcription fast enough to feel instant. Intel Macs won't run it.

## Related posts

- [On-device vs. cloud dictation: what's private](/blog/on-device-vs-cloud-dictation-privacy/) — a full architectural comparison of how each handles your audio and where your recordings actually go
- [Getting started with EnviousWispr in under 2 minutes](/blog/getting-started-enviouswispr-under-2-minutes/) — step-by-step setup from download to first dictation
- [Voice to prose: a writing workflow](/blog/voice-to-prose-writing-workflow/) — how to build a first-draft workflow using on-device dictation and writing style presets