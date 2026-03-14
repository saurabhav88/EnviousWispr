---
title: "Why I Switched to Dictating Git Commits on macOS"
description: "Dictating git commits produces better messages than typing. Here's how writing style presets and LLM post-processing make voice commit messages practical."
pubDate: 2026-03-16
tags: ["developer", "git", "workflow", "dictation"]
draft: false
---

Last month I went back through six months of my git history. The first three months were the usual graveyard: "fix bug," "update stuff," "misc changes." The last three months? Every commit had a subject line, a body, and actual reasoning. The code hadn't changed. My discipline hadn't changed. The only thing that changed was that I started speaking my commit messages instead of typing them.

I didn't plan for this to work. I just got tired of the friction between finishing a satisfying piece of code and having to shift into prose mode to explain it. Dictating removed that friction entirely.

## The one-line commit message problem

Here's a pattern I bet you recognize. You've just spent forty-five minutes refactoring a module. You understand every change intimately -- which functions moved, why the interface changed, what edge case you finally handled. The diff is clean. You're proud of it.

Then you type `git commit -m "refactor auth module"` and move on.

The problem isn't laziness exactly. It's friction. Typing a good commit message means switching from code-brain to prose-brain. You have to think about sentence structure, capitalize things, decide how much detail is enough. Your fingers are already positioned for the next `vim` session in Terminal. Writing two paragraphs of explanation in a terminal prompt feels wrong.

Speaking, though -- speaking is different. When someone asks you what you just changed, you don't struggle to explain it. You just talk. "I pulled the token validation out of the auth middleware and into its own service because we need to reuse it in the WebSocket handler, and the old approach was duplicating logic in three places."

That's a good commit message. And it took about four seconds to say. You stay in the flow -- the code is still alive in your head, and the explanation comes out while it's fresh, not after you've context-switched back to prose mode.

## Why speaking produces better commit messages

There's a mechanical reason dictating git commits works better than typing them. When you type, you optimize for keystrokes. Fewer words means less typing. Your brain unconsciously edits for brevity before your fingers even move, and the result is terse to the point of useless.

When you speak, you optimize for explanation. You naturally include the "why" -- the reasoning, the context, the trade-off you considered. Spoken language tends toward complete thoughts. You say "I moved the config parsing into a separate function because the main function was over 200 lines and impossible to test" instead of typing "extract config parsing."

The other factor is speed. Speaking is roughly three to four times faster than typing for most people. That forty-word commit body that feels like a chore to type takes about eight seconds to dictate. The cost-benefit math changes completely.

I've been dictating commit messages for a few months now, and looking back through my git history the difference is obvious. The typed era is full of one-liners. The dictated era has context, reasoning, and descriptions that actually help when I revisit the code.

<!-- TODO: Screenshot — Writing style presets: the settings UI showing Formal, Standard, and Friendly options -->

## Choosing the right writing style for commits

The key to making developer dictation practical is matching the tone to the context. When I dictate a Slack reply, I want Friendly mode — natural, conversational. When I dictate documentation, I want Formal — full prose with proper paragraphs.

But for commit messages, I want something stripped down: terse, technical, no fluff.

EnviousWispr ships with three writing style presets — **Formal**, **Standard**, and **Friendly** — and for terminal work, Standard hits the sweet spot. It cleans up filler words, fixes punctuation, and keeps output direct without over-formalizing. No "So basically what I did was..." making it into a commit message. The post-processor keeps things technical and to the point.

> **Coming soon:** Per-app presets will make this even smoother. You'll assign a writing style to Terminal, a different one to Slack, another to your browser — and EnviousWispr will apply the right rules automatically based on which app has focus. No switching, no remembering to toggle anything.

## How the post-processor shapes commit messages

This is where it gets good. EnviousWispr's LLM post-processing step cleans up your spoken words into properly structured text. The Standard preset strips filler, fixes punctuation, and keeps output direct — which already gets you most of the way to a good commit message.

> **Coming soon:** Custom prompts will let you go even further — defining exact formatting rules like "output as a conventional commit with type, scope, and body." You'll be able to tell the post-processor precisely how to structure your commits, changelogs, or any other output format.

Even with the current presets, the results are surprisingly good. When I hold the hotkey and say:

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

**Accuracy with technical terms is good but not perfect.** WhisperKit handles common programming vocabulary well -- function names, framework names, language keywords. Occasionally it stumbles on very niche library names or unusual abbreviations. The LLM post-processing step catches most of these.

**You'll feel weird at first.** Talking to your M2 MacBook Air in an open office is awkward. I started doing it at home and eventually stopped caring. Most of my team wears headphones anyway. If you're self-conscious, start with commit messages -- they're short, private, and the improvement is immediately visible in your git log.

**Switching presets becomes second nature.** You'll quickly build a habit of toggling between Standard for terminal work and Friendly for Slack before you dictate. It's a single click. And when per-app presets ship, even that click goes away — EnviousWispr will detect the focused app and apply the right style automatically.

**It helps with RSI.** This wasn't my original motivation, but after eight-plus hours of typing every day, being able to offload even a portion of that to voice makes a noticeable difference in wrist strain by end of day. If RSI is your primary motivation, we have a dedicated guide on [voice input for RSI](/blog/voice-input-rsi-keyboard-free-workflow/).

## Getting started

If you want to try dictating git commits, here's the minimal setup.

1. Download EnviousWispr from the [releases page](https://github.com/saurabhav88/EnviousWispr/releases) and grant it microphone and accessibility permissions on first launch
2. Pick a Whisper model -- `large-v3-turbo` is the best balance of speed and accuracy on Apple Silicon
3. Select the **Standard** writing style preset — it keeps output direct and technical, which works well for commit messages
4. Open your terminal, hold the hotkey, describe your change, release

That's the whole workflow. Hold, speak, release. Your commit message lands formatted and ready to go. EnviousWispr is [free and open source](https://github.com/saurabhav88/EnviousWispr) — no account, no API key, no subscription.

## Related Posts

- [Dictation for Developers: Code Reviews and PRs](/blog/dictation-for-developers-code-reviews/) — how dictation fits into PR descriptions, review comments, and documentation
- [Voice Coding on macOS Without Cloud APIs](/blog/voice-coding-macos-without-cloud/) — why on-device transcription matters for developer workflows
- [Getting Started with EnviousWispr in Under 2 Minutes](/blog/getting-started-enviouswispr-under-2-minutes/) — from download to first dictation in minutes

Your future self, reading `git log` at 2 AM trying to understand why that migration exists, will thank you.
