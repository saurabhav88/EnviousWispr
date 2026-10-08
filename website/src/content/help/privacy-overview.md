---
title: "Privacy Overview"
description: "What stays on your Mac, and when the app uses the network."
category: "privacy-and-security"
section: "Privacy"
order: 1
keywords: ["privacy", "private", "is it private", "does it spy", "does it send my text anywhere", "data", "offline", "internet", "cloud", "tracking", "who can see my dictation", "does it need internet", "works offline", "send feedback privacy"]
related: ["what-data-is-collected", "ai-polish-and-cloud-data"]
seeAlso: "on-device-vs-cloud-dictation-privacy"
updated: 2026-09-29
deflection: "show_but_always_send"
---
EnviousWispr is a free dictation app for macOS. Your voice becomes text on your own Mac, and the audio never leaves it. There is no account and nothing to sign up for.

## Does my dictation stay on my Mac?

Your audio, yes, always. It is turned into text on your Mac and never sent anywhere. Your text stays on your Mac too when you use on-device polish or no polish. If you choose cloud polish, your text goes directly to the provider you picked.

- **Offline use.** Recording, transcribing, and pasting need no internet connection once the speech model has downloaded. Both speech engines run on your Mac.
- **Local History.** Your dictations and transcripts are saved in your user folder. Envious Labs, the company that makes EnviousWispr, never receives a copy.
- **Open source.** You can read the code. EnviousWispr is open source, so every claim on this page can be checked against it.

## When does EnviousWispr use the internet?

The app connects to the internet only for specific tasks.

- **Updates and downloads.** The app checks for new versions and downloads the speech and AI models you choose.
- **Anonymous usage and crash data.** Both are on by default, and you can turn either one off in **App Settings** > **Privacy**. They report which app and macOS versions were involved in a problem, and never what you said. See [What Data Is Collected](/help/what-data-is-collected/).
- **Cloud AI Polish, only if you choose it.** If you pick OpenAI, Gemini, Claude, or one of Ollama's hosted models, your text goes to that company under your own account with them. Your audio never does. See [AI Polish and Cloud Data](/help/ai-polish-and-cloud-data/).
- **Send Feedback, only when you press Send.** The message you type goes to Envious Labs. In recent versions, pressing Send also sends the text of your message (never your email address or diagnostics) through enviouswispr.com to an AI service that looks for matching help pages. See [Sending Feedback From the App](/help/sending-feedback/).

## Where does my text go with each AI Polish option?

It depends on the option you select in settings.

| Polish option | Where your text goes |
| :--- | :--- |
| Apple Intelligence | Stays on your Mac |
| EG-1 | Stays on your Mac |
| S1-mini | Stays on your Mac |
| An Ollama model you downloaded | Stays on your Mac |
| An Ollama hosted model | To Ollama's servers |
| OpenAI | To OpenAI |
| Gemini | To Google |
| Claude | To Anthropic |

Ollama appears on both sides of that line, so check which kind of model you picked.
