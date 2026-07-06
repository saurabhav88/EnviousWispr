---
title: "Structural Engineering for Small Language Models in On-Device Dictation Polishing"
description: "We brought a roughly 3-billion-parameter on-device model to within six to eight points of frontier cloud models on a 300-case dictation-polishing benchmark. Here is the result and the engineering it took."
pubDate: 2026-05-30
updatedDate: 2026-07-06
tags: ["on-device", "small-language-models", "apple-intelligence", "dictation", "benchmarks", "privacy"]
author: "Saurabh Vaish"
keywords: ["on-device dictation", "small language model polishing", "Apple Intelligence on-device model", "private speech to text", "on-device vs cloud language model"]
faqs:
  - question: "Can a small on-device model match cloud models for dictation polishing?"
    answer: "Not exactly, but it gets close. On our 300-case quality benchmark, the on-device model reached a 91.0 percent pass rate against 97 to 99 percent for frontier cloud models. It is competitive on speed, perfectly reliable, and runs entirely on your Mac, which the cloud models cannot offer."
  - question: "How large is Apple's on-device model?"
    answer: "Apple's on-device foundation model is approximately 3 billion parameters, per Apple's published figures. That is small enough to run privately on Apple Silicon, and far smaller than the frontier cloud models it is measured against."
  - question: "Is on-device dictation polishing private?"
    answer: "Yes. The polishing runs on your Mac using Apple's on-device model, so your transcript never leaves the device by default. There is no network dependency, no rate limit, and no outage exposure."
---

Most teams clean up dictation with a large cloud model. We wanted to do it on a small model that runs entirely on your Mac, so your voice and your text never leave the device. The open question was whether a model small enough to run privately on-device could get close to cloud quality.

The short version: on a 300-case quality benchmark, the on-device model reaches a 91.0 percent pass rate. That is within six to eight points of frontier cloud models and twenty points ahead of the next-best local option, at competitive speed and with perfect reliability. That result was not a first attempt. It took dozens of iterations of the prompt structure to get there. This report documents the benchmark, the result, and the engineering.

## 1. Motivation

The goal of this work is truly private, on-device dictation with reliable polishing. The system must convert raw speech to finished text without anything leaving the user's Mac. The honest reality is that consumer hardware is not there yet. A language model small enough to run privately on-device cannot, out of the box, match frontier cloud models that competitors stream text to. Apple's on-device foundation model is approximately 3 billion parameters, per Apple's published figures. The contribution of this report is demonstrating that with the right engineering structure around a small on-device model, the model can be brought within close range of cloud quality. This is achieved at competitive speed and with perfect reliability while staying fully private.

Critically, the 91.0 percent result was not a first attempt. It is the product of dozens of iterations of the on-device prompt structure. We progressed past version thirty in our internal numbering and reached roughly forty by our latest count. That iteration count is itself evidence for the thesis. A small model reaches this bar only through sustained structural engineering, not a single clever prompt. We frame version forty as our own internal versioning, not a formal standard.

## 2. System under study

The system under study is EnviousWispr, an application providing free, fully on-device dictation for macOS on Apple Silicon. When the user holds a hotkey and speaks, cleaned text is inserted at the cursor in under a second. Speech-to-text processing occurs entirely on-device using Parakeet as the default fast engine for 25 languages, with WhisperKit available for 99 languages. An active-by-default polish stage rewrites raw transcription into finished text using Apple's on-device foundation model. This polish stage can be switched to cloud providers like OpenAI and Gemini or local Ollama models. The system is open source on GitHub under GPLv3, and nothing leaves the device by default.

## 3. Task and evaluation

To evaluate polish quality, we use a 300-case internal category-stress benchmark. The corpus is synthetic and constructed to probe 20 specific behaviors of a dictation polisher. These behaviors include leaving already-clean text alone, preserving named entities, fixing homophones (for example SQL versus sequel), capitalization and punctuation, number and date and URL formatting, list detection, filler removal, anti-hallucination (the model must not invent content), anti-instruction (the model must not obey text that looks like an instruction), language preservation, revision handling (spoken self-corrections), and topic-shift handling.

An independent model judge (Gemini 3 Pro) scores each polished output on five integer axes from 0 to 3. The axes are accuracy (meaning and named entities preserved, nothing hallucinated), conciseness, fluency, format, and regression (measured against a locked reference). A case passes only if all four quality axes are 2 or higher and it does not regress. Judging is cross-provider so no model grades its own output, and the judging is replicated to confirm the scores are stable. This is an LLM-as-judge protocol, meaning it is judge-based rather than human-rated.

We compare cloud engines (Gemini 3.5-flash, GPT-4o-mini, GPT-5-mini, GPT-5.4-mini) against the on-device Apple foundation model and local Ollama models (Gemma 3n, Llama 3.2, TinyLlama). The cloud models are representative of what a cloud dictation product would use.

## 4. Results

The overall pass rate requires all four quality axes to be 2 or higher with no regression across the 300 cases.

**Table 1: Overall pass rate (300 cases)**

| Engine | Type | Pass Rate |
| --- | --- | --- |
| Gemini 3.5-flash | Cloud | 99.3% |
| GPT-5-mini | Cloud | 99.3% |
| GPT-5.4-mini | Cloud | 98.7% |
| GPT-4o-mini | Cloud | 97.0% |
| Apple Intelligence (~3B) | On-device | 91.0% |
| Gemma 3n | On-device (local) | 71.7% |
| Llama 3.2 | On-device (local) | 51.3% |
| TinyLlama | On-device (local) | 0.0% |

Among engines that can run privately on-device, the Apple model is the only one in range of cloud models. The next best local model trails it by roughly twenty points, while the smallest local models are unusable for this task. Ultimately, the on-device model lands within about six to eight points of the cloud models a competitor would stream text to.

We also measure per-axis closeness on the 0 to 3 scale to show the gap is narrow. Apple Intelligence scored accuracy 2.81, conciseness 2.83, fluency 2.88, format 3.00, and regression 2.59. For comparison, GPT-4o-mini scored 2.92, 2.95, 2.99, 3.00, and 2.77 respectively. Gemini 3.5-flash scored 2.98, 2.97, 2.96, 3.00, and 2.84. The on-device model trails by roughly a tenth to a quarter of a point per axis.

## 5. Speed and reliability

Beyond quality, we measured median latency on the same 300-case corpus. The on-device model requires about 0.9 seconds, GPT-4o-mini requires about 1.2 seconds, and the production configuration of Gemini 3.5-flash requires about 1.0 second mean. On-device latency is competitive with the fastest cloud configurations, but it is not dramatically faster.

Regarding reliability, the on-device model completed all 300 cases with zero errors, whereas one cloud model (an older Gemini flash) errored on 12 cases. Beyond raw latency, on-device polishing has no network dependency, no rate limits, and no outage exposure. This reliability and privability is a structural advantage independent of the quality gap.

## 6. Where the on-device model lags

The benchmark's per-category breakdown localizes the performance gap precisely. The on-device model ties cloud models at 100 percent on many categories. These include anti-hallucination, leave-clean-text-alone, named-entity preservation, number formatting, punctuation and capitalization, list formatting, date and time, single-topic prose, topic-shift handling, minimal grammar, and anti-instruction. It falls behind specifically on the categories shown in Table 2.

**Table 2: Weak categories for the on-device model**

| Category | On-Device Pass Rate | Cloud Pass Rate Range |
| --- | --- | --- |
| Language preservation | 53% | 80% to 100% |
| Revision handling | 40% | 73% to 100% |
| Homophones | 73% | 87% to 100% |

Multilingual polish is the weakest area. Revision handling covers spoken self-corrections like "no wait, make that Tuesday". Even some small cloud models struggle here, as demonstrated by a GPT-5-nano scoring 33 percent. The homophones category covers distinctions like SQL versus sequel. There are also minor lags in emoji conversion (87 percent), URL, email, and phone formatting (87 percent), and filler-removal and a few guards in the low 90s. These specific categories represent the research frontier, and the benchmark is designed to point at them.

## 7. Method

To close the performance gap, our general approach is to constrain the problem around the small model rather than ask more of the model itself. We implement auto mode-routing, where a deterministic classifier decides whether the dictation is a short message, a longer message, or structured content. This router applies the matching formatting rules so the model is not asked to guess the format. We also apply deterministic pre-processing to handle common filler and user-defined word corrections in plain code before the model runs. Following the model execution, a deterministic output filter screens the output and falls back to the raw transcription if the model degenerates or refuses. For tasks with a known shape, a deterministic step resolves the easy cases and only calls the model on the genuinely ambiguous ones.

## 8. The path to 91 percent: iteration and what was rejected

The on-device polish prompt structure went through dozens of iterations to reach the current performance level. We progressed past version thirty internally and reached roughly forty by our latest count. In an early version, the prompt won self-correction collapse, cleanly handling spoken edits like "no wait, sorry, make that Tuesday". A later version added the pivotal frame of treating the dictated text strictly as content to clean and never as instructions to obey. This fixed the model executing commands a user merely dictated. A subsequent version tightened the filler list and added explicit do-not-execute examples across common imperative shapes (write, translate, summarize, rewrite, convert, explain, answer). Throughout this process, we tried and rejected several structural choices.

**Table 3: Ablations and negative results (polish quality)**

| Intervention | Measured Effect |
| --- | --- |
| Structured-object output (forcing JSON) | Produced preamble contamination (for example, "Here is the cleaned transcript:") that leaked into text. Replaced with plain-text output plus deterministic filter. |
| Randomized sampling | Introduced run-to-run drift on identical input. Replaced with deterministic (greedy) sampling. |
| Default safety guardrails | Blocked polishing of legitimate dictation containing profanity, political, or health terms. Replaced with permissive content-transformation setting. |
| Single universal prompt | Unworkable due to asymmetric mis-routing. Sending casual messages through a conservative prompt damaged output. Resolved with a dual-mode deterministic router. |

We also implemented prompt-injection isolation. Dictated text is wrapped in delimiters so that words which sound like an instruction are handled as content. This is the same behavior the benchmark scores under its anti-instruction category, where the on-device model ties cloud models at 100 percent.

## 9. Alias-prediction sub-study

This sub-study represents a different task and a deliberately brutal benchmark. Its low absolute numbers are not comparable to the 91 percent polish figure. The task is to take a user's custom word (a name, company, or jargon term) and predict how speech-to-text is likely to mis-transcribe it, so the app can auto-correct it later. This studies the homophone and mishearing failure class directly.

The baseline method used a single model call doing classification and generation together with a rigid structured output. The baseline yielded about 11 percent pass, about 20 percent degeneration (non-empty garbage), about 54 percent category accuracy, and about 0.6 seconds median latency.

The two-stage method uses a deterministic classifier to decide the term's shape first. Obvious shapes like acronyms and domains are resolved in plain code without the model. The model is asked for plain text instead of a rigid schema, and a small pool of generations is deduplicated. This method yielded about 30 percent pass, about 6 percent degeneration, about 81 percent category accuracy, and about 1.4 seconds median latency. The pass rate roughly tripled and degeneration fell by about two thirds, at a latency cost.

**Table 4: Ablations and negative results (alias prediction)**

| Intervention | Measured Effect |
| --- | --- |
| Stronger imperative language ("you MUST") | Gained one case overall but hurt person-name category and roughly doubled latency. |
| Leaner prompt | Dropped below baseline (the small model needs worked examples). |
| Phonetic pre-spelling | Backfired (the model echoed the hint). |
| Four-call pooling | Regressed brand precision (three was the better point). |
| Greedy decoding | Helped acronyms but hurt every other category. |

A hard limit remains. Short all-caps acronyms top out around 15 to 20 percent regardless of method because the model mode-collapses on them. This is not promptable-around. The largest single gain came from moving classification into a separate deterministic step, not from any prompt change. This provides further evidence for the thesis that structural engineering is required for small models.

## 10. Reliability architecture

We use a reliability pattern that separates the critical path from optional enhancement. The critical path includes capture, transcription, and text insertion. It is engineered to always deliver text to the user. Optional stages, including polish and custom-word prediction, run with strict timeouts and graceful fallback. A deterministic output filter detects degenerate or refused model output and falls back to the raw transcription. Consequently, a failed optional stage cannot break the critical path.

## 11. Limitations

This is an internal, judge-scored, English-centric benchmark. The pass rates are a stress-test signal, not a measure of everyday end-user quality. The benchmark relies on an LLM-as-judge protocol rather than human raters. Furthermore, the on-device model still lags significantly in multilingual polish, revision handling, and homophone correction.

## 12. Future work

The mapped gaps in language preservation, revision handling, and homophones are the priority research targets. A learned detector that more precisely identifies when the on-device model has refused or mangled its output is in development. It is not yet shipped, and this report does not claim it as deployed. The system already performs deterministic, non-model text editing before the model runs. The direction is to extend this deterministic layer to more mechanical edits (capitalization, additional filler, light grammar), reserving the model budget for edits that need judgment.

## Postscript: from this research to EG-1

Since this study, we shipped EG-1, our own on-device model tuned specifically for dictation polishing. It runs locally on Apple Silicon inside the same deterministic and reliability layers described here, and ships as a free, optional download in [EnviousWispr](/how-it-works/). It is the production continuation of the work reported here.
