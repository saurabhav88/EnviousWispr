---
title: "What Data Is Collected"
description: "What stays on your Mac, what the app never sends, and what it does collect."
category: "privacy-and-security"
section: "Privacy"
order: 2
keywords: ["what data", "analytics", "telemetry", "collected", "do you see my text", "do you store", "opt out", "tracking", "crash reports"]
related: ["privacy-overview"]
updated: 2026-09-25
---
EnviousWispr collects anonymous usage data and crash reports. Nothing you say is part of that. Your audio never reaches Envious Labs, the company that makes the app, and the app never sends us your dictations or transcripts unless you include them in a feedback report yourself.

### What stays on your Mac

Your dictations and transcripts are saved to your History so you can find them later. They sit in your user folder, and Envious Labs never receives a copy.

[Escape Recovery](/help/escape-recovery/) is on unless you switch it off, so a recording you cancel with your keybind is transcribed and held in that same folder, letting you paste it back or press Keep to make it permanent. It stays available for 24 hours. After that it is removed while the app is running, or the next time you launch it. Its audio is deleted once its text is safely saved, exactly as with any other dictation.

While you dictate, the app keeps an encrypted backup of the recording. Once your text is safely saved, the app requests deletion of that backup. If the app quits first, EnviousWispr makes one recovery attempt the next time it runs, then requests deletion whether that recovery succeeded or failed.

Your custom words, settings, and API keys live here too. They stay on your Mac unless you turn on cloud polish, which is covered below.

### What the app never sends automatically

None of these is ever attached to feedback. Anything you type into a feedback report yourself is covered below.

- Your audio
- Your dictations and transcripts, before or after polish
- Your custom words
- The text around your cursor
- Your API keys
- Your name or email address, unless you choose to include either in a feedback report (below)

### What the app does collect

The app collects anonymous usage and crash data. That data shows whether a release broke dictation on a particular macOS version, or whether anyone ever opens a setting that took a month to build. It is on by default and cannot be turned off.

The app records how you use it, never what you said. There is no account, and nothing in the data names you, although each installation gets a random ID so that one Mac counts as one user. The privacy policy has the full detail.

If you would rather run without it, EnviousWispr is open source under the GPLv3 license. You can build the app yourself, and dictation works in exactly the same way.

### Feedback you choose to send

If you use Send Feedback, from the menu bar menu or the app window, we receive the message you write and, only if you add it, your email address so we can reply. It also carries the app and macOS version, basic details about your Mac, your locale and time zone, technical diagnostics such as the audio route, recording status and Apple Intelligence availability, and random IDs used by the app and Sentry. Your feedback is sent only after you press Send, and no recordings or History are attached. The privacy policy covers how long it is kept and how to have it deleted.

### Where your text goes if you use cloud AI polish

Polish runs on your Mac by default. If you choose OpenAI, Gemini, or Claude instead, you add your own API key. Your text is then sent to that provider, along with your custom words and the name of the app you are dictating into, so the model gets your spellings and tone right. Audio is never sent. The app tells you this when you set it up. That connection is your account with that company, governed by their terms.

Ollama works in two ways, and only one of them keeps your text on your Mac. A model you download runs on your Mac and sends nothing anywhere. A hosted model runs on Ollama's servers, so your text goes to Ollama in the same way it would go to any other cloud provider. EnviousWispr lists the two kinds under separate headings so you can tell which you are picking.

Envious Labs is not in the middle of any of these requests. Everything goes straight from your Mac to the provider, so Envious Labs never sees it either way.
