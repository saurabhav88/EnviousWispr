---
title: "Dictate Emails on macOS at the Speed of Thought"
description: "Stop typing emails between meetings. Dictate them in seconds with on-device speech to text that keeps sensitive company data on your MacBook."
pubDate: 2026-03-13
tags: ["dictation", "email", "productivity", "executive", "privacy"]
draft: false
---

The average executive types around 40 words per minute. They speak 150. That's not a marginal improvement -- it's nearly 4x throughput on the single activity that dominates their day: writing emails.

Between meetings, most leaders face a growing backlog of follow-up messages -- updates, decisions, delegation, context for people who weren't in the room. The decisions happen fast. Writing them down doesn't. And dictating into a cloud tool that routes every word through someone else's servers isn't an option when you're handling sensitive strategy, personnel decisions, or M&A discussions.

There's a faster, more private way.

## Speaking Is 3x Faster Than Typing

The average professional types around 40 words per minute. Speaking comfortably — not rushing — produces 120 to 150 words per minute. That's a 3x difference on raw throughput alone.

A 200-word email takes five minutes to type. It takes about 90 seconds to dictate. Multiply that across the 30 to 50 emails a day that many executives send, and the math stops being incremental. You're reclaiming hours.

But raw speed only matters if the output is usable. Nobody wants to send an email that reads like a stream-of-consciousness voice memo — full of "um," "so basically," and sentences that trail off. This is where most dictation tools fall short. They transcribe accurately, but they hand you a transcript, not a finished email.

EnviousWispr handles this differently. After transcription, your text runs through a local LLM that strips filler words, fixes punctuation, tightens sentence structure, and adjusts tone. You speak your thoughts loosely. What lands in your email client reads like you sat down and wrote it carefully. The whole cycle — record, transcribe, clean up, paste — takes a second or two on Apple Silicon.

<!-- TODO: Screenshot — Custom prompt config: the settings UI showing a custom prompt configured for email dictation with formal tone -->

## Writing Style Presets for Every Email Type

Not every email sounds the same. A response to a board member requires different language than a quick delegation to your direct report. EnviousWispr's three writing style presets — Formal, Standard, and Friendly — let you shape the output to match the context.

### Formal correspondence

Switch to the Formal preset for structured, professional prose. Dictate your key points conversationally, and the LLM will output polished paragraphs with proper salutations and clear paragraph breaks. Useful for investor updates, client responses, and cross-functional announcements.

### Quick replies

The Standard preset works well for brevity. Speak a few sentences, get back a clean, direct response. No fluff, no preamble. This is ideal for the Slack-style "acknowledged, here's the next step" messages that pile up between meetings.

### Delegation emails

The LLM post-processing step naturally formats action-oriented dictation into structured output. Dictate what needs to happen, who owns it, and the deadline. The output arrives as a clean bulleted list with names and dates — ready to paste and send.

### Coming soon: custom prompts and per-app presets

<!-- TODO: Screenshot — Per-app presets: the UI showing presets for email client (formal), Slack (concise), and notes app (raw capture) -->

On the roadmap: custom prompts will let you write your own processing instructions, and per-app presets will assign different rules to different applications automatically — so your email client gets the formal treatment, Slack gets the concise version, and your notes app gets raw capture, all without switching settings manually.

## Sensitive Data Stays on Your MacBook

Here's where the executive dictation tool conversation gets uncomfortable. Most speech-to-text services — including the ones built into popular productivity suites — send your audio to cloud servers for processing. For general-purpose dictation, that's a reasonable trade-off. For confidential business communications, it's a liability.

When you dictate an email about a pending acquisition, a personnel decision, or quarterly numbers before they're public, that audio travels to a data center you don't control. It gets processed on hardware you can't audit. The provider's privacy policy might be fine today and different after the next acquisition or policy update.

EnviousWispr runs transcription on-device using either Parakeet (streaming English) or WhisperKit (multi-language via Apple's Whisper model), both executing natively via Core ML on the Neural Engine in every M-series chip. Post-processing — the LLM step that cleans up your text — also runs locally using your local LLM of choice. Your recordings never leave your Mac unless you explicitly configure an external API.

No audio uploaded. No transcripts stored on someone else's server. This isn't a privacy feature bolted onto a cloud product. It's how the entire system works by default. For a detailed comparison of on-device and cloud dictation approaches, see [On-Device vs Cloud Dictation: What Stays Private](/blog/macos-dictation-offline-private/).

For executives handling material nonpublic information, attorney-client privileged communications, or board-level strategy discussions, this is the difference between a tool you can actually use and one that legal would flag on review.

## The Workflow: Dictate, Clean, Paste

The day-to-day experience is straightforward:

1. **Hold the hotkey** — a single keypress you configure once. EnviousWispr starts recording.
2. **Speak your email** — talk naturally. Say "um" if you want. Pause to think. The LLM handles cleanup.
3. **Release the hotkey** — recording stops, transcription starts immediately on-device.
4. **Text appears in your email client** — in about a second or two on Apple Silicon, the polished text pastes directly into whatever app has focus. If you prefer, clipboard mode copies it instead.

That's the entire loop. No app switching. No copy-paste from a separate dictation window. No waiting for a cloud round-trip. You stay in your email client the whole time.

For longer emails or strategy memos, hands-free mode lets EnviousWispr transcribe continuously in the background without holding any key. Speak for as long as you need, and the text accumulates. When you're done, it processes and delivers the full result.

## What This Looks Like in Practice

Picture your Tuesday morning on your M3 MacBook Pro. Three meetings between 9 and 11:30. Between each one, you have five to seven minutes. In that window, you open your inbox, hold the hotkey, and speak:

*"Send a note to the product team. The board approved the Q3 roadmap with one change — we're pulling the enterprise tier launch forward to August. Lisa owns the GTM timeline. Ask her to have a revised plan by Friday."*

You release the key. A second later, your email client contains:

> The board approved the Q3 roadmap with one change: the enterprise tier launch moves forward to August. Lisa owns the GTM timeline — please have a revised plan ready by Friday.

Clean, direct, ready to send. No filler words. Proper punctuation. The right tone for an internal team email. You hit send and walk into your next meeting with the confidence that nothing's slipping through the cracks.

Do that ten times a day and you've replaced 45 minutes of typing with 15 minutes of speaking — without compromising clarity or tone.

## Get Started in Five Minutes

EnviousWispr is free and open source. Download the `.dmg` from the [releases page](https://github.com/saurabhav88/EnviousWispr/releases), drag it to Applications, and grant microphone access on first launch. That's the whole setup — no account, no subscription.

Choose the `large-v3-turbo` Whisper model for the best balance of speed and accuracy on Apple Silicon. The model downloads and compiles locally once — a few minutes — and never needs to phone home again.

## Related Posts

- [Meeting Notes to Polished Summaries in Seconds](/blog/meeting-notes-polished-summaries/) — turn post-meeting chaos into structured summaries with action items
- [Async Communication Is Better When You Speak It](/blog/async-communication-better-when-you-speak/) — why dictating Slack messages and async updates beats typing them
- [Getting Started with EnviousWispr in Under 2 Minutes](/blog/getting-started-enviouswispr-under-2-minutes/) — from download to first dictation

Set your hotkey. Open your email client. Hold, speak, release. Your first dictated email will be done before you finish reading this sentence.
