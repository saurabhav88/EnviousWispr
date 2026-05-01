---
title: "Getting Started with EnviousWispr in Under 2 Minutes"
description: "Install EnviousWispr, grant two permissions, and start dictating in any app. This step-by-step guide walks you through full setup in under two minutes."
pubDate: 2026-03-11
updatedDate: 2026-04-28
tags: ["getting-started", "tutorial", "setup", "dictation"]
draft: false
author: "Saurabh Vaish"
faqs:
  - question: "Do I need an account or API key to use EnviousWispr?"
    answer: "No. EnviousWispr works fully offline out of the box with the default Parakeet engine. There is no signup, no email confirmation, and no API key to paste in. You can optionally bring your own OpenAI or Anthropic key later if you want cloud AI polish, but it is opt-in."
  - question: "Which permissions does EnviousWispr request, and why?"
    answer: "Two permissions, both granted through standard macOS prompts. Microphone access lets the app capture your voice. Accessibility access lets the app paste polished text into the app you are typing in. Neither permission sends data anywhere; both are required for a dictation app to function."
  - question: "What if my Mac is too old to run EnviousWispr?"
    answer: "EnviousWispr requires Apple Silicon (M1 or later) running macOS Sonoma 14 or newer. If you are on an Intel Mac, the on-device transcription speed would not be acceptable. We recommend Apple Dictation as a built-in alternative, or a cloud option like WisprFlow if you need a non-Apple-Silicon path."
  - question: "Will EnviousWispr work in my favorite app?"
    answer: "Yes, in any text field that accepts paste. That covers Slack, Gmail, VS Code, Notion, Google Docs, Terminal, browsers, native macOS apps, Word, and Cursor. The app pastes into whichever text field has focus, so it works wherever your cursor is blinking."
  - question: "How do I uninstall EnviousWispr if I change my mind?"
    answer: "Drag EnviousWispr from your Applications folder to the Trash. Optionally, revoke microphone and accessibility permissions in System Settings under Privacy and Security. The app stores nothing on remote servers, so there is nothing to delete from a cloud account."
---

You'll be dictating polished text into your apps before you finish your coffee. No account to create, no API key to find, no subscription to debate. Download, grant two permissions, talk. That's the entire setup, and it takes under two minutes.

This guide walks you through every step, from the initial download to your first dictation and beyond.

## Step 1: Download the .dmg

Head to the [EnviousWispr releases page on GitHub](https://github.com/saurabhav88/EnviousWispr/releases) and grab the latest `.dmg` file. It's a standard macOS disk image. Open it, drag EnviousWispr into your Applications folder, and launch it.

EnviousWispr requires an Apple Silicon Mac (M1 or later) running macOS Sonoma 14 or later. From a MacBook Air to a Mac Studio, transcription finishes in a second or two.

That's the entire install. No installer wizard, no setup assistant, no "create your workspace" screen.

## Step 2: Grant Microphone and Accessibility Permissions

On first launch, macOS will ask for two permissions. Both are required, and both stay entirely on your Mac. EnviousWispr doesn't phone home.

### Microphone access

macOS will show a standard permission dialog the first time EnviousWispr tries to record. Click **Allow**. This lets EnviousWispr hear you when you hold the hotkey. Your audio is processed locally via Core ML on Apple Silicon. The recording never leaves your device.

If you accidentally clicked **Don't Allow**, open **System Settings > Privacy & Security > Microphone** and toggle EnviousWispr on.

### Accessibility access

EnviousWispr needs Accessibility permission to paste transcribed text directly into your focused app. macOS will prompt you for this on first launch as well. You can also grant it manually in **System Settings > Privacy & Security > Accessibility**.

After toggling it on, you may need to restart EnviousWispr for the permission to take effect. This is a macOS quirk, not a bug.

Once both permissions are granted, you're ready to dictate.

## Step 3: Hold the Hotkey, Speak, Release

This is the core loop, and it's as simple as it sounds:

1. **Hold** the hotkey (the default is shown in the menu bar; you can change it later)
2. **Speak** naturally. Full sentences, half-formed thoughts, stream of consciousness. Don't worry about filler words or grammar.
3. **Release** the hotkey

EnviousWispr records while you hold, transcribes when you release, runs the text through post-processing to clean up filler words and fix punctuation, and then pastes the polished result into whatever app has focus. The whole cycle takes a second or two on Apple Silicon.

That's it. You've just dictated your first text with EnviousWispr.

Here's what a first dictation typically looks like:

**What you say:**
> hey I just wanted to test this out so um basically I need to send an email to the team about the project timeline and let them know that we're pushing the deadline back by a week because the design review took longer than expected

**What gets pasted:**
> Sending a quick update on the project timeline. We're pushing the deadline back by one week because the design review took longer than expected.

That's the before and after. You spoke naturally, with filler words and run-on phrasing. The output is clean, concise, and ready to paste into an email.

### What the post-processing does

By default, EnviousWispr's post-processing pipeline removes filler words like "um," "uh," and "like," fixes punctuation, and produces clean prose. You can run this on-device with Apple Intelligence or Ollama, or use a cloud provider like OpenAI or Gemini. If you want to understand [how the full pipeline works](/how-it-works/), we've documented each stage in detail.

You don't need to configure anything for this to work. The defaults are designed to produce clean, readable text out of the box.

## Step 4: Customize (Optional)

EnviousWispr works well with zero configuration, but if you want to tune it to your workflow, here's where to start.

### Speech engine

EnviousWispr downloads its speech recognition model automatically on first launch. The primary engine handles English with streaming transcription that overlaps with recording. A secondary engine is available for 100+ languages. The download takes a minute or two, and the model is cached locally from then on.

### AI polish

EnviousWispr's polish step removes filler words, fixes punctuation, and tightens structure without flattening your voice. The default works well for most writing. When you need a specific shape (a more polished tone, a particular format, your personal style rules), a Custom prompt lets you write your own polish instructions and reuse them.

### Custom prompts

Custom prompts let you tell the post-processor exactly how to handle your speech: "format as bullet points," "translate to Spanish," "write in my style: short sentences, no semicolons." Set your own system prompt in Settings under AI Polish, and the polish step uses it for every dictation until you change it.

### Custom word dictionary

Add names, technical terms, and company jargon to your personal dictionary. EnviousWispr uses multi-pass fuzzy matching to catch common misrecognitions and correct them automatically. This works whether or not you have AI polish enabled.

## What to Try Next

Once you're comfortable with the basic hotkey workflow, there are a few features worth exploring.

### Hands-free mode

Double-press your hotkey to lock recording for longer dictation sessions. You don't have to hold any key. Speak naturally for as long as you need, then triple-press to cancel or release to finish. This is especially useful for drafting an essay, capturing meeting notes, or working through a complex idea out loud.

### Clipboard mode

By default, EnviousWispr pastes text directly into the focused app and preserves your previous clipboard contents. If you prefer more control over where text ends up, switch to clipboard-only mode. Your transcription lands on the clipboard, and you paste it wherever you want with Cmd+V.

## Troubleshooting Quick Tips

Most issues during the EnviousWispr setup process come down to permissions or model loading. Here are the common ones.

### "Paste isn't working"

Check Accessibility permissions first. Open **System Settings > Privacy & Security > Accessibility** and make sure EnviousWispr is listed and toggled on. If it's already on, try toggling it off and back on, then restart EnviousWispr. macOS sometimes needs a fresh permission grant after updates.

### "No audio is being captured"

Verify microphone access in **System Settings > Privacy & Security > Microphone**. Also check that your input device is set correctly in macOS Sound settings. EnviousWispr uses whatever input device your system is configured to use.

### "Transcription is slow"

The first transcription after launch includes model loading time. Subsequent transcriptions are faster because the model stays in memory. If you want near-instant response from the first dictation, keep EnviousWispr running in the background. You can also adjust the warm engine policy in Settings to keep the engine ready between recordings.

### Something else?

EnviousWispr is on [GitHub](https://github.com/saurabhav88/EnviousWispr). If you hit a problem not covered here, open an issue and describe what happened. Include your macOS version and Mac model. That helps us reproduce and fix it faster.

## Related Posts

Now that you're set up, explore what EnviousWispr can do for your specific workflow:

- [Dictation for Writers: Skip the Blank Page](/blog/dictation-for-writers-skip-blank-page/). How speaking your first draft bypasses writer's block.
- [Dictation for Developers: Code Reviews and PRs](/blog/dictation-for-developers-code-reviews/). Faster PR descriptions and review comments by voice.
- [On-Device vs Cloud Dictation: What Stays Private](/blog/macos-dictation-offline-private/). Understand why your recordings stay on your Mac.

## You're Up and Running

That's the full setup, from install to your first dictation in under two minutes, with optional customization whenever you're ready for it. Free to download, no account required. A hotkey, your voice, and polished text in whatever app you're working in.

[Download EnviousWispr free](/#download) and start dictating, or grab it directly from [GitHub](https://github.com/saurabhav88/EnviousWispr/releases).

*Switching from another tool? See how EnviousWispr compares: [vs WisprFlow](/compare/wisprflow/), [vs Superwhisper](/compare/superwhisper/), [vs MacWhisper](/compare/macwhisper/), [vs VoiceInk](/compare/voiceink/), [vs Apple Dictation](/compare/apple-dictation/), or [browse all comparisons](/compare/).*
