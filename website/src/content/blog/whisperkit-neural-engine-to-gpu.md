---
title: "Moving Whisper Off the Neural Engine: What We Found"
description: "We moved our Whisper-based engine from the Neural Engine to the GPU and watched a 109-second cold start fall to about 13, with no hit to transcription speed."
pubDate: 2026-06-09
tags: ["engineering", "macos", "apple-silicon", "performance", "whisper"]
draft: false
author: "Saurabh Vaish"
keywords:
  - "whisperkit gpu vs neural engine"
  - "coreml compute units"
  - "apple neural engine cold start"
  - "on-device speech recognition performance"
  - "whisper apple silicon"
faqs:
  - question: "Did moving Whisper to the GPU make transcription faster?"
    answer: "Transcription speed stayed essentially the same: about 0.70 seconds on the GPU versus about 0.75 seconds on the Neural Engine for the same clip. The large win was in cold start. The first-launch model compile dropped from roughly 109 seconds on the Neural Engine to about 13 seconds on the GPU on a current Apple Silicon Mac."
  - question: "Why was the Neural Engine slow to start?"
    answer: "The Neural Engine needs an ahead-of-time compile of the model the first time it runs on a given system, and that compiled cache does not survive a macOS update. Every update wipes it, forcing a fresh compile. On our test machine that compile took around 109 seconds, during which the engine was not ready."
  - question: "Does the GPU version use more disk space?"
    answer: "No. Both paths build the same compiled-model cache. The GPU does not avoid that cost. It simply produces the cache far faster, so the not-ready window is much shorter."
  - question: "Does this affect the default engine?"
    answer: "No. This change is specific to the optional Whisper-based engine you can switch to. The default engine was already starting quickly and was left as it was."
---

EnviousWispr ships with two transcription engines. Most people stay on the default one. The other is a Whisper-based engine you can switch to, and it had a problem that was easy to miss in normal use and impossible to miss at the worst possible moment.

The first time you ran it, or right after a macOS update, you would press the dictation key and wait. Not for a couple of seconds. For closer to two minutes, staring at a "preparing" state with no way to know it would eventually work.

We moved that engine off the Apple Neural Engine and onto the GPU. The cold start went from about 109 seconds to about 13. Transcription speed did not change. This post is the measurement and the reasoning, because the result was more interesting than "we flipped a setting."

## What we actually changed

On Apple Silicon, a Core ML model can be told which hardware to run on: the CPU, the GPU, the Neural Engine, or some combination. Our Whisper-based engine was asking for the Neural Engine for both halves of the model, the audio encoder and the text decoder.

The change was to ask for the CPU-and-GPU combination instead. That is a small edit in the model configuration. The effect was not small.

## The cold-start problem

The Neural Engine is wonderful at running a model once the model is ready for it. Getting it ready is the catch. The first time a given model runs on a given machine, the system performs an ahead-of-time compile, translating the model into the form the Neural Engine executes, and caches the result.

Two facts make that cache fragile. It is large. And it does not survive a macOS update, which throws it away. So the slow compile is not a one-time new-install cost. It comes back every time you update your operating system, which is exactly when you are least expecting your tools to misbehave.

On our test machine, a current M-series Mac, that compile took roughly 109 seconds. For that whole window the engine was not ready, and a dictation press in that window went nowhere.

## What the GPU did

The GPU path needs its own compile, and it builds the same cache. The difference is how long that takes. The GPU produced its cache in about 13 seconds, against the Neural Engine's 109. That is about an eight-fold reduction in the not-ready window for the same work and the same disk footprint.

To be completely honest, the GPU does not escape the cost. It pays it far faster. Thirteen seconds is short enough that the app's startup warm-up usually finishes before you make your first press, so on a modern Mac the wait you used to hit becomes something most people never see.

## The result we expected to lose, and did not

The reason this was not an obvious change is the conventional wisdom: the Neural Engine is the efficient, fast place to run inference, and the GPU is the fallback. We expected to trade some steady-state transcription speed for the faster start, and we measured carefully to see how much.

There was nothing to trade. For the same audio, the GPU transcribed in about 0.70 seconds where the Neural Engine took about 0.75. Within the margin of error, it was the same speed.

We also looked for a first-inference penalty, the common pattern where the very first transcription after a model loads is slow because the hardware is still warming up. On the GPU there was not one. The first transcription ran at full speed, the same as the ones after it. Once the engine reports ready, your first press is as quick as any later press, so there was no need for a throwaway warm-up transcription to hide a penalty that was not there.

## What we took away from it

A few things worth keeping.

**The compile, not the inference, was the bottleneck.** It is tempting to optimize the part of a system that runs constantly. Here, the part that ran once (the cold compile) was the entire user-facing problem, hiding behind a "preparing" spinner where it was easy to ignore.

**A cache a macOS update wipes is a recurring cost, not a setup cost.** We had been reasoning about cold start as a fresh-install event. It is really an after-every-update event. That reframing is what made the 109 seconds unacceptable rather than tolerable.

**The "right" accelerator depends on which cost you are paying.** The Neural Engine is the textbook choice for running a model. For this model, on this product, where the felt cost was the wait before the first word, the GPU was simply better, and it cost us nothing on the part the Neural Engine is supposed to win.

## Honest limits

This measurement is from a current Apple Silicon Mac. Older Macs will compile more slowly, and the configuration we used falls back gracefully on hardware without a usable GPU, so nobody ends up worse off than the Neural Engine path. We did not measure battery draw; the GPU likely draws more during the compile, but over a far shorter window. And this is one engine, the optional Whisper-based one. The default engine was already quick to start and we left it alone.

You can read the engine configuration yourself. EnviousWispr is open source, and the compute-unit choice lives in the Whisper backend in [the repository](https://github.com/saurabhav88/EnviousWispr).

## What changes for you

If you use the Whisper-based engine, the long wait after a fresh install or a macOS update is largely gone. Transcription feels the same as it always did once you are going. The difference is at the start, where there used to be a wall.

## Related posts

- [How EnviousWispr works, end to end](/how-it-works/). The full on-device pipeline.
- [Building commercial software solo with Claude Code](/blog/building-commercial-software-solo-with-claude-code/). More notes from the build.
- [macOS dictation that works offline and stays private](/blog/macos-dictation-offline-private/). Why on-device matters in the first place.

Curious to try the local engines on your own Mac? [Download EnviousWispr free](/#download).
