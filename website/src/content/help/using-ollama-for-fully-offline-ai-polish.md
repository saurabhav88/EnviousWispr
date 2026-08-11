---
title: "Using Ollama for Fully Offline AI Polish"
description: "Running AI Polish through a local model with Ollama."
category: "ai-polish"
section: "Polish"
order: 6
keywords: ["ollama", "offline ai", "local ai", "local model", "llama", "run ai locally", "no internet ai", "free local"]
related: ["ollama-polish-not-working"]
updated: 2026-08-11
---
Ollama is a separate free application that runs language models directly on your Mac, and EnviousWispr can hand your dictation to one of those models for tidying up. Once you have completed the setup, you do not need an API key or an account, and your transcribed text stays on your Mac.

Ollama offers both models that download to run on your machine and models that run on Ollama's own servers. The hosted models send your transcribed text over the internet. EnviousWispr lists them under their own heading in the model list and never selects one automatically, so if you want your text to stay local, choose a model that is not in that group.

### Setting up Ollama

You need an internet connection to install Ollama and download a model, but polish works offline after that.

One thing to know before you download anything: no local model handled languages other than English well in our tests. If you dictate in another language, this is not the polish option to reach for first.

Follow these steps to connect EnviousWispr to Ollama.

**Install Ollama.** Download and install the application from [ollama.com](https://ollama.com).

**Open Ollama.** Launch the application so it runs in the background.

**Download a model.** Open Terminal and run `ollama pull qwen2.5:3b`, or use the model download tools inside the Ollama application.

**Open AI Polish settings.** Open EnviousWispr, go to **Settings**, and select **AI Polish**.

**Select your model.** Choose **Ollama** as your provider, then pick your downloaded model from the list.

EnviousWispr finds your installed models on its own, so they appear in that list without any configuration. You can download and remove local models from the same settings page. Hosted models use Add instead, and there is nothing on your Mac to remove.

### Picking a model

Start with `qwen2.5:3b`, the model EnviousWispr suggests. It scored best of the local models we offer when we tested how well each one cleans up dictation. `qwen2.5:7b` also carries the Recommended label and is the more careful of the two, though it is slower and larger.

The label beside each model in Settings comes from those tests, not from the model's size. Size is not a quality rating. Several of the smallest models EnviousWispr offers produced no acceptable result in our tests, so a smaller download can mean much worse cleanup without reliably solving a timeout. If polish feels slow, choose one of the two Recommended models rather than the smallest one you can find.

### If Ollama is not running

If Ollama is not running when you dictate, the polish step is skipped. You still get your text, without the AI clean-up. Ollama has to be running by the time AI polish starts, which is a moment after your speech finishes transcribing.

### An option with nothing to install

If you want AI polish on your Mac without installing a separate application, try EG-1, the model Envious Labs built for this. It downloads from inside the EnviousWispr settings and needs no other software.
