---
title: "Getting Started with EnviousWispr in Under 2 Minutes"
description: "From installing the app to speaking your first sentence."
topic: getting-started
pubDate: 2026-03-11
updatedDate: 2026-04-28
tags: ["getting-started", "tutorial", "setup", "dictation"]
draft: false
author: "Saurabh Vaish"
faqs:
  - question: "Do I need an account or API key to use EnviousWispr?"
    answer: "No. EnviousWispr works fully offline out of the box with the default Parakeet engine. There is no signup, no email confirmation, and no API key to paste in. You can optionally bring your own OpenAI, Gemini, or Claude key later if you want cloud AI polish, but it is opt-in."
  - question: "Which permissions does EnviousWispr request, and why?"
    answer: "Up to three, all granted through standard macOS prompts. Microphone access lets the app capture your voice. Accessibility access lets the app paste polished text into the app you are typing in (Tier 1 direct insertion and Tier 2 simulated Cmd+V). Automation access is prompted only the first time the AppleScript paste fallback (Tier 2b) is needed, when both faster paste paths fail. None of these permissions sends data anywhere."
  - question: "What if my Mac is too old to run EnviousWispr?"
    answer: "EnviousWispr requires Apple Silicon (M1 or later) running macOS Sonoma 14 or newer. If you are on an Intel Mac, the on-device transcription speed would not be acceptable. We recommend Apple Dictation as a built-in alternative, or a cloud option like WisprFlow if you need a non-Apple-Silicon path."
  - question: "Will EnviousWispr work in my favorite app?"
    answer: "Yes, in any text field that accepts paste. That covers Slack, Gmail, VS Code, Notion, Google Docs, Terminal, browsers, native macOS apps, Word, and Cursor. The app pastes into whichever text field has focus, so it works wherever your cursor is blinking."
  - question: "How do I uninstall EnviousWispr if I change my mind?"
    answer: "Drag EnviousWispr from your Applications folder to the Trash. Optionally, revoke microphone, accessibility, and automation permissions in System Settings under Privacy and Security. The app stores nothing on remote servers, so there is nothing to delete from a cloud account."
---

You'll be dictating polished text into your apps before you finish your coffee. No account to create, no API key to find, no subscription to debate. Download, grant a couple of macOS permissions, talk. That's the entire setup, and it takes under two minutes.

This guide walks you through every step, from the initial download to your first dictation and beyond.

## Step 1: Download the .dmg

Head to the [download section](/#download) and grab the latest `.dmg` file. It's a standard macOS disk image. Open it, drag EnviousWispr into your Applications folder, and launch it.

EnviousWispr requires an Apple Silicon Mac (M1 or later) running macOS Sonoma 14 or later. From a MacBook Air to a Mac Studio, transcription finishes in a second or two.

That's the entire install. No installer wizard, no setup assistant, no "create your workspace" screen.

## Step 2: Grant Microphone and Accessibility Permissions

On first launch, macOS will ask for two permissions, and setup needs both to finish. Microphone lets it hear you; Accessibility lets the text land in the app you are working in. Your audio never leaves your Mac. A third prompt (Automation / Apple Events) appears only when the AppleScript paste fallback runs for the first time, and it's optional; declining it means the paste cascade stops one tier sooner.

### Microphone access

macOS will show a standard permission dialog the first time EnviousWispr tries to record. Click **Allow**. This lets EnviousWispr hear you when you hold the keybind. Your audio is processed locally via Core ML on Apple Silicon. The recording never leaves your device.

If you accidentally clicked **Don't Allow**, open **System Settings > Privacy & Security > Microphone** and toggle EnviousWispr on.

### Accessibility access

EnviousWispr needs Accessibility permission to paste transcribed text directly into your focused app. macOS will prompt you for this on first launch as well. You can also grant it manually in **System Settings > Privacy & Security > Accessibility**.

No restart needed; the app notices within a few seconds. If the switch is on but nothing pastes, remove EnviousWispr from the list with the minus button and add it back with plus.

Once both permissions are granted, you're ready to dictate.

## Step 3: Hold the Keybind, Speak, Release

This is the core loop, and it's as simple as it sounds:

1. **Hold** the keybind (the default is shown in the menu bar; you can change it later)
2. **Speak** naturally. Full sentences, half-formed thoughts, stream of consciousness. Don't worry about filler words or grammar.
3. **Release** the keybind

EnviousWispr records while you hold, transcribes when you release, runs the text through post-processing to clean up filler words and fix punctuation, and then pastes the polished result into whatever app has focus. Transcription takes under a second; polish adds a moment that grows with how much you said.

That's it. You've just dictated your first text with EnviousWispr.

Here's what a first dictation typically looks like:

**What you say:**
> hey I just wanted to test this out so um basically I need to send an email to the team about the project timeline and let them know that we're pushing the deadline back by a week because the design review took longer than expected

**What gets pasted:**
> Sending a quick update on the project timeline. We're pushing the deadline back by one week because the design review took longer than expected.

That's the before and after. You spoke naturally, with filler words and run-on phrasing. The output is clean, concise, and ready to paste into an email.

### What the post-processing does

Filler removal ("um," "uh," and "like") and number formatting run on your Mac with no AI model involved, and are on out of the box. AI rewriting is on by default on macOS 26 through Apple Intelligence; on older macOS pick EG-1 or S1-mini under Settings, AI Polish, or add an OpenAI, Gemini, or Claude key. If you want to understand [how the full pipeline works](/features/), we've documented each stage in detail.

You don't need to configure anything for this to work. The defaults are designed to produce clean, readable text out of the box.

## Step 4: Customize (Optional)

EnviousWispr works well with zero configuration, but if you want to tune it to your workflow, here's where to start.

### Speech engine

EnviousWispr downloads its speech recognition model automatically on first launch. The primary engine, Fast, covers 25 European languages. A second engine, All Languages, covers 99+ languages. The download takes a minute or two, and the model is cached locally from then on.

### AI polish

EnviousWispr's polish step removes filler words, fixes punctuation, and keeps your voice. It works well across most writing: a short aside stays a clean line, while a longer piece comes back as clean, readable prose.

### Structure follows your voice

You shape the output by how you talk. Speak a quick one-liner and it stays one line. With AI polish on, rattle off a list ("first... then... finally") and it usually comes back as bullet points; S1-mini follows its own Structure setting. There's nothing else to configure.

### Custom word dictionary

Add names, technical terms, and company jargon to your personal dictionary. EnviousWispr uses multi-pass fuzzy matching to catch common misrecognitions and correct them automatically. This works whether or not you have AI polish enabled.

## What to Try Next

Once you're comfortable with the basic keybind workflow, there are a few features worth exploring.

### Hands-free mode

Double-press your keybind to lock recording for longer dictation sessions. You don't have to hold any key. Speak naturally for as long as you need, then press the keybind once to finish, or triple-press to cancel. This is especially useful for drafting an essay, capturing meeting notes, or working through a complex idea out loud.

### Clipboard mode

By default, EnviousWispr pastes text directly into the focused app and preserves your previous clipboard contents. If you would rather paste yourself, switch off **Restore clipboard after paste** under Settings, Clipboard: your dictation stays on the clipboard after it lands, and you can paste it again wherever you want with Cmd+V.

## Troubleshooting Quick Tips

Most issues during the EnviousWispr setup process come down to permissions or model loading. Here are the common ones.

### "Paste isn't working"

Check Accessibility permissions first. Open **System Settings > Privacy & Security > Accessibility** and make sure EnviousWispr is listed and toggled on. If it's already on but nothing pastes, remove EnviousWispr from the list with the minus button and add it back with plus. macOS sometimes holds on to a stale record of the app after updates.

### "No audio is being captured"

Verify microphone access in **System Settings > Privacy & Security > Microphone**. Also check that your input device is set correctly in macOS Sound settings. By default EnviousWispr follows your Mac's input. To pin a specific mic, open Settings, Microphone.

### "Transcription is slow"

The first transcription after launch includes model loading time. Subsequent transcriptions are faster because the model stays in memory. If you want near-instant response from the first dictation, keep EnviousWispr running in the background. You can also set Microphone Readiness under Settings, Microphone to 60 sec or Always to keep the engine ready between recordings.

### Something else?

EnviousWispr is on [GitHub](https://github.com/saurabhav88/EnviousWispr). If you hit a problem not covered here, open an issue and describe what happened. Include your macOS version and Mac model. That helps us reproduce and fix it faster.

## Related Posts

Now that you're set up, explore what EnviousWispr can do for your specific workflow:

- [Dictation for Writers: Skip the Blank Page](/blog/dictation-for-writers-skip-blank-page/). How speaking your first draft bypasses writer's block.
- [Dictation for Developers: Code Reviews and PRs](/blog/dictation-for-developers-code-reviews/). Faster PR descriptions and review comments by voice.
- [On-Device vs Cloud Dictation: What Stays Private](/blog/macos-dictation-offline-private/). Understand why your recordings stay on your Mac.

## You're Up and Running

That's the full setup, from install to your first dictation in under two minutes, with optional customization whenever you're ready for it. Free to download, no account required. A keybind, your voice, and polished text in whatever app you're working in.

[Download EnviousWispr free](/#download) and start dictating, or browse the source [on GitHub](https://github.com/saurabhav88/EnviousWispr).

*Switching from another tool? See how EnviousWispr compares: [vs WisprFlow](/compare/wisprflow/), [vs Superwhisper](/compare/superwhisper/), [vs MacWhisper](/compare/macwhisper/), [vs VoiceInk](/compare/voiceink/), [vs Apple Dictation](/compare/apple-dictation/), or [browse all comparisons](/compare/).*
