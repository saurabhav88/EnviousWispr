---
title: "How We Test EnviousWispr"
description: "The tests behind EnviousWispr's defaults, with the results: speech settings, AI Polish, number formatting, other languages and an independent review."
category: "updates-and-source"
section: "Source Code"
order: 4
keywords: ["how do you test", "benchmark", "benchmarks", "test results", "accuracy test", "why is this the default", "why so few models", "why only two engines", "is it tested", "quality", "independent review", "mostly mac"]
related: ["source-code-and-contributing", "hallucination-protection", "live-transcription-streaming-asr"]
updated: 2026-10-17
deflection: "never_intervene"
---
EnviousWispr is a free, open-source dictation app for Mac. It offers a short list of options. This page lists the tests behind several of its defaults and features, with their results, so you can see the reason for each one.

### Which speech settings did testing decide?

**Faster Transcription ships off.** With it on, the Fast engine (Parakeet) made about twice as many wrong words: word errors went from 2.0% to 3.7%, and about 1 dictation in 24 lost its final words. The test used 28 recordings and a replay of 500 real dictations. The details are in [Faster Transcription](/help/live-transcription-streaming-asr/).

**Spoken punctuation ships off.** In our tests, saying "comma" or "period" out loud conflicted with the punctuation that both speech engines already add. You can turn it on in **Dictation Settings** > **Engine**. See [Spoken punctuation and emoji](/help/spoken-punctuation-and-emoji/).

### How do we test AI Polish?

We grade AI Polish on a fixed set of 1,462 test dictations. When we checked in August 2026, none of them appeared in the training data for EG-1, our own polish model. An AI judge compares each polished result with an answer key and marks it as a pass or a fail.

| What we changed | Test | Before | After |
|---|---|---|---|
| Apple Intelligence instructions, macOS 27 | 1,462 dictations | 85.1% passed | 88.6% passed |
| Apple Intelligence speed, macOS 27 | Median time per dictation | 1,172 ms | 775 ms |
| Apple Intelligence instructions, macOS 26.7 | 300 dictations | 70.0% passed | 83.7% passed |

**Ollama models carry a label only after a test.** The **Recommended** label beside an Ollama model comes from how well it cleaned up dictation in our tests, not from its size. Several of the smallest models produced no acceptable result. See [Using Ollama for fully offline AI Polish](/help/using-ollama-for-fully-offline-ai-polish/).

**Emoji survive the AI step.** Apple Intelligence sometimes deletes emoji from the text it polishes. EnviousWispr puts the deleted emoji back in their places, and in a test on 300 real cases it restored all of them.

**Clear failures are thrown out before pasting.** EnviousWispr checks the polished text and rejects results that invented text or answered your question instead of tidying it. See [Hallucination protection](/help/hallucination-protection/).

### How do we test numbers, dates and money?

EnviousWispr's formatting step writes numbers, dates, times, prices, phone numbers, email addresses and web addresses with fixed rules, not with AI. If AI Polish is on, it runs after this step and can reword the result. On 2,064 English test cases, the result matched the expected text 99.7% of the time.

| Type | Test cases |
|---|---|
| Numbers | 630 |
| Negative numbers | 508 |
| Money | 209 |
| Dates | 200 |
| Times | 155 |
| Phone numbers | 147 |
| Email addresses | 111 |
| Web addresses | 90 |
| Punctuation | 14 |

These test cases are English dictation only. To see what gets formatted in other languages, read [Numbers, dates and times](/help/numbers-dates-and-times/).

### How do we test other languages?

We found that English clean-up rules were removing real words from dictation in other languages. Before the fix, 161 of 207 non-English test transcripts lost a word. After the fix, 1 did.

### What did an independent reviewer find?

The Mostly Mac YouTube channel tested seven Mac dictation apps with the same passages, voice and microphone. In [that review](https://www.youtube.com/watch?v=tkV_A_6HFRQ), EnviousWispr was the only one of the seven to get dictated app names right. These are the reviewer's results, not ours.

### Can I check this myself?

Yes. The app's code and its full change history are public on [GitHub](https://github.com/saurabhav88/EnviousWispr), with more than 2,000 changes since February 2026. See [Source code and contributing](/help/source-code-and-contributing/).
