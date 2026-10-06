---
title: "How to Dictate Version Numbers, Ports and Slash Commands"
description: "Say localhost colon three thousand and get localhost:3000. What to say for versions, IPs, ports, dashed dates and slash commands."
topic: writing-productivity
pubDate: 2026-09-28
tags: ["dictation", "developers", "macos", "productivity"]
draft: false
author: "Saurabh Vaish"
keywords:
  - "dictate version number"
  - "dictate slash command"
  - "voice to text localhost"
  - "dictate ip address mac"
  - "speech to text technical terms"
faqs:
  - question: "How do I dictate a version number like 2.5.0?"
    answer: "In EnviousWispr, a free dictation app for Mac, say \"version two point five point zero\" and it writes version 2.5.0. The spoken dots between digits are joined into one version number rather than written as a decimal and loose words."
  - question: "Can I dictate localhost and a port number?"
    answer: "Yes. Say \"localhost colon three thousand\" and EnviousWispr writes localhost:3000. IP addresses work the same way: \"one nine two dot one six eight dot one dot one\" becomes 192.168.1.1."
  - question: "How do I dictate a slash command such as /clear?"
    answer: "Say \"slash clear\" and you get /clear, even with Spoken punctuation switched off. \"command is slash wfp\" gives command is /wfp, with the space kept. Ordinary phrases like \"slash the budget\" stay as words, though some verb uses such as \"slash prices\" can still become a symbol."
  - question: "Is this formatting done in the cloud?"
    answer: "No. The formatting is a step that runs on your Mac before any AI polish, automatically. Transcription runs on your Mac too. Text leaves your Mac only if you choose a cloud polish provider under your own key, and then it goes directly to that provider."
---

Dictating prose is easy now. Dictating the things developers actually type between sentences is harder: a version number, a local server address, a slash command for a chat tool, a date in the format your logs use. Say "version two point five point zero" and dictation often hands the words back, spelled out, for you to fix by hand.

This post lists exactly what to say for each of those, and what you get back. It uses EnviousWispr, a free dictation app for Mac, whose formatting step handles them on your Mac before any AI polish runs.

## The quick reference

| You say | You get |
|---|---|
| "version two point five point zero" | version 2.5.0 |
| "localhost colon three thousand" | localhost:3000 |
| "one nine two dot one six eight dot one dot one" | 192.168.1.1 |
| "twenty twenty six dash nine dash twenty six" | 2026-09-26 |
| "S dash one" | S-1 |
| "slash clear" | /clear |
| "command is slash wfp" | command is /wfp |
| "pros slash cons" | pros/cons |
| "john dot smith at gmail dot com" | john.smith@gmail.com |
| "docs dot example dot com" | docs.example.com |

Every row comes from the help article [Numbers, Dates and Times](/help/numbers-dates-and-times/) or [Spoken Punctuation and Emoji](/help/spoken-punctuation-and-emoji/), which list the full rules.

## Version numbers come out whole

Say the digits with "point" between them and EnviousWispr joins them into one version: "version two point five point zero" becomes version 2.5.0. That matters because version strings follow a strict pattern (the [Semantic Versioning](https://semver.org/) convention is the common one), and a stray space in "2.5. 0" breaks a search or a changelog.

## Hosts, ports and IP addresses

A host with a spoken colon and a port number becomes one address: "localhost colon three thousand" gives localhost:3000. An IP address said with "dot" between the numbers is written as one: "one nine two dot one six eight dot one dot one" gives 192.168.1.1. Web addresses ending in common endings like .com, .org, .net or .io also come out ready to paste, including ones with several dots.

## Dates in the format your tools use

Say a date with "dash" between its parts and it is written as a dashed date: "twenty twenty six dash nine dash twenty six" becomes 2026-09-26. Said normally, "july eleventh twenty twenty six" becomes July 11, 2026 instead. You choose the format by how you say it.

## Slash commands, without turning on punctuation

Many chat tools, editors and terminal assistants take commands that start with a slash. EnviousWispr writes those even with **Spoken punctuation** switched off, which is its default:

- "slash clear" becomes /clear.
- "command is slash wfp" becomes command is /wfp, with the space kept before the command.
- "pros slash cons" becomes pros/cons.
- "slash the budget" stays as words, because it is a normal phrase.

The honest limit: some verb uses, like "slash prices", can still become a symbol, because the app cannot always tell the verb from a command name. A backslash is different; it needs Spoken punctuation turned on.

## What it will not guess

When a phrase could mean two things, EnviousWispr leaves it as you said it. "Meet at one twenty" is a time and "paid one twenty" is money, so an ambiguous "one twenty" stays in words for you, or the polish step, to settle. This is deliberate: a wrong number in a config value is worse than a word you fix yourself.

## Tool names and project words

Formatting covers the shape of technical text. The names in it, like the build tool your team uses or a library with an odd spelling, are a job for your dictionary. Add a word once and EnviousWispr uses your spelling when it hears it. If you fix a misheard word in text it has pasted, the [Self-Learning Dictionary](/features/self-learning-dictionary/) can save that spelling for you.

## Where it runs

All of this formatting happens on your Mac, before any AI polish, automatically. The spoken-number examples here are for English dictation; addresses, links and codes said with local words also work in French, Spanish, Polish, Dutch, German, Russian, Portuguese and Italian. If polish is off or fails, the formatted text is what gets pasted. Transcription runs on your Mac too, so your voice stays there. Text leaves your Mac only if you pick a cloud polish provider under your own key, and then it goes directly to that provider.

For the feature at a glance, see the [Smart Formatting page](/features/smart-formatting/). If you dictate pull request descriptions and review comments, [Dictation for Developers](/blog/dictation-for-developers-code-reviews/) covers that workflow.
