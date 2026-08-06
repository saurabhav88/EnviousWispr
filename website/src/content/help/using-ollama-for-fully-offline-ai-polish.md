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
Ollama can run a language model on your own Mac. Once it is set up, polishing needs no key, no account, and sends none of your dictation to the internet.

This page is about those on-Mac models. Ollama also offers hosted models that run on Ollama's servers, which do send your transcribed text off your Mac. EnviousWispr lists them under their own heading in the model list and never selects one for you, so if you want everything to stay local, pick a model that is not in that group.

### Setting it up

1. Install Ollama from [ollama.com](https://ollama.com).
2. Open it, so the Ollama app is running.
3. Download a model. In Terminal that is `ollama pull llama3.2`, or use the Ollama app.
4. In EnviousWispr, open Settings and go to **AI Polish**.
5. Choose **Ollama**, then pick your model.

Installing Ollama and downloading a model need an internet connection. Polishing after that does not.

EnviousWispr finds your installed models on its own. You can also download and remove models from that page.

### Picking a model

Start with llama3.2, the one EnviousWispr suggests. If polish feels slow, try a smaller model. Larger models use more memory and take longer, and they do not automatically write better.

### If Ollama is not running

Polish is skipped and you get your text anyway, without the AI clean-up. Ollama has to be running by the time AI Polish starts, which is just after your speech is transcribed.

### A simpler local option

If you want AI Polish on your Mac with nothing to install, try EG-1. It downloads from inside Settings and needs no separate app.
