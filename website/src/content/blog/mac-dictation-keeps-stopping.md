---
title: "Why Mac Dictation Keeps Stopping (and How to Fix It)"
description: "Mac dictation that stops after about 30 seconds, or the moment you pause, has two specific causes. Here is why it happens and how to dictate without the cutoff."
pubDate: 2026-06-06
tags: ["dictation", "productivity", "macos", "troubleshooting"]
draft: false
author: "Saurabh Vaish"
keywords:
  - "mac dictation keeps stopping"
  - "mac dictation stops after 30 seconds"
  - "mac dictation stops when i pause"
  - "macos dictation time limit"
  - "dictate long passages on mac"
faqs:
  - question: "Why does my Mac dictation stop after about 30 seconds?"
    answer: "The built-in dictation on macOS is designed for short, command-style input, and many people hit a cutoff after roughly 30 seconds (slightly longer with the downloaded enhanced model). There is no setting to extend it. If your session ends even sooner than that, the likely cause is the separate stop-on-pause behavior, which you can switch off in System Settings, Keyboard, Dictation. For sustained dictation, a purpose-built tool like EnviousWispr handles passages up to about five minutes at a stretch."
  - question: "How do I stop Mac dictation from ending when I pause?"
    answer: "Open System Settings, then Keyboard, then Dictation, and turn off the option that ends dictation when you stop speaking (the wording varies by macOS version). With it off, a thinking pause will not end the session, although the separate short-session cutoff still applies."
  - question: "Is there a way to dictate long passages on a Mac without it cutting out?"
    answer: "Yes. A dedicated on-device tool removes both limits. EnviousWispr lets you lock recording with a double-press of your hotkey and speak naturally, with pauses, for up to about five minutes per dictation. It then polishes the text and pastes it where you are working, and it runs on-device on Apple Silicon, so your voice never leaves your Mac."
  - question: "Is the fix free?"
    answer: "Configuring the built-in dictation costs nothing. EnviousWispr is also free to download, with no account and no subscription, and it runs entirely on your Mac."
---

You are mid-sentence, thinking through the next clause, and the microphone icon just disappears. The text stops. You reach for the keyboard, restart dictation, and try to pick up your train of thought from wherever it broke off.

If that happens every time you try to dictate more than a sentence or two on your Mac, you are not doing anything wrong. It is how the built-in dictation is designed to behave. The good news is that there are only two causes, both are fixable, and once you know which one you are hitting, you can stop fighting it.

## The two reasons Mac dictation stops

**1. It stops the moment you pause.** macOS has a setting that ends dictation as soon as it hears a stretch of silence. Pause to think, and it assumes you are finished. The microphone icon vanishes, and whatever you say next is lost.

You can turn this off:

- Open System Settings, then Keyboard, then Dictation.
- Find the option named something like "Dictation automatically ends when you stop speaking" (the exact wording varies by macOS version) and switch it off.

With that off, a thinking pause will no longer kill the session.

**2. The built-in session cutoff.** Even with the stop-on-pause setting turned off, the built-in dictation is built around short bursts. Many people hit a stop after roughly 30 seconds, a little longer with the downloaded enhanced model, and there is no setting to extend it. Apple's documentation says you can dictate text of any length, but in practice the experience is tuned for short commands and quick replies, not paragraphs.

That second one is the wall most people run into, and no checkbox fixes it.

## Why the cutoff exists

The built-in dictation was made for short, command-style input: a quick text reply, a search query, a single sentence in Notes. It was not built for sustained dictation, the kind where you talk through a whole email, a paragraph of a draft, or a long message in one go. The short session length and the stop-on-silence behavior both make sense for "say a quick thing." Both get in the way the moment you try to actually write by voice.

So if you are trying to dictate the way you really speak, in full thoughts with natural pauses, you are using a tool outside what it was made for.

## Fixing it for short dictation

If your dictation is genuinely short, the steps above are often enough:

- Turn off the stop-on-pause setting so a pause does not end the session.
- Confirm dictation is enabled and that your microphone is the input you expect (System Settings, Keyboard, Dictation).
- If dictation has stopped working entirely, rather than just cutting off, toggling it off and back on, or restarting, usually clears it.

For a quick reply or a one-line note, the built-in dictation is fine once it is configured this way.

## Fixing it for real, sustained dictation

If you are trying to write by voice, full sentences and full paragraphs, with the pauses that thinking requires, a tool built for that solves the problem at the root instead of working around it.

That is what EnviousWispr is for. A few things make the difference:

- **It does not quit when you pause.** Lock recording with a double-press of your hotkey, then speak naturally with as many thinking pauses as you need. Press once when you are done. (A triple-press cancels.) You do not have to hold a key down for every sentence.
- **It handles long passages.** You can dictate for up to about five minutes at a stretch, not thirty seconds, so a full email or a paragraph of a draft comes out in one piece.
- **Your first words are not clipped.** A short pre-roll buffer captures the very start of your speech, so you do not lose the first word the way quick-start dictation often does.
- **The text comes out clean.** Optional AI polish removes filler words, fixes punctuation and capitalization, and formats the result, so what gets pasted is closer to what you meant than a raw transcript.
- **It stays on your Mac.** Transcription runs on-device on Apple Silicon. Your voice is never sent to a server. It is free, and there is no account.

Here is what that looks like in practice, dictating a message in one take without it cutting out:

**What you say:**

> hey can we push our one on one to thursday afternoon um something came up wednesday morning and I want to give the agenda the time it deserves I'll send over the doc tomorrow so you have a chance to look before we meet

**What gets pasted:**

> Hey, can we push our one-on-one to Thursday afternoon? Something came up Wednesday morning, and I want to give the agenda the time it deserves. I'll send over the doc tomorrow so you have a chance to look before we meet.

No restart, no lost train of thought, no reaching for the keyboard halfway through.

To see how the on-device pipeline works end to end, read [how it works](/how-it-works/). If you want to try it, [download EnviousWispr](/#download). It is free and runs entirely on your Mac.

*Choosing a dictation tool for your Mac? See how it stacks up against [the built-in option](/compare/apple-dictation/) and [a popular paid app](/compare/wisprflow/), or [browse all comparisons](/compare/).*
