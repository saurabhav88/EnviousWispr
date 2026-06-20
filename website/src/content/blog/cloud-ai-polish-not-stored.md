---
title: "Cloud AI Polish: Why Your Dictation Isn't Stored"
description: "Use your own OpenAI or Gemini key for AI polish and EnviousWispr asks the provider not to retain your dictation. Here's what that means and how we did it."
pubDate: 2026-05-05
updatedDate: 2026-05-15
tags: ["privacy", "ai-polish", "byok", "openai", "gemini"]
draft: false
author: "Saurabh Vaish"
faqs:
  - question: "What does store=false actually do at OpenAI and Gemini?"
    answer: "It tells the provider not to retain that specific request and its response in their server-side history. OpenAI documents this as a per-request flag on the Chat Completions API. Google added an equivalent per-request flag to Gemini's generateContent endpoint. Both are independent of any project-level setting, so the request opts out even if your account defaults are different."
  - question: "Does this mean my dictation is private end to end?"
    answer: "When you use a fully on-device polish provider like Apple Intelligence or Ollama, the audio and text never leave your Mac. When you use cloud polish with OpenAI or Gemini, the polished text segment travels to the provider so the model can rewrite it. EnviousWispr never sees or stores any of it. With store=false, we ask the provider not to retain it after answering, and the provider's data policy governs what they actually keep."
  - question: "Why use cloud polish at all if on-device polish exists?"
    answer: "On-device polish is the default for a reason: nothing leaves your Mac. Cloud polish is there for people who want the rewriting quality of a larger model, or who already have an OpenAI or Gemini key for other work and want the same model handling their dictation. The choice is yours, and EnviousWispr makes the privacy posture explicit either way."
  - question: "Does store=false stop the provider from training on my data?"
    answer: "It opts the request out of server-side history retention, which is the path most provider training pipelines depend on. Provider-level training opt-outs are a separate setting, and OpenAI and Gemini already exclude API traffic from training by default for paid usage. Setting store=false adds a request-level signal on top of that posture."
  - question: "How can I verify this myself?"
    answer: "EnviousWispr is source-available. The OpenAI request lives in Sources/EnviousWisprLLM/OpenAIConnector.swift and the Gemini request lives in Sources/EnviousWisprLLM/GeminiConnector.swift. Both include store: false in the JSON body sent to the provider. You can also inspect the network request from your own machine if you want to confirm."
---

If you bring your own OpenAI or Gemini key to handle AI polish, the next question is the natural one. What does the provider keep? Your dictation is your words, your tone, the things you wouldn't paste into a public form. So the provider's behavior matters as much as ours.

EnviousWispr now tells both providers, on every request, not to retain it. The flag is small. The posture is straightforward. Here's what's true today.

## The flag we send

OpenAI's Chat Completions API and Google's Gemini API both accept a per-request flag called `store`. When it's set to `false`, it asks the provider not to retain that request and response in their server-side history; the provider's data policy governs what is actually kept. EnviousWispr sends `"store": false` on every cloud polish call: OpenAI's polish requests, Gemini's polish requests, the model-probe call we make to confirm a key works, and the prewarm call we use to warm up a fresh session.

That posture is independent of whatever your account defaults are. Even if your project is configured with logging on, the request itself opts out.

This was added in two passes. The OpenAI flag landed first. The Gemini equivalent shipped on May 5, 2026 once Google's documented per-request `store` boolean was confirmed against the live API.

## What it means at OpenAI

OpenAI's `store` parameter tells the Chat Completions endpoint not to keep the prompt or completion in their request history. The Conversations dashboard reflects only requests that were stored. With `store: false`, the request transcribes, the model answers, and it stays out of your account history for later viewing or reuse. That last part is a request to the provider, not a guarantee about their systems: their published data policy governs actual retention.

OpenAI separately states that API traffic is not used to train their models for customers paying through the API. The `store: false` flag is a per-request reinforcement of that posture: it removes the data path that retention would have used.

## What it means at Gemini

Gemini's generateContent and streamGenerateContent endpoints accept the same `store` parameter at the request level. Google documents it as a logging control. EnviousWispr sends `"store": false` on the polish call, on the lightweight content probe used to verify a key, and on the model-discovery call that lists which models your key has access to.

Google's posture, like OpenAI's, is that paid Gemini API usage is excluded from training by default. Sending `store: false` is the request-level signal that goes with that posture instead of leaning on the account-level defaults.

## Two layers of privacy

When you use cloud polish, two parties touch the polish step. EnviousWispr is one. The provider is the other.

EnviousWispr's side is straightforward and has been since launch. We don't have a server. There is no EnviousWispr account, no telemetry of your dictation content, no copy of your audio, and no copy of the polished text on our infrastructure. Your audio is captured on your Mac, transcribed on your Mac, and the transcript is sent directly from your Mac to the provider when cloud polish is selected. The polished text comes back the same way. We are not in the middle.

The provider's side is what `store: false` addresses. Now their copy of the request and response, the part that would otherwise sit in your account's history, is opted out at the request level.

For a deeper look at where the audio actually flows, see [the on-device pipeline](/how-it-works/) and our [on-device versus cloud dictation comparison](/blog/on-device-vs-cloud-dictation-privacy/).

## What this does not change

A few honest qualifications.

`store: false` does not turn cloud polish into on-device polish. The polished text segment still travels to the provider's servers so the model can rewrite it. If you want a workflow where nothing leaves your Mac at all, [offline dictation with on-device polish](/blog/macos-dictation-offline-private/) is the right setup. Apple Intelligence and Ollama both run polish locally on Apple Silicon.

`store: false` is also not a substitute for reading the provider's data policy. Both OpenAI and Gemini publish their retention and processing terms, and those terms govern what happens at their end of the wire. The request-level flag sits on top of those terms, not in place of them.

Finally, this is a small change in the request body, not a rewrite of the polish path. The reason it is worth a blog post isn't the engineering. It is that bring-your-own-key users keep asking what the provider does with their text, and the answer should be on the website and in the source, not buried in a commit.

## How to verify

The OpenAI request body is built in `Sources/EnviousWisprLLM/OpenAIConnector.swift`. The Gemini request body is built in `Sources/EnviousWisprLLM/GeminiConnector.swift`. Both include `"store": false` in the JSON sent to the provider. If you want to confirm against your own traffic, run a network capture on your Mac while a polish call is in flight; the flag is in the request body. EnviousWispr is source-available on [GitHub](https://github.com/saurabhav88/EnviousWispr), so the audit is right there.

## What changes for you

Nothing in your day-to-day. Hold the hotkey, speak, release. Polished text lands in your clipboard or pastes into the app you're using, the same as before.

What changed is what the cloud provider is asked not to retain when polish runs through your key. The provider's terms govern actual retention.

## Related posts

- [Is cloud dictation private? On-device versus cloud on macOS](/blog/on-device-vs-cloud-dictation-privacy/). Where audio actually goes for each architecture.
- [macOS dictation that works offline and stays private](/blog/macos-dictation-offline-private/). The fully-local setup, including on-device polish.
- [Getting started with EnviousWispr in under 2 minutes](/blog/getting-started-enviouswispr-under-2-minutes/). From download to first dictation.

If you want to try it, [download EnviousWispr free](/#download). Use Apple Intelligence or Ollama for on-device polish, or bring your own OpenAI or Gemini key and let the request-level flag do its small but specific job.
