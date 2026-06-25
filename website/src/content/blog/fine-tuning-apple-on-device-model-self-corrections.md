---
title: "I Fine-Tuned Apple's On-Device Model to Fix Spoken Self-Corrections. It Worked, Then Apple Closed the Door."
description: "A LoRA adapter on Apple's macOS 26 Foundation Model took spoken self-correction accuracy from 13% to 86% on held-out cases. Here is the full measurement, the latency cost, and the entitlement wall that ended the experiment."
pubDate: 2026-06-25
tags: ["engineering", "macos", "apple-silicon", "on-device-ai", "fine-tuning", "foundation-models"]
draft: false
author: "Saurabh Vaish"
keywords:
  - "fine-tune apple foundation model"
  - "apple on-device model lora adapter"
  - "macos 26 foundation models framework"
  - "apple intelligence model fine-tuning"
  - "on-device llm polish dictation"
faqs:
  - question: "Can you fine-tune Apple's on-device Foundation Model?"
    answer: "Yes, locally. Apple ships an official adapter training toolkit that lets you train a LoRA adapter against the on-device model. In my test, a rank-32 adapter took spoken self-correction accuracy from 13% to 86% on held-out cases. The catch is shipping: as of macOS 27, Apple stopped accepting the managed entitlement required to deploy a custom adapter to users, so you can train and test but not ship the adapter itself."
  - question: "How much slower is a fine-tuned adapter than the stock model?"
    answer: "On the same Mac, warmed up, the tuned adapter added about 295 ms per polish on average, roughly a 35% increase. The tax scales with length: about +82 ms on short dictations, +248 ms on medium, and +602 ms on long. That number is unaccelerated; I did not compile the adapter's built-in draft model, which may narrow the gap."
  - question: "Is the adapter path still available in macOS 27?"
    answer: "No. The Foundation Models adapter API is marked end of life at version 26 and is not compatible with macOS, iOS, iPadOS, or visionOS 27 and later. Apple replaced it at WWDC26 with a bring-your-own-model path through the new LanguageModel protocol, which lets you run your own tuned model on-device with no adapter entitlement gate."
  - question: "Why does dictation polish struggle with self-corrections?"
    answer: "When you change your mind mid-sentence, like saying 'send it to John, actually Jane,' the cleaned text should read 'Send it to Jane.' The stock on-device model often keeps the abandoned wording or picks the wrong name. It is a narrow but common failure, and it is the one a small fine-tune improved the most."
---

I build a macOS dictation app. The last step in the pipeline is a polish pass: it cleans filler, fixes punctuation, resolves self-corrections, and then pastes the finished text. On macOS 26, that polish can run fully on-device through Apple's Foundation Models framework, the roughly 3-billion-parameter model that powers Apple Intelligence.

The stock on-device model is good at most of this. It struggles with one specific thing: self-correction. If you change your mind mid-sentence, "send it to John, actually Jane" should become "Send it to Jane." The stock model often keeps the abandoned wording or picks the wrong name. Another dictation app ships a fine-tuned open model that handles this well, so I wanted to know whether fine-tuning Apple's own on-device model could close the gap.

I do not have a formal machine learning background. I approached this with strict architectural rigor anyway: I designed the validation pipeline, the dataset, and the mechanical guardrails myself, and used Claude Code to accelerate the implementation. Here is what the data showed.

## What I built

A LoRA adapter, rank 32, about 67 million trainable parameters on top of the 3.2-billion-parameter frozen base, using Apple's official adapter training toolkit.

I trained it on my own labeled dictation data, roughly 2,000 raw-to-cleaned pairs, under the exact prompt the app uses in production. Training under a different prompt than the one you ship makes the adapter worse. That was an early mistake worth flagging.

Training ran on an RTX 4090 with 24 GB, and I validated on an M4 Pro Mac.

## How I measured it

**The baseline.** The stock Apple model, using identical prompts and inputs.

**The test set.** I held back 15% of the data during training and only report on those never-seen cases. Full-corpus numbers look better but include memorized data, which is useless for telling you whether the thing actually generalizes.

**The grading.** I used an ensemble of 12 LLM judges. They graded on meaning, with a pass, weak, or fail verdict, instead of exact string matches. They also ignored numbers, dates, and emojis, because my app handles those deterministically in code rather than leaving them to the model.

## The improvement (held-out, never-seen cases)

- Spoken self-correction resolved correctly: **13% to 86%**.
- General polish (punctuation, homophones, structure): **66% to 83%** (19 of 29 held-out cases).
- Realistic multi-behavior paragraphs: **63% to 84%** (27 of 43 up to 36 of 43).

Regressions were few, but not zero. A small number of held-out cases the stock model already passed came out weak or fail after tuning. These were mostly emoji and other deterministic-layer edge cases my app handles outside the model anyway.

## The latency cost

Stock model versus tuned adapter, both timed on-device on the same Mac, 20 phrases, warmed up:

- Short dictations: **+82 ms (+13%)**.
- Medium: **+248 ms (+31%)**.
- Long: **+602 ms (+52%)**.

Overall, polish went from 846 ms to 1,140 ms, a tax of about **+295 ms (+35%)** per pass.

The tax scales with length. I did not compile the adapter's built-in draft model, the speculative-decoding helper, so this is the unaccelerated number. Compiling it may narrow the gap, though I have not measured that yet.

## Honest caveats

The held-out sample on the self-correction set is small, just 15 cases. The full run was about 1,560 training examples, 3 epochs, no hyperparameter search. I paused there on purpose, because the next part of the story made further tuning beside the point.

## The wall

To actually ship a custom adapter to users, Apple requires a managed entitlement. When I went to request it, the page now reads, verbatim:

> We are no longer accepting entitlement requests. The Foundation Models framework adapter API is not compatible with macOS, iOS, iPadOS, or visionOS 27 and later.

The adapter toolkit is marked end of life at version 26. So this specific path is closed. I can train and test locally, but I cannot get the deploy entitlement needed to ship this adapter to users.

Honestly, I am not that bummed. At WWDC26 earlier this month, Apple introduced a bring-your-own-model path through the new LanguageModel protocol. You can run your own tuned model on-device through Apple's framework with no Foundation Models adapter entitlement gate.

That is the durable version of this experiment, and where I am headed next. The adapter was a fun, disposable proof that a small fine-tune meaningfully moves Apple's on-device model on a real task.

All of the compute here was local, on the 4090 and the Mac, and the judging ran on an existing Claude subscription, so the marginal API spend was zero.

## Where this goes next

For the macOS 27 bring-your-own-model route, the open question is the starting point: a small fine-tuned Gemma, Qwen, or Llama, or something else, for on-device polish-style rewriting at around 3 billion parameters. If you have run this kind of task on-device, I would genuinely like to hear what worked.

EnviousWispr is open source under the GPLv3. You can read the polish pipeline and the on-device model wiring yourself in [the repository](https://github.com/saurabhav88/EnviousWispr).

## Related posts

- [Moving Whisper off the Neural Engine: what we found](/blog/whisperkit-neural-engine-to-gpu/). Another on-device measurement, this one about cold-start latency.
- [Polishing dictation with small on-device models](/blog/on-device-dictation-polishing-small-models/). How local models clean up raw speech.
- [On-device versus cloud dictation, and why privacy is architectural](/blog/on-device-vs-cloud-dictation-privacy/). Why this all runs on your Mac in the first place.

Want to try fully on-device dictation and polish on your own Mac? [Download EnviousWispr free](/#download).
