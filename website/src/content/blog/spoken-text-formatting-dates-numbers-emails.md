---
title: "Say It, Get It Formatted: Dates, Numbers, Emails, and More"
description: "EnviousWispr formats spoken numbers, dates, times, money, percentages, phone numbers, emails, and web addresses into the way you would actually type them. It runs on your Mac, before any AI step, on every dictation."
pubDate: 2026-06-08
tags: ["dictation", "macos", "productivity", "ai-polish"]
draft: false
author: "Saurabh Vaish"
keywords:
  - "voice to text formatting"
  - "dictate numbers and dates"
  - "dictate email address"
  - "dictate phone number"
  - "spoken numbers to digits"
faqs:
  - question: "Does EnviousWispr turn spoken numbers into digits?"
    answer: "Yes. Say 'seventy eight thousand five hundred forty seven' and you get '78,547', with the thousands separator placed for you. The same applies to decimals, ordinals like 'seventy third' becoming '73rd', percentages, and currency such as 'fifty dollars and thirty cents' becoming '$50.30'."
  - question: "Can I dictate an email address or a website?"
    answer: "Yes. Say 'casey at proton dot me' and you get 'casey@proton.me'. Say 'stackoverflow dot io slash blog' and you get 'stackoverflow.io/blog'. The app recognizes the spoken 'at', 'dot', and 'slash' markers and assembles the address."
  - question: "Do I need AI polish turned on for this?"
    answer: "No. This formatting is a separate, on-device step that runs before AI polish on every dictation. It works whether polish is on or off, and whether you use on-device or cloud polish. There is no setting to enable; it is always on for English."
  - question: "What if a number is ambiguous?"
    answer: "When a phrase could mean more than one thing, the formatter leaves it alone rather than guessing wrong. Idiomatic times like 'quarter past five' stay as words, and a loose phrase like 'one twenty people' is left untouched so the AI step or your own edit can decide. The goal is to never corrupt your text."
---

You say "march fifteenth twenty twenty six," and what you usually get is exactly that: the words, spelled out, waiting for you to turn them into "March 15, 2026." Dictation handles the talking and leaves you the cleanup.

EnviousWispr does the cleanup for you. When you speak a number, a date, a price, an email, or a web address, it writes it the way you would have typed it. This happens on your Mac, before any AI step, on every dictation, in English.

Here is the full list of what it converts.

## Numbers

Spoken numbers become digits, with separators placed correctly.

- "ninety four" becomes "94"
- "seventy eight thousand five hundred forty seven" becomes "78,547"
- "three point one four" becomes "3.14", and "thirty point six zero" keeps its trailing zero as "30.60"

## Ordinals

- "seventy third" becomes "73rd", with the correct ending (st, nd, rd, or th) chosen for you
- Ordinal days inside dates are handled too, so "march fifteenth" becomes "March 15"

## Dates

- "march fifteenth twenty twenty six" becomes "March 15, 2026"
- "january twenty eighth two thousand twenty one" becomes "January 28, 2021"
- Spoken numeric dates work as well: "four slash six slash twenty twenty one" becomes "4/6/2021"

## Years

- "nineteen eighty seven" becomes "1987"
- "twenty twenty six" becomes "2026"
- Leading zeros are handled: "twenty oh six" becomes "2006"

## Times

- "ten thirty a m" becomes "10:30 AM"
- "six fifty p m" becomes "6:50 PM"
- "ten o'clock" becomes "10:00"

Idiomatic times are left as you said them on purpose. "Quarter past five" and "half past three" stay in words, because writing them as "5:15" and "3:30" changes the register of how you were speaking.

## Money

- "six thousand two hundred thirty nine dollars" becomes "$6,239"
- "fifty dollars and thirty cents" becomes "$50.30", always with two decimal places
- Large amounts keep their magnitude word: "eighty million dollars" becomes "$80 million", not "$80,000,000"

## Percentages

- "twenty one percent" becomes "21%"
- "nine percent" becomes "9%"

## Phone numbers

- "eight two four six one nine six one seven five" becomes "824-619-6175"
- A spoken "oh" is treated as a zero, the way people actually read numbers aloud
- It even handles a mix of already-spoken digits and number words in the same breath: "call me at 203 nine five four eight eight seven nine" becomes "call me at 203-954-8879"

## Email addresses

- "casey at proton dot me" becomes "casey@proton.me"
- "riley at gmail dot com" becomes "riley@gmail.com"

It only fires on the clear "name at domain dot something" shape, so an ordinary sentence like "meet me at noon" is never turned into an address by mistake.

## Web addresses

- "github dot io" becomes "github.io"
- "stackoverflow dot io slash blog" becomes "stackoverflow.io/blog"
- Spoken "w w w dot example dot com" becomes "www.example.com"

## Spoken punctuation and breaks

- "hello comma world period" becomes "hello, world."
- "are you free question mark" becomes "are you free?"
- "new paragraph" and "new line" insert the breaks for you

## How it decides what to leave alone

The most important rule in all of this is the one about restraint. An overly eager formatter is worse than none at all, because it quietly corrupts your words before you notice.

So when a phrase is genuinely ambiguous, the app does nothing. "There were one twenty people there" stays exactly as spoken, because "one twenty" could be a count, a time, or a price, and guessing wrong would be worse than leaving it. The idiomatic times above stay in words for the same reason. The design goal is simple: plain prose comes through untouched.

## Where this runs

This is not the AI step. It is a separate, rule-based pass that runs entirely on your Mac, before any polishing, on every dictation in English. That has three practical consequences.

It is fast, it is predictable, and it works even when you turn AI polish off. If you prefer fully [offline, on-device dictation](/blog/macos-dictation-offline-private/) with no polishing model at all, your "78,547" and "March 15, 2026" still come out formatted. And because it runs before polish, the AI step receives clean, formatted text to work with rather than a wall of spelled-out numbers.

There is nothing to switch on. It is on by default for everyone.

## What changes for you

You stop doing the second pass. Numbers, dates, prices, and addresses arrive already typed the way you meant them. Your dictated text is closer to ready the moment it lands.

## Related posts

- [How EnviousWispr works, end to end](/how-it-works/). The on-device pipeline, step by step.
- [Dictate emails at the speed of thought](/blog/dictate-emails-speed-of-thought/). Where formatted numbers and addresses earn their keep.
- [On-device dictation and the small models that polish it](/blog/on-device-dictation-polishing-small-models/). What the AI step does after formatting.

Want to try it? [Download EnviousWispr free](/#download), then dictate a sentence with a date and a dollar amount and watch them format themselves.
