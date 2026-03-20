---
title: "On-Device vs Cloud Dictation on macOS: What's Private"
description: "A fair comparison of on-device and cloud dictation — how each handles your voice data, where recordings go, and what that means for your privacy on macOS."
pubDate: 2026-03-23
tags: ["privacy", "dictation", "comparison", "on-device", "speech-to-text"]
draft: true
---

"Your data is processed securely." Every cloud dictation service says some version of this. Almost none of them tell you what it actually means -- where your audio goes, who can access it, how long it persists, or what happens to it after transcription. The assumption is that you won't ask.

You should ask. Because the difference between on-device and cloud dictation isn't a marketing distinction. It's an architectural one, and it determines whether your recordings stay on your hardware or travel through infrastructure you can't inspect.

## How cloud dictation works

Cloud-based dictation tools follow a straightforward pipeline. Your device records audio from the microphone, compresses it, and sends it over the internet to a remote server. That server runs a speech recognition model — typically a large neural network that requires significant compute resources — and returns the transcribed text to your device.

The appeal is obvious: the provider handles all the heavy computation, so even a low-powered device can get high-quality transcription. The vast majority of commercial speech-to-text services still rely on cloud processing for their primary transcription pipeline.

But there are trade-offs you should understand:

- **Your audio travels over the network.** Even with encryption in transit, the recording exists on someone else's infrastructure during processing.
- **Retention policies vary.** Some providers delete audio immediately after transcription. Others retain recordings for model improvement unless you explicitly opt out. Google's Speech-to-Text API, for example, has a separate data logging opt-in that many developers leave at the default setting without checking (source: Google Cloud Speech-to-Text documentation, accessed March 2026).
- **Third-party subprocessors are common.** Your audio may pass through multiple services before the text comes back.
- **Internet dependency.** No connection means no transcription. Latency depends on server load and your network quality.

None of this makes cloud dictation inherently bad. But it does mean that every time you speak, you're trusting the provider's infrastructure, retention policies, and security practices with a recording of your voice.

## How on-device dictation works

On-device dictation keeps the entire pipeline local. Your microphone captures audio, a speech recognition model processes it directly on your hardware, and the text output stays on your machine. No network request, no server, no third party.

This used to mean serious compromises on accuracy. The models that could run on consumer hardware in 2020 were noticeably worse than their cloud counterparts. That's changed substantially.

In 2022, OpenAI released Whisper, an open-source automatic speech recognition model trained on 680,000 hours of multilingual data. Whisper's accuracy matches or exceeds many commercial cloud APIs, and because the model weights are openly available, it can run locally on capable hardware. Independent benchmarks on LibriSpeech test-clean show Whisper large-v3 achieving word error rates competitive with leading cloud services — the accuracy gap that once justified cloud-only workflows has largely closed.

On Apple Silicon specifically, Apple's Core ML framework compiles neural networks to run natively on the Mac's Neural Engine, GPU, and CPU. [WhisperKit](https://github.com/argmaxinc/WhisperKit), developed by Argmax, wraps Whisper models for Core ML execution. The result is fast, accurate transcription that runs entirely on your Mac — no server required. You can see [how the on-device pipeline works end-to-end](/how-it-works/) if you want to understand where each step happens.

The practical experience: on an M-series Mac — whether it's an M2 MacBook Air or an M4 Pro Mac Mini — a typical dictation segment transcribes in one to two seconds. That's end-to-end, from the moment you stop speaking to the moment text appears.

## Comparison: on-device vs cloud dictation

Here's a fair side-by-side comparison across the dimensions that matter most for daily use.

| Factor | Cloud Dictation | On-Device Dictation |
|--------|----------------|-------------------|
| **Where audio is processed** | Remote servers owned by the provider | Locally on your hardware |
| **Audio leaves your device** | Yes — sent over the network | No — stays on-device |
| **Data retention** | Varies by provider; some retain recordings | Nothing to retain — audio is processed and discarded locally |
| **Internet required** | Yes — always | No — works fully offline |
| **Latency** | Depends on network + server load (typically 1-5 seconds) | Consistent 1-2 seconds on Apple Silicon |
| **Accuracy** | Generally strong; benefits from large server-side models | Comparable with modern models like Whisper large-v3 |
| **Cost** | Often subscription-based or per-minute API pricing | Free if using open-source models locally |
| **Device requirements** | Minimal — server does the work | Needs capable hardware (Apple Silicon recommended) |
| **Offline capability** | None | Full |
| **Model updates** | Automatic, provider-managed | Manual — you choose when to update |

Neither column is universally better. The right choice depends on what you value and what you're dictating.

## When cloud dictation makes sense

Cloud dictation is a reasonable choice when:

- **You're on low-powered hardware** that can't run modern speech models efficiently. Chromebooks, older laptops, and mobile devices benefit from offloading computation.
- **You need support for uncommon languages or dialects** where cloud providers have invested in specialized models that aren't yet available locally.
- **You're dictating non-sensitive content** and prioritize zero-setup convenience. Cloud tools often work out of the box with no model downloads or configuration.
- **You need real-time streaming transcription** for very long sessions. Some cloud APIs handle continuous streaming more gracefully than local models that process in chunks.

There's no shame in choosing cloud dictation for the right use case. The key is knowing you're making that choice — not having it made for you by default.

## When on-device dictation makes sense

On-device dictation is the stronger choice when:

- **You're dictating anything sensitive.** Legal memos, medical notes, financial discussions, proprietary code reviews, internal company communications — anything where the content of the recording matters if it were exposed.
- **You want predictable performance.** No network variability, no server outages, no API rate limits. It works the same whether you're on a plane or in a coffee shop.
- **You care about cost at scale.** Cloud speech APIs typically charge $0.006 to $0.024 per 15 seconds of audio (source: Google Cloud Speech-to-Text and AWS Transcribe published pricing pages, accessed March 2026). For heavy users dictating hours per day, local processing costs nothing beyond the hardware you already own.
- **You prefer zero friction.** On-device tools can work with no sign-up, no API key, and no recurring payment.
- **You want control over your tooling.** Local models don't change unless you change them. No surprise API deprecations, no terms-of-service updates, no forced model swaps.

For many people — especially those dictating work-related content on a Mac — on-device is the more practical default.

## Where EnviousWispr fits

EnviousWispr is an on-device dictation app for macOS. It ships with two transcription backends — Parakeet for fast English dictation and WhisperKit for multi-language support — both running natively via Core ML on Apple Silicon. Your audio is recorded, transcribed, and post-processed — all locally. Recordings never leave your Mac unless you explicitly configure an external API.

<!-- TODO: Screenshot — Menu bar icon: the EnviousWispr menu bar dropdown showing the privacy toggle and on-device processing status -->

Here's what the workflow looks like: hold a hotkey, speak, release. A second or two later, polished text lands on your clipboard or pastes directly into the app you're using. Post-processing — punctuation cleanup, filler word removal, tone adjustment — runs through a local LLM of your choice. Three writing style presets (Formal, Standard, Friendly) let you shape the output for different contexts, with custom prompts and per-app presets coming soon.

Here's what that looks like in practice:

**What you say:**
> so the main takeaway from the security review is that we need to encrypt all user data at rest not just in transit and we also need to uh rotate the API keys quarterly instead of annually which is gonna require some changes to the deployment pipeline

**What gets pasted:**
> The security review identified two required changes: all user data must be encrypted at rest (not just in transit), and API keys need quarterly rotation instead of annual. The deployment pipeline will need updates to support the new rotation schedule.

That entire pipeline — from your voice to polished text — ran locally on your Mac. No audio left the device.

A few specifics worth noting:

- **No sign-up required.** No login, no telemetry, no account walls.
- **Free and open source.** EnviousWispr is available on [GitHub](https://github.com/saurabhav88/EnviousWispr) at no cost.
- **Hands-free mode.** For extended dictation sessions, you can switch to continuous background transcription without holding a key.
- **Privacy toggle (coming soon).** A planned feature that will let you pause all processing with one click — useful during sensitive conversations.
- **Offline by default.** The app works with no internet connection. Network access is only needed if you choose to connect an external API for post-processing.

EnviousWispr doesn't try to be everything for everyone. It's built specifically for macOS users on Apple Silicon who want fast, private dictation that doesn't require trusting a third party with their recordings.

## What actually stays private

To summarize plainly: with on-device dictation, your recordings stay private because they never leave your hardware. There's no retention policy to read because no one else has the data. There are no subprocessors, no terms-of-service clauses about using your audio for training, and no possibility of a server-side data breach exposing your recordings — because the recordings never went to a server.

With cloud dictation, privacy depends on trust. You're trusting the provider's encryption, their retention policies, their access controls, and their compliance with their own stated practices. For many use cases, that trust is well-placed. For others — dictating confidential work, personal health information, or anything you'd rather not explain in a data breach notification — it's a risk that on-device processing eliminates entirely.

The distinction isn't philosophical. It's architectural.

## Related Posts

- [macOS Dictation That Works Offline and Stays Private](/blog/macos-dictation-offline-private/) — a comparison of EnviousWispr against built-in dictation, cloud tools, and competitors
- [Voice Coding on macOS Without Cloud APIs](/blog/voice-coding-macos-without-cloud/) — why on-device matters specifically for developer workflows
- [Getting Started with EnviousWispr in Under 2 Minutes](/blog/getting-started-enviouswispr-under-2-minutes/) — try on-device dictation yourself in minutes

## Getting started with private dictation

If you want to try on-device dictation on your Mac:

1. [Download EnviousWispr free](https://enviouswispr.com/#download) — no account required
2. Open the `.dmg` and drag the app to Applications
3. Grant microphone access when prompted on first launch
4. Choose a Whisper model — `large-v3-turbo` offers the best balance of speed and accuracy on Apple Silicon
5. Hold the hotkey, speak, release

The first model download takes a few minutes. After that, you're dictating privately, offline, with nothing standing between you and your text. The [getting started guide](/blog/getting-started-enviouswispr-under-2-minutes/) walks through the full first-run setup in under two minutes if you want a step-by-step walkthrough. If you run into issues or want to contribute, [open an issue on GitHub](https://github.com/saurabhav88/EnviousWispr).

## Frequently asked questions

### Is on-device dictation as accurate as cloud dictation?

On modern hardware, yes. OpenAI's Whisper large-v3 model achieves word error rates competitive with leading cloud speech APIs. On Apple Silicon, WhisperKit runs these models natively via Core ML, delivering high accuracy without a network connection. For most English dictation, you won't notice a meaningful difference.

### Does on-device dictation work offline?

Yes. Because the speech recognition model runs locally on your hardware, no internet connection is needed. EnviousWispr works fully offline — on a plane, in a basement, or at a coffee shop with your MacBook Air and no Wi-Fi.

### What happens to my audio recordings with cloud dictation?

It depends on the provider. Some delete audio immediately after transcription. Others retain recordings for varying periods, sometimes to improve their models. Always check the provider's data retention and processing policies before using a cloud dictation service for sensitive content.

### Can I use on-device dictation on older Macs?

On-device transcription with modern Whisper models works best on Apple Silicon (M1 and later). Older Intel Macs can run smaller models but with slower performance and reduced accuracy. For the best experience, an M-series Mac is recommended.
