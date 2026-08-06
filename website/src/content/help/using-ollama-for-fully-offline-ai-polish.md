---
title: "Using Ollama for Fully Offline AI Polish"
description: "Running AI Polish through a local model with Ollama."
category: "ai-polish"
section: "Polish"
order: 6
keywords: ["ollama", "offline ai", "local ai", "local model", "llama", "run ai locally", "no internet ai", "free local"]
related: ["ollama-polish-not-working"]
updated: 2026-08-05
---
EnviousWispr is a free dictation app for macOS. Ollama is a separate free app that runs language models on your own Mac, and EnviousWispr can hand your dictation to one of them for tidying up. Once it is set up there is no key, no account, and none of your dictation goes to the internet.

This page is about those on-Mac models. Ollama also offers hosted models that run on its own servers, and those do send your transcribed text off your Mac. EnviousWispr lists them under their own heading in the model list and never selects one for you, so if you want everything to stay local, pick a model that is not in that group.

### Setting it up

1. Install Ollama from [ollama.com](https://ollama.com).
2. Open it, so the Ollama app is running.
3. Download a model. In Terminal that is `ollama pull llama3.2`, or you can do it from the Ollama app.
4. In EnviousWispr, go to **Settings** \> **AI Polish**.
5. Choose **Ollama**, then pick your model from the list.

Installing Ollama and downloading a model need an internet connection. Polishing after that does not.

EnviousWispr finds your installed models on its own, so they appear in that list without you telling it where they are. You can also download and remove models from the same page.

### Picking a model

Start with llama3.2, the one EnviousWispr suggests. If polish feels slow, try a smaller model. Larger models use more memory and take longer, and they do not automatically write better.

### If Ollama is not running

Polish is skipped and you get your text anyway, without the AI clean-up. Ollama has to be running by the time AI Polish starts, which is a moment after your speech is transcribed.

### A simpler local option

If you want AI Polish on your Mac with nothing separate to install, try EG-1, the model EnviousWispr built. It downloads from inside Settings and needs no other app.
