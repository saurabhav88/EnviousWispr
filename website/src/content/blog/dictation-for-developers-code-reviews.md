---
title: "macOS Dictation for Developers: Code Reviews and PRs"
description: "How developers use voice dictation to write PR descriptions, code review comments, and documentation without breaking flow state."
pubDate: 2026-03-12
tags: ["developers", "dictation", "productivity", "code-review"]
draft: false
---

Studies on developer productivity consistently find the same thing: the biggest time sink isn't writing code -- it's everything around the code. PR descriptions, review comments, Slack threads, postmortems, design docs, README updates. One analysis of engineering time found that developers spend roughly 30% of their workday writing prose, not code. And most of that prose gets typed in the cracks between implementation work, breaking flow state every time.

That context-switch cost is what makes voice input valuable for developers. Hold a hotkey, speak, release. Your words get transcribed on-device, cleaned up by a local LLM, and pasted into whatever app has focus. The whole cycle takes a second or two on Apple Silicon. No cloud API, no uploaded audio.

Here's how that fits into a developer's actual day.

## The problem with prose in a code workflow

When you're three hours into debugging a race condition and you finally fix it, the last thing you want to do is shift gears to write a detailed PR description. But your team needs context — what changed, why, what you considered and rejected, what to watch for in review.

So you write something minimal. "Fixed race condition in queue handler." Your reviewer has to reverse-engineer the reasoning from the diff. The review takes longer. Questions get asked that the description should have answered. Everyone loses time.

The fix isn't writing better descriptions through sheer discipline. The fix is making it easier to produce them without breaking your train of thought. If you can just talk through what you did — the same way you'd explain it to a colleague at your desk — the description writes itself.

## Writing style presets: match the tone to the task

Not all developer writing sounds the same. A commit message is terse. A PR description is structured. A Slack reply is conversational. EnviousWispr ships with three writing style presets — **Formal**, **Standard**, and **Friendly** — that control how the LLM post-processor shapes your dictated text.

Here's how each one maps to developer tasks:

### Formal

Best for PR descriptions, documentation, and design docs. Full sentences, proper punctuation, structured prose. You talk through your reasoning and the post-processor organizes it into clean, readable text. Markdown headers, bullet points, and code references stay intact.

### Standard

The default. Works well for most developer writing — review comments, ticket updates, README sections. It cleans up filler words and fixes punctuation without over-formalizing.

### Friendly

Best for Slack messages and casual communication. Keeps things informal — closer to how you'd actually talk. "Hey, the deploy is blocked on that config change, can you merge it when you get a chance" comes out natural, not stiff.

<!-- TODO: Screenshot — Writing style presets: the settings UI showing Formal, Standard, and Friendly options -->

You switch between presets with a click. Pick the tone that matches what you're writing, and the post-processor handles the rest.

> **Coming soon:** Per-app presets will let you assign different writing styles to different apps — Terminal stays terse, Slack stays casual, your browser gets structured markdown — all automatically based on which app has focus. No manual switching.

## Real workflow: dictating a PR description

Let's walk through a concrete example. You've just finished a feature branch that adds retry logic to an HTTP client on your M4 Pro Mac Mini. You switch to your browser, open the "Create Pull Request" page, click into the description field, and hold your hotkey.

You say something like:

> "This adds configurable retry logic to the HTTP client. Previously, failed requests would just throw immediately. Now the client retries up to three times with exponential backoff. The retry count and backoff multiplier are configurable via the client constructor. I considered using a middleware approach but went with direct integration because it's simpler and we don't need per-request retry policies yet. The main thing to watch in review is the timeout interaction — make sure the per-retry timeout doesn't stack with the overall request timeout."

You release the hotkey. A second or two later, the post-processed text appears in the description field — punctuation fixed, filler words removed, structure tightened. The content is yours. The cleanup is automatic.

That took maybe 20 seconds of speaking. Writing the same thing by hand, with the mental overhead of composing prose mid-flow, takes significantly longer.

Here's the before and after — what you actually say versus what lands in the PR description field:

**What you say:**
> so basically this PR adds retry logic to the HTTP client um previously if a request failed it would just throw immediately now it retries up to three times with exponential backoff and the retry count and backoff multiplier are both configurable through the constructor I thought about doing this as middleware but it's simpler as direct integration since we don't need per-request retry policies yet

**What gets pasted:**
> Adds configurable retry logic to the HTTP client. Previously, failed requests threw immediately. The client now retries up to three times with exponential backoff. Retry count and backoff multiplier are configurable via the constructor. Considered a middleware approach but chose direct integration for simplicity — per-request retry policies aren't needed yet.

Twenty seconds of speaking replaced five minutes of context-switching into prose mode. The reasoning is there. The trade-off is documented. Your reviewer has what they need. And you never had to break your mental model of the code to do it.

## Real workflow: code review comments

Code review is where dictation saves the most friction. You're reading a diff, you spot something, and you need to leave a comment that's specific enough to be actionable. The old way: stop reading the diff, shift into writing mode, type out the comment, lose your place in the review.

With dictation, you stay in reading mode. You hold the hotkey and say:

> "This allocation happens inside the loop but the buffer size doesn't change between iterations. Move the allocation outside the loop and reuse the buffer. Should cut the allocations from N to 1."

Release. The comment appears, properly punctuated, in the review textarea. You're still in the flow of reading the diff. No context switch.

This works especially well for longer review comments — the kind where you need to explain a subtle issue or suggest an alternative approach. Those are exactly the comments that are most valuable to the author and most tedious to type out.

<!-- TODO: Screenshot — Recording state: the app showing it's actively recording while the user is in a GitHub PR description field -->

## Real workflow: documentation and design docs

Technical documentation has the highest typing-to-thinking ratio of anything developers write. You know what the system does. You just need to get it into words. Dictation makes this almost trivial.

For documentation, the Formal writing style preset works well — it produces structured prose with proper punctuation and clean paragraphs. You talk through the architecture the way you'd explain it to a new team member, and the output lands polished and ready to commit. Down the road, custom prompts will let you go even further — telling the post-processor to format output as API documentation with parameter descriptions, or to use specific header structures.

This is particularly useful for the kind of documentation that always gets skipped — the "how does this subsystem actually work" docs that everyone wishes existed but nobody wants to sit down and type out. Speaking is lower friction than typing for this kind of knowledge dump, and the difference is enough to make it actually happen.

## Privacy: your codebase stays on your Mac

Developer conversations are sensitive. PR descriptions mention internal architecture. Code review comments reference proprietary logic. Slack threads discuss unreleased features, customer issues, and security concerns.

EnviousWispr processes everything on-device. Your audio is transcribed locally using either Parakeet or WhisperKit, both running natively via Core ML. Post-processing runs through your local LLM. From microphone to clipboard, nothing leaves your Mac unless you explicitly configure an external API.

This isn't a privacy policy — it's architecture. There's no server to send data to. For a detailed breakdown of how on-device processing differs from cloud alternatives, see [On-Device vs Cloud Dictation: What Stays Private](/blog/on-device-vs-cloud-dictation-privacy/). The processing happens on your hardware, using models that run on your Apple Silicon Neural Engine. You can verify this yourself — the project is [open source on GitHub](https://github.com/saurabhav88/EnviousWispr).

For developers working on proprietary codebases, under NDA, or at companies with strict data handling policies, this is the difference between "tool I can actually use at work" and "tool that's blocked by security review."

## Getting started

Download EnviousWispr from the [releases page](https://github.com/saurabhav88/EnviousWispr/releases). On first launch, grant microphone access and pick a Whisper model — `large-v3-turbo` gives the best balance of speed and accuracy on Apple Silicon.

To set up for developer use:

1. **Open Preferences** and choose your writing style preset — Formal works well for PR descriptions and docs, Friendly for Slack
2. **Pick your hotkey** — something that doesn't collide with your IDE shortcuts
3. **Switch presets as needed** — when you move from writing a PR description to replying in Slack, switch from Formal to Friendly with a click

It's fast to switch, and you'll quickly develop a habit of matching the preset to the task. Hold the hotkey in GitHub with Formal selected, get a detailed PR description. Switch to Friendly for Slack, get a casual reply.

## Related Posts

- [Why I Switched from Typing to Dictating Git Commits](/blog/switched-typing-to-dictating-git-commits/) — a practical look at dictating commit messages with writing style presets
- [Voice Coding on macOS Without Cloud APIs](/blog/voice-coding-macos-without-cloud/) — the full case for on-device voice input in dev workflows
- [Getting Started with EnviousWispr in Under 2 Minutes](/blog/getting-started-enviouswispr-under-2-minutes/) — setup walkthrough from download to first dictation

No login screen. No pricing page. Just faster prose, wherever your dev workflow needs it.
