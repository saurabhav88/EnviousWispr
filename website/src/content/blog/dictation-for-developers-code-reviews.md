---
title: "Dictation for Developers: Code Reviews and PRs"
description: "How developers use voice dictation to write PR descriptions, code review comments, and documentation without breaking flow state."
pubDate: 2026-03-11
tags: ["developers", "dictation", "productivity", "code-review"]
draft: false
---

Developers write more prose than they think. Between PR descriptions, code review comments, Slack threads, incident postmortems, design docs, and README updates, a significant chunk of your day is spent producing English, not code. And most of that writing happens in the cracks — context-switching from an implementation you're deep in to a textarea where you need to explain what you just did and why.

That switch is expensive. Not because typing is hard, but because the mental gear-change from "thinking in code" to "writing for humans" pulls you out of the state where you're most productive.

EnviousWispr lets you stay in flow and talk through the prose parts instead. Hold a hotkey, speak, release. Your words get transcribed on-device, cleaned up by a local LLM, and pasted into whatever app has focus. The whole cycle takes a second or two on Apple Silicon.

Here's how that fits into a developer's actual day.

## The problem with prose in a code workflow

When you're three hours into debugging a race condition and you finally fix it, the last thing you want to do is shift gears to write a detailed PR description. But your team needs context — what changed, why, what you considered and rejected, what to watch for in review.

So you write something minimal. "Fixed race condition in queue handler." Your reviewer has to reverse-engineer the reasoning from the diff. The review takes longer. Questions get asked that the description should have answered. Everyone loses time.

The fix isn't writing better descriptions through sheer discipline. The fix is making it easier to produce them without breaking your train of thought. If you can just talk through what you did — the same way you'd explain it to a colleague at your desk — the description writes itself.

## Per-app presets: different tone for different tools

Not all developer writing sounds the same. A terminal command is terse. A PR description is structured. A Slack reply is conversational. EnviousWispr handles this with [per-app presets](/how-it-works/) — different post-processing rules depending on which app has focus when you dictate.

Here's what that looks like in practice:

### Terminal / IDE

**Preset goal:** minimal formatting, no filler, preserve technical terms exactly.

When you dictate into your terminal or editor, the preset strips filler words and keeps output tight. You say "git commit dash m fix null pointer in session handler" and you get a clean commit message, not a polished paragraph.

### GitHub / browser

**Preset goal:** structured prose, markdown formatting, technical detail preserved.

When you're writing a PR description or review comment in the browser, the preset produces full sentences with proper punctuation. You talk through your reasoning and the LLM post-processor organizes it into readable prose. Markdown headers, bullet points, and code references stay intact.

### Slack

**Preset goal:** conversational, casual punctuation, shorter sentences.

Slack messages don't need to read like documentation. The Slack preset keeps things informal — closer to how you'd actually talk. "Hey, the deploy is blocked on that config change, can you merge it when you get a chance" comes out natural, not stiff.

You configure these presets once. After that, EnviousWispr detects which app has focus and applies the right rules automatically. No manual switching.

## Real workflow: dictating a PR description

Let's walk through a concrete example. You've just finished a feature branch that adds retry logic to an HTTP client. You switch to your browser, open the "Create Pull Request" page, click into the description field, and hold your hotkey.

You say something like:

> "This adds configurable retry logic to the HTTP client. Previously, failed requests would just throw immediately. Now the client retries up to three times with exponential backoff. The retry count and backoff multiplier are configurable via the client constructor. I considered using a middleware approach but went with direct integration because it's simpler and we don't need per-request retry policies yet. The main thing to watch in review is the timeout interaction — make sure the per-retry timeout doesn't stack with the overall request timeout."

You release the hotkey. A second or two later, the post-processed text appears in the description field — punctuation fixed, filler words removed, structure tightened. The content is yours. The cleanup is automatic.

That took maybe 20 seconds of speaking. Writing the same thing by hand, with the mental overhead of composing prose mid-flow, takes significantly longer.

## Real workflow: code review comments

Code review is where dictation saves the most friction. You're reading a diff, you spot something, and you need to leave a comment that's specific enough to be actionable. The old way: stop reading the diff, shift into writing mode, type out the comment, lose your place in the review.

With dictation, you stay in reading mode. You hold the hotkey and say:

> "This allocation happens inside the loop but the buffer size doesn't change between iterations. Move the allocation outside the loop and reuse the buffer. Should cut the allocations from N to 1."

Release. The comment appears, properly punctuated, in the review textarea. You're still in the flow of reading the diff. No context switch.

This works especially well for longer review comments — the kind where you need to explain a subtle issue or suggest an alternative approach. Those are exactly the comments that are most valuable to the author and most tedious to type out.

## Real workflow: documentation and design docs

Technical documentation has the highest typing-to-thinking ratio of anything developers write. You know what the system does. You just need to get it into words. Dictation makes this almost trivial.

For documentation, you can go further with custom prompts. Set up a prompt that tells the LLM post-processor to format output as markdown with headers, or to structure it as API documentation with parameter descriptions. You talk through the architecture the way you'd explain it to a new team member, and the output lands formatted and ready to commit.

This is particularly useful for the kind of documentation that always gets skipped — the "how does this subsystem actually work" docs that everyone wishes existed but nobody wants to sit down and type out. Speaking is lower friction than typing for this kind of knowledge dump, and the difference is enough to make it actually happen.

## Privacy: your codebase stays on your Mac

Developer conversations are sensitive. PR descriptions mention internal architecture. Code review comments reference proprietary logic. Slack threads discuss unreleased features, customer issues, and security concerns.

EnviousWispr processes everything on-device. Your audio is transcribed locally using either Parakeet or WhisperKit, both running natively via Core ML. Post-processing runs through your local LLM. From microphone to clipboard, nothing leaves your Mac unless you explicitly configure an external API.

This isn't a privacy policy — it's architecture. There's no server to send data to. For a detailed breakdown of how on-device processing differs from cloud alternatives, see [On-Device vs Cloud Dictation: What Stays Private](/blog/on-device-vs-cloud-dictation-privacy/). The processing happens on your hardware, using models that run on your Apple Silicon Neural Engine. You can verify this yourself — the project is [open source on GitHub](https://github.com/saurabhav88/EnviousWispr).

For developers working on proprietary codebases, under NDA, or at companies with strict data handling policies, this is the difference between "tool I can actually use at work" and "tool that's blocked by security review."

## Getting started

Download EnviousWispr from the [releases page](https://github.com/saurabhav88/EnviousWispr/releases). On first launch, grant microphone access and pick a Whisper model — `large-v3-turbo` gives the best balance of speed and accuracy on Apple Silicon.

To set up developer-friendly presets:

1. **Open Preferences** and navigate to the presets section
2. **Create a preset for your browser** — set the custom prompt to produce structured markdown with full sentences
3. **Create a preset for your terminal** — set the prompt to keep output terse and literal
4. **Create a preset for Slack** — set the prompt to keep things conversational
5. **Assign each preset** to the corresponding app

After that, dictation adapts automatically based on where you're working. Hold the hotkey in GitHub, get a detailed PR description. Hold it in the terminal, get a clean command. Hold it in Slack, get a casual reply.

## Related Posts

- [Why I Switched from Typing to Dictating Git Commits](/blog/switched-typing-to-dictating-git-commits/) — a practical look at per-app presets for your terminal
- [Voice Coding on macOS Without Cloud APIs](/blog/voice-coding-macos-without-cloud/) — the full case for on-device voice input in dev workflows
- [Getting Started with EnviousWispr in Under 2 Minutes](/blog/getting-started-enviouswispr-under-2-minutes/) — setup walkthrough from download to first dictation

No login screen. No pricing page. Just faster prose, wherever your dev workflow needs it.
