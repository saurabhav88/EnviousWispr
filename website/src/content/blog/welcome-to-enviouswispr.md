---
title: "Welcome to EnviousWispr"
description: "Introducing EnviousWispr — private AI dictation for macOS. Learn what makes it different."
pubDate: 2026-03-10
tags: ["announcement", "privacy", "dictation"]
draft: false
---

We built EnviousWispr because we got tired of the trade-off: either use a fast, cloud-powered dictation tool that sends everything you say to someone else's server, or use an offline tool that feels like it was designed in 2012. We wanted both — speed and privacy — without compromise.

EnviousWispr runs entirely on your Mac. Your voice recordings never leave your device. Transcription happens locally using [WhisperKit](https://github.com/argmaxinc/WhisperKit), which runs Apple's Whisper model natively via Core ML. Post-processing — correcting punctuation, cleaning up filler words, adjusting tone — also runs on-device via your local LLM of choice. From microphone to clipboard, nothing touches the internet unless you explicitly configure an external API.

## What it does

The workflow is intentionally simple: hold a hotkey, speak, release. EnviousWispr records your audio, transcribes it, runs it through the post-processing pipeline, and places polished text on your clipboard — or pastes it directly into whatever app has focus. The whole cycle takes a second or two on Apple Silicon.

A few things that make it worth using day-to-day:

- **Hands-free mode** — set it to transcribe continuously in the background, no hotkey required
- **Custom prompts** — tell the post-processor to write in your style, translate on the fly, or format output as bullet points
- **Per-app presets** — different rules for Slack vs. your terminal vs. your writing app
- **Privacy toggle** — pause all processing with a single click when you're in a sensitive conversation

## Getting started

Download the `.dmg` from the [releases page](https://github.com/saurabhav88/EnviousWispr/releases), open it, and drag EnviousWispr to your Applications folder. On first launch you'll grant microphone access and choose a Whisper model — we recommend `large-v3-turbo` for the best balance of speed and accuracy on Apple Silicon. The app will download and compile the model locally; this takes a few minutes once and never again.

That's it. No account, no API key, no subscription. EnviousWispr is free and open source. If you run into issues or have ideas, open an issue on GitHub — we read everything.