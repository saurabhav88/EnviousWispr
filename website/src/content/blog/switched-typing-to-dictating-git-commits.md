---
title: "Dictating Git Commits on macOS: Better Messages, Less Typing"
description: "Dictating git commits produces better messages than typing. Here's how on-device polish turns spoken explanations into clean, readable commit bodies."
pubDate: 2026-03-16
updatedDate: 2026-04-04
tags: ["developer", "git", "workflow", "dictation"]
draft: false
author: "Saurabh Vaish"
---

Imagine going back through six months of git history. The first three months are the usual graveyard: "fix bug," "update stuff," "misc changes." The last three months? Every commit has a subject line, a body, and actual reasoning. The code didn't change between those two periods. What changed was the input method: the developer switched from typing commit messages to speaking them.

The improvement isn't accidental. It's structural. Speaking and typing produce different kinds of output, and for commit messages, where explaining *why* matters as much as describing *what*, speaking wins by a wide margin.

## Why do typed git commit messages turn into useless one-liners?

Typed git commit messages turn into useless one-liners because typing optimizes for keystrokes and speaking optimizes for explanation. When a developer types `git commit -m "fix bug"`, they have just spent forty-five minutes refactoring a module and understand every change intimately. The terse message is not laziness. It is friction. Switching from code-brain to prose-brain at a terminal prompt feels wrong, and fingers are already positioned for the next file.

Speaking removes that friction. When someone asks what just changed, the explanation comes out in complete thoughts: "I pulled the token validation out of the auth middleware and into its own service because we need to reuse it in the WebSocket handler." That is a useful commit message, and it takes about four seconds to say. Dictation lets a developer stay in flow, capture the why while it is fresh, and never break the loop with a context switch back to prose mode.

Here's a pattern most developers recognize. You've just spent forty-five minutes refactoring a module. You understand every change intimately: which functions moved, why the interface changed, what edge case you finally handled. The diff is clean. You're proud of it.

Then you type `git commit -m "refactor auth module"` and move on.

The problem isn't laziness exactly. It's friction. Typing a good commit message means switching from code-brain to prose-brain. You have to think about sentence structure, capitalize things, decide how much detail is enough. Your fingers are already positioned for the next `vim` session in Terminal. Writing two paragraphs of explanation in a terminal prompt feels wrong.

Speaking, though, is different. When someone asks what just changed, the explanation doesn't require effort. It just comes out. "I pulled the token validation out of the auth middleware and into its own service because we need to reuse it in the WebSocket handler, and the old approach was duplicating logic in three places."

That's a good commit message. And it takes about four seconds to say. The developer stays in the flow. The code is still alive in their head, and the explanation comes out while it's fresh, not after a context switch back to prose mode.

## Why does speaking produce better commit messages than typing?

There's a mechanical reason dictating git commits works better than typing them. When you type, you optimize for keystrokes. Fewer words means less typing. Your brain unconsciously edits for brevity before your fingers even move, and the result is terse to the point of useless.

When you speak, you optimize for explanation. You naturally include the "why": the reasoning, the context, the trade-off you considered. Spoken language tends toward complete thoughts. You say "I moved the config parsing into a separate function because the main function was over 200 lines and impossible to test" instead of typing "extract config parsing."

The other factor is speed. Speaking is roughly three to four times faster than typing for most people. A forty-word commit body that feels like a chore to type takes about eight seconds to dictate. The cost-benefit math changes completely.

Developers who make this switch consistently report the same thing: looking back through their git history, the typed era is full of one-liners while the dictated era has context, reasoning, and descriptions that actually help when revisiting the code six months later.


## Shaping the polish for commit messages

The key to making developer dictation practical is matching the output to the context. Slack replies want casual phrasing. Documentation wants full prose with proper paragraphs.

For commit messages, something stripped down works best: terse, technical, no fluff.

EnviousWispr's default polish already keeps output direct and technical without over-formalizing. No "So basically what I did was..." making it into a commit message. For terminal work, that's usually enough.

For conventional commits, type the short prefix yourself, `feat(auth):` is a couple of seconds, and dictate the part that's actually tedious: the body that explains the why. The polish cleans your spoken explanation; it does not invent structure, so the prefix you want is the prefix you type.

## How the post-processor shapes commit messages

This is where it gets good. EnviousWispr's LLM post-processing step cleans up your spoken words into clean, direct text. The polish strips filler, fixes punctuation, and keeps output direct, which already gets you most of the way to a good commit message.

The trick is to split the work: type the one-line subject (your `type(scope):` prefix and a short summary), then dictate the body, the part that explains the why. The polish cleans that spoken explanation into a tight paragraph. Here's a dictated body before and after the polish:

*You type the subject:* `feat(auth): add rate limiting to login endpoint`

*You dictate the body:* "so we were getting hammered by credential stuffing bots, um, so I added a sliding window counter in Redis with a default of five attempts per minute per IP"

*The polish cleans it to:*

> Credential stuffing bots were hammering the login endpoint. Added a sliding window counter in Redis with a default of five attempts per minute per IP.

That's a commit message worth finding in a git log six months from now, and the explanatory part took about ten seconds to say instead of a minute to type.

## Before and after: typed vs. dictated commits

Here's the difference in practice. In each pair, the terse version is what you'd type in a hurry; the richer version is the commit you end up with when you type the subject and dictate the body, with the polish cleaning it up.

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
timeout. No behavior change; existing tests pass without
modification.
```

The typed versions aren't wrong. They're just useless for future comprehension. The dictated versions took roughly the same amount of time to produce (just speaking instead of typing) but they contain actual information.

## Speech to text in the terminal: practical considerations

A few things worth knowing when using developer dictation daily.

**Accuracy with technical terms is good but not perfect.** On-device speech recognition handles common programming vocabulary well: function names, framework names, language keywords. Occasionally it stumbles on very niche library names or unusual abbreviations. The LLM post-processing step catches most of these.

**You'll feel weird at first.** Talking to your Mac in an open office is awkward. Starting at home helps, and most teams wear headphones anyway. If self-consciousness is a concern, start with commit messages: they're short, private, and the improvement is immediately visible in your git log.

**Type the prefix, dictate the body.** The `feat(auth):` part is a couple of keystrokes; the body, the part that explains the why, is what dictation makes easy. Speak it, and the polish cleans it up.

**It helps with RSI.** After eight-plus hours of typing every day, being able to offload even a portion of that to voice makes a noticeable difference in wrist strain by end of day. If RSI is your primary motivation, there's a dedicated guide on [voice input for RSI](/blog/voice-input-rsi-keyboard-free-workflow/).

## Getting started

If you want to try dictating git commits, here's the minimal setup.

1. [Download EnviousWispr free](/#download) or browse the source [on GitHub](https://github.com/saurabhav88/EnviousWispr) and grant it microphone and accessibility permissions on first launch
2. The speech model downloads automatically on first launch. No model selection needed.
3. Leave AI polish on for direct, technical output; type your `type(scope):` prefix and dictate the body.
4. Open your terminal, hold the hotkey, describe your change, release

That's the whole workflow. Type the subject, hold the hotkey, speak the body, release. The cleaned-up body lands ready to paste under your subject line. EnviousWispr is [free](https://github.com/saurabhav88/EnviousWispr): no account, no API key, no subscription.

## Related Posts

- [Dictation for Developers: Code Reviews and PRs](/blog/dictation-for-developers-code-reviews/). How dictation fits into PR descriptions, review comments, and documentation.
- [Voice Coding on macOS Without Cloud APIs](/blog/voice-coding-macos-without-cloud/). Why on-device transcription matters for developer workflows.
- [Getting Started with EnviousWispr in Under 2 Minutes](/blog/getting-started-enviouswispr-under-2-minutes/). From download to first dictation in minutes.

Your future self, reading `git log` at 2 AM trying to understand why that migration exists, will thank you.

*Sizing up other dictation tools for dev work? See [vs WisprFlow](/compare/wisprflow/), [vs whisper.cpp](/compare/whisper-cpp/), or [browse all comparisons](/compare/).*
