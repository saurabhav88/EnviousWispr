---
title: "Why I Switched from Typing to Dictating Git Commits"
description: "Dictating git commits produces better messages than typing. Here's how per-app presets and custom prompts make voice commit messages practical."
pubDate: 2026-03-11
tags: ["developer", "git", "workflow", "dictation"]
draft: false
---

My commit messages used to be terrible. Not because I didn't know what I'd changed -- I always knew. The problem was that typing a commit message felt like a chore wedged between the satisfying part (writing code) and the next satisfying part (writing more code). So I'd type "fix bug" or "update stuff" and move on.

I knew this was bad. Every developer knows this is bad. We've all stared at a `git log` six months later and wondered what "misc changes" could possibly mean. But knowing something is bad and actually changing the behavior are two different things.

What changed for me was dictating git commits instead of typing them.

## The one-line commit message problem

Here's a pattern I bet you recognize. You've just spent forty-five minutes refactoring a module. You understand every change intimately -- which functions moved, why the interface changed, what edge case you finally handled. The diff is clean. You're proud of it.

Then you type `git commit -m "refactor auth module"` and move on.

The problem isn't laziness exactly. It's friction. Typing a good commit message means switching from code-brain to prose-brain. You have to think about sentence structure, capitalize things, decide how much detail is enough. Your fingers are already positioned for the next `vim` session. Writing two paragraphs of explanation in a terminal prompt feels wrong.

Speaking, though -- speaking is different. When someone asks you what you just changed, you don't struggle to explain it. You just talk. "I pulled the token validation out of the auth middleware and into its own service because we need to reuse it in the WebSocket handler, and the old approach was duplicating logic in three places."

That's a good commit message. And it took about four seconds to say.

## Why speaking produces better commit messages

There's a mechanical reason dictating git commits works better than typing them. When you type, you optimize for keystrokes. Fewer words means less typing. Your brain unconsciously edits for brevity before your fingers even move, and the result is terse to the point of useless.

When you speak, you optimize for explanation. You naturally include the "why" -- the reasoning, the context, the trade-off you considered. Spoken language tends toward complete thoughts. You say "I moved the config parsing into a separate function because the main function was over 200 lines and impossible to test" instead of typing "extract config parsing."

The other factor is speed. Speaking is roughly three to four times faster than typing for most people. That forty-word commit body that feels like a chore to type takes about eight seconds to dictate. The cost-benefit math changes completely.

I've been dictating commit messages for a few months now, and looking back through my git history the difference is obvious. The typed era is full of one-liners. The dictated era has context, reasoning, and descriptions that actually help when I revisit the code.

## Setting up per-app presets for your terminal

The key to making developer dictation practical is that you don't want the same processing rules everywhere. When I dictate into Slack, I want natural conversational tone. When I dictate into a document, I want full prose with proper paragraphs.

But when I dictate into the terminal, I want something specific: terse, technical, no fluff, and formatted for git.

EnviousWispr handles this with [per-app presets](/how-it-works/). You create a preset for Terminal (or iTerm2, or whatever you use), and it applies different post-processing rules automatically based on which app has focus. No switching modes, no remembering to toggle anything. The app detects that your terminal is in the foreground and applies the right prompt.

For my terminal preset, I keep things stripped down. No filler words (obviously -- the LLM handles that regardless), but also no conversational padding. I don't want "So basically what I did was..." making it into a commit message. The preset tells the post-processor to keep output direct and technical.

## Custom prompt: format as conventional commit

This is where it gets good. EnviousWispr lets you define custom prompts that tell the local LLM exactly how to process your speech. For git commits, I use a prompt that formats my spoken words into conventional commit format with a subject line and body.

Here's roughly what my custom prompt looks like:

> Format the following as a conventional commit message. First line should be a conventional commit subject (type, optional scope, colon, imperative description) under 72 characters. If the spoken input includes reasoning or context, add a blank line and a commit body with that detail. Remove filler words and conversational tone. Keep technical terms exact. Do not invent information that wasn't spoken.

So when I hold the hotkey and say:

*"feat auth -- I added rate limiting to the login endpoint because we were getting hammered by credential stuffing bots. It uses a sliding window counter in Redis with a default of five attempts per minute per IP."*

The post-processor outputs:

```
feat(auth): add rate limiting to login endpoint

Credential stuffing bots were hammering the login endpoint. Added
sliding window counter in Redis with a default of five attempts per
minute per IP.
```

That's a commit message I'd be happy to find in a git log six months from now. And it took me about ten seconds to produce, including the hotkey hold.

## Before and after: typed vs. dictated commits

Here are some real examples from my own git history, comparing the typed era to the dictated era.

**Typed:** `fix tests`
**Dictated:**
```
fix(api): correct assertion in user endpoint integration tests

The test was comparing against a stale fixture that didn't include the
new email_verified field added in v2.3. Updated fixture and added
explicit check for the field.
```

**Typed:** `update readme`
**Dictated:**
```
docs: rewrite installation section for clarity

The previous instructions assumed Homebrew and skipped the manual
install path. Added both options with platform-specific notes for
Apple Silicon vs. Intel.
```

**Typed:** `refactor`
**Dictated:**
```
refactor(db): extract connection pooling into dedicated module

Connection pool setup was duplicated across three service files.
Moved to a shared module with configurable pool size and idle
timeout. No behavior change -- existing tests pass without
modification.
```

The typed versions aren't wrong. They're just useless for future comprehension. The dictated versions took roughly the same amount of time to produce -- I just spoke instead of typed -- but they contain actual information.

## Speech to text in the terminal: practical considerations

A few things I've learned from using developer dictation daily.

**Accuracy with technical terms is good but not perfect.** WhisperKit handles common programming vocabulary well -- function names, framework names, language keywords. Occasionally it stumbles on very niche library names or unusual abbreviations. The LLM post-processing step catches most of these, especially if your custom prompt tells it to preserve technical terms.

**You'll feel weird at first.** Talking to your computer in an open office is awkward. I started doing it at home and eventually stopped caring. Most of my team wears headphones anyway. If you're self-conscious, start with commit messages -- they're short, private, and the improvement is immediately visible in your git log.

**Per-app presets matter more than you'd think.** Without them, you'd need to mentally switch between "terminal mode" and "Slack mode" every time you dictate. The fact that EnviousWispr detects the focused app and applies the right processing rules automatically is what makes this sustainable as a daily workflow.

**It helps with RSI.** This wasn't my original motivation, but after eight-plus hours of typing every day, being able to offload even a portion of that to voice makes a noticeable difference in wrist strain by end of day. If RSI is your primary motivation, we have a dedicated guide on [voice input for RSI](/blog/voice-input-rsi-keyboard-free-workflow/).

## Getting started

If you want to try dictating git commits, here's the minimal setup.

1. Download EnviousWispr from the [releases page](https://github.com/saurabhav88/EnviousWispr/releases) and grant it microphone and accessibility permissions on first launch
2. Pick a Whisper model -- `large-v3-turbo` is the best balance of speed and accuracy on Apple Silicon
3. Create a per-app preset for your terminal app
4. Add a custom prompt that formats output as conventional commits (use the example above as a starting point)
5. Open your terminal, hold the hotkey, describe your change, release

That's the whole workflow. Hold, speak, release. Your commit message lands formatted and ready to go. EnviousWispr is [free and open source](https://github.com/saurabhav88/EnviousWispr) — no account, no API key, no subscription.

## Related Posts

- [Dictation for Developers: Code Reviews and PRs](/blog/dictation-for-developers-code-reviews/) — how dictation fits into PR descriptions, review comments, and documentation
- [Voice Coding on macOS Without Cloud APIs](/blog/voice-coding-macos-without-cloud/) — why on-device transcription matters for developer workflows
- [Getting Started with EnviousWispr in Under 2 Minutes](/blog/getting-started-enviouswispr-under-2-minutes/) — from download to first dictation in minutes

Your future self, reading `git log` at 2 AM trying to understand why that migration exists, will thank you.
