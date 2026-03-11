---
title: "Getting Started with EnviousWispr in Under 2 Minutes"
description: "Install EnviousWispr, grant two permissions, and start dictating. This step-by-step guide walks you through setup in under two minutes."
pubDate: 2026-03-11
tags: ["getting-started", "tutorial", "setup", "dictation"]
draft: false
---

You'll be dictating polished text into your apps before you finish your coffee. No account to create, no API key to find, no subscription to debate. Download, grant two permissions, talk. That's the entire setup, and it takes under two minutes.

This guide walks you through every step -- from the initial download to your first dictation and beyond.

## Step 1: Download the .dmg

Head to the [EnviousWispr releases page on GitHub](https://github.com/saurabhav88/EnviousWispr/releases) and grab the latest `.dmg` file. It's a standard macOS disk image — open it, drag EnviousWispr into your Applications folder, and launch it.

EnviousWispr requires macOS Sonoma or later and runs best on Apple Silicon. If you're on an M1, M2, M3, or M4 Mac — from a MacBook Air to a Mac Studio — transcription will finish in a second or two. Intel Macs work too, but expect slower processing times.

That's the entire install. No installer wizard, no setup assistant, no "create your workspace" screen.

## Step 2: Grant Microphone and Accessibility Permissions

On first launch, macOS will ask for two permissions. Both are required, and both stay entirely on your Mac — EnviousWispr doesn't phone home.

### Microphone access

macOS will show a standard permission dialog the first time EnviousWispr tries to record. Click **Allow**. This lets EnviousWispr hear you when you hold the hotkey. Your audio is processed locally via Core ML using either Parakeet or [WhisperKit](https://github.com/argmaxinc/WhisperKit) — the recording never leaves your device.

If you accidentally clicked **Don't Allow**, open **System Settings > Privacy & Security > Microphone** and toggle EnviousWispr on.

### Accessibility access

EnviousWispr needs Accessibility permission to paste transcribed text directly into your focused app. macOS will prompt you for this on first launch as well — or you can grant it manually in **System Settings > Privacy & Security > Accessibility**.

After toggling it on, you may need to restart EnviousWispr for the permission to take effect. This is a macOS quirk, not a bug.

Once both permissions are granted, you're ready to dictate.

## Step 3: Hold the Hotkey, Speak, Release

This is the core loop, and it's as simple as it sounds:

1. **Hold** the hotkey (the default is shown in the menu bar — you can change it later)
2. **Speak** naturally — full sentences, half-formed thoughts, stream of consciousness. Don't worry about filler words or grammar.
3. **Release** the hotkey

EnviousWispr records while you hold, transcribes when you release, runs the text through post-processing to clean up filler words and fix punctuation, and then pastes the polished result into whatever app has focus. The whole cycle takes a second or two on Apple Silicon.

That's it. You've just dictated your first text with EnviousWispr.

Here's what a first dictation typically looks like:

**What you say:**
> hey I just wanted to test this out so um basically I need to send an email to the team about the project timeline and let them know that we're pushing the deadline back by a week because the design review took longer than expected

**What gets pasted:**
> Sending a quick update on the project timeline — we're pushing the deadline back by one week. The design review took longer than expected.

That's the before and after. You spoke naturally, with filler words and run-on phrasing. The output is clean, concise, and ready to paste into an email.

### What the post-processing does

By default, EnviousWispr's post-processing pipeline removes filler words like "um," "uh," and "like," fixes punctuation, and produces clean prose. It runs on-device via your local LLM — no cloud round-trip, no latency penalty. If you want to understand [how the full pipeline works](/how-it-works/), we've documented each stage in detail.

You don't need to configure anything for this to work. The defaults are designed to produce clean, readable text out of the box.

<!-- TODO: Screenshot — Menu bar icon: the EnviousWispr menu bar dropdown showing the hotkey, recording status, and quick actions -->

## Step 4: Customize (Optional)

EnviousWispr works well with zero configuration, but if you want to tune it to your workflow, here's where to start.

### Choose your Whisper model

EnviousWispr ships with support for multiple Whisper model sizes. Smaller models transcribe faster but are less accurate. Larger models — like large-v3-turbo — produce better results but take longer, especially on older hardware.

The first model download takes a few minutes depending on your connection. After that, the model is cached locally and loads instantly on launch.

For most people on Apple Silicon, the default model strikes a good balance between speed and accuracy. Experiment if you want — switching models takes a couple of clicks in the settings.

### Writing style presets

EnviousWispr ships with three writing style presets -- Formal, Standard, and Friendly -- that control the tone of your post-processed output. Switch between them depending on the task: Formal for polished emails, Standard for general writing, Friendly for casual messages.

### Coming soon: custom prompts and per-app presets

Custom prompts will let you tell the post-processor exactly how to handle your speech -- "format as bullet points," "translate to Spanish," "write in my style: short sentences, no semicolons." Per-app presets will take that further by automatically applying different rules based on which app has focus -- casual for Slack, terse for Terminal, full prose for your writing app. Both are on the roadmap.

## What to Try Next

Once you're comfortable with the basic hotkey workflow, there are a few features worth exploring.

### Hands-free mode

Hands-free mode lets EnviousWispr transcribe continuously in the background without holding any keys. Start it, speak naturally for as long as you need, and stop it when you're done. This is especially useful for long dictation sessions — drafting an essay, capturing meeting notes, or working through a complex idea out loud.

### Clipboard mode

By default, EnviousWispr pastes text directly into the focused app. If you prefer more control over where text ends up, switch to clipboard mode. Your transcription lands on the clipboard, and you paste it wherever you want with Cmd+V.

### Privacy toggle (coming soon)

A dedicated privacy toggle is in the works -- a single click to pause all processing when you're in a sensitive conversation or confidential meeting. Until then, hands-free mode can simply be stopped when you need silence.

## Troubleshooting Quick Tips

Most issues during the EnviousWispr setup process come down to permissions or model loading. Here are the common ones.

### "Paste isn't working"

Check Accessibility permissions first. Open **System Settings > Privacy & Security > Accessibility** and make sure EnviousWispr is listed and toggled on. If it's already on, try toggling it off and back on, then restart EnviousWispr. macOS sometimes needs a fresh permission grant after updates.

### "No audio is being captured"

Verify microphone access in **System Settings > Privacy & Security > Microphone**. Also check that your input device is set correctly in macOS Sound settings — EnviousWispr uses whatever input device your system is configured to use.

### "Transcription is slow"

If transcription takes more than a few seconds, you may be using a model that's too large for your hardware. Try switching to a smaller model in settings. On Apple Silicon, large-v3-turbo should still be fast. On Intel Macs, smaller models will give a noticeably better experience.

### "The first transcription took a while"

That's normal. The first transcription after launch includes model loading time. Subsequent transcriptions are faster because the model stays in memory. If you want near-instant response from the first dictation, keep EnviousWispr running in the background.

### Something else?

EnviousWispr is [open source on GitHub](https://github.com/saurabhav88/EnviousWispr). If you hit a problem not covered here, open an issue and describe what happened. Include your macOS version (Sonoma, Sequoia, etc.), Mac model, and which Whisper model you're using — that helps us reproduce and fix it faster.

## Related Posts

Now that you're set up, explore what EnviousWispr can do for your specific workflow:

- [Dictation for Writers: Skip the Blank Page](/blog/dictation-for-writers-skip-blank-page/) — how speaking your first draft bypasses writer's block
- [Dictation for Developers: Code Reviews and PRs](/blog/dictation-for-developers-code-reviews/) — faster PR descriptions and review comments by voice
- [On-Device vs Cloud Dictation: What Stays Private](/blog/on-device-vs-cloud-dictation-privacy/) — understand why your recordings stay on your Mac

## You're Up and Running

That's the full EnviousWispr tutorial — from install to your first dictation in under two minutes, with optional customization whenever you're ready for it. Free and open source — just download and go. A hotkey, your voice, and polished text in whatever app you're working in.

[Download EnviousWispr from GitHub](https://github.com/saurabhav88/EnviousWispr/releases) and start dictating.
