---
title: "Using Ollama for Fully Offline AI Polish"
description: "Running AI Polish through a local model with Ollama."
category: "ai-polish"
section: "Polish"
order: 6
keywords: ["ollama", "offline ai", "local ai", "local model", "llama", "run ai locally", "no internet ai", "free local"]
related: ["ollama-polish-not-working"]
updated: 2026-08-06
---
Ollama is a separate free application that runs language models directly on your Mac, and EnviousWispr can hand your dictation to one of those models for tidying up. Once you have completed the setup, you do not need an API key or an account, and your transcribed text stays on your Mac.

Ollama offers both models that download to run on your machine and models that run on Ollama's own servers. The hosted models send your transcribed text over the internet. EnviousWispr lists them under their own heading in the model list and never selects one automatically, so if you want your text to stay local, choose a model that is not in that group.

### Setting up Ollama

You need an internet connection to install Ollama and download a model, but polish works offline after that. Follow these steps to connect EnviousWispr to Ollama.

**Install Ollama.** Download and install the application from [ollama.com](https://ollama.com).

**Open Ollama.** Launch the application so it runs in the background.

**Download a model.** Open Terminal and run `ollama pull llama3.2`, or use the model download tools inside the Ollama application.

**Open AI Polish settings.** Open EnviousWispr, go to **Settings**, and select **AI Polish**.

**Select your model.** Choose **Ollama** as your provider, then pick your downloaded model from the list.

EnviousWispr finds your installed models on its own, so they appear in that list without any configuration. You can download and remove local models from the same settings page. Hosted models use Add instead, and there is nothing on your Mac to remove.

### Picking a model

Start with `llama3.2`, the model EnviousWispr suggests. If polish feels too slow, switch to a smaller model. Larger models use more memory and take longer, and they do not automatically produce better text.

### If Ollama is not running

If Ollama is not running when you dictate, the polish step is skipped. You still get your text, without the AI clean-up. Ollama has to be running by the time AI polish starts, which is a moment after your speech finishes transcribing.

### An option with nothing to install

If you want AI polish on your Mac without installing a separate application, try EG-1, the model Envious Labs built for this. It downloads from inside the EnviousWispr settings and needs no other software.
