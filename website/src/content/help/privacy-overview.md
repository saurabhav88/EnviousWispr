---
title: "Privacy Overview"
description: "What stays on your Mac, and when the app uses the network."
category: "privacy-and-security"
section: "Privacy"
order: 1
keywords: ["privacy", "private", "is it private", "does it spy", "does it send my text anywhere", "data", "offline", "internet", "cloud", "tracking", "who can see my dictation"]
related: ["what-data-is-collected", "ai-polish-and-cloud-data"]
seeAlso: "on-device-vs-cloud-dictation-privacy"
updated: 2026-08-06
---
EnviousWispr is a free dictation app for macOS. Your voice becomes text on your own Mac, and the audio never leaves it. There is no account and nothing to sign up for.

### What stays on your Mac

You can use the app without an internet connection at all, and your dictation stays on your own hardware.

- **Offline operation.** Recording, transcribing, and pasting need no internet connection. Both speech engines run on your Mac.
- **Local transcripts.** Your transcripts are saved in your user folder. Envious Labs, the company that makes EnviousWispr, never receives a copy.
- **Open source verification.** You can read the code. EnviousWispr is open source, so every claim on this page can be checked against it.

### When EnviousWispr uses the network

The app connects to the internet only for specific tasks that genuinely need it.

- **Updates and downloads.** The app checks for new versions, and downloads the speech and AI models you choose.
- **Anonymous usage and crash data.** This is on by default. It reports which app and macOS versions were involved in a problem, and it never reports what you said. See [_What Data Is Collected_](/help/what-data-is-collected/).
- **Cloud AI Polish, only if you choose it.** If you pick OpenAI, Gemini, Claude, or one of Ollama's hosted models, your text goes to that company under your own account with them. Your audio never does. See [_AI Polish and Cloud Data_](/help/ai-polish-and-cloud-data/).

### Where your text goes with each polish option

This depends entirely on the option you select in settings.

| Polish option | Where your text goes |
| :--- | :--- |
| Apple Intelligence | Stays on your Mac |
| EG-1 | Stays on your Mac |
| An Ollama model you downloaded | Stays on your Mac |
| An Ollama hosted model | To Ollama's servers |
| OpenAI | To OpenAI |
| Gemini | To Google |
| Claude | To Anthropic |

Ollama appears on both sides of that line, so check which kind of model you picked.
