---
title: "Using Ollama for Fully Offline AI Polish"
description: "Set up Ollama, a free app that runs AI models on your Mac, so AI Polish works without an internet connection."
category: "ai-polish"
section: "Polish"
order: 6
keywords: ["ollama", "offline ai", "local ai", "local model", "llama", "run ai locally", "no internet ai", "free local", "set up ollama", "which ollama model", "ollama hosted models", "polish without internet"]
related: ["ollama-polish-not-working"]
updated: 2026-09-29
deflection: "can_resolve"
---
Ollama is a separate free app that runs AI models on your Mac. EnviousWispr can hand your dictation to one of those models to tidy it up. With a model you downloaded, you need no API key and no account after setup, and your text stays on your Mac.

If Ollama is not working for you, see [Ollama Polish Not Working](/help/ollama-polish-not-working/).

### Set up Ollama for AI Polish

You need an internet connection to install Ollama and download a model. After that, polish works offline.

No local model handled languages other than English well in our tests. If you dictate in another language, this is not the polish option to try first.

1. **Install Ollama.** Download the app from [ollama.com](https://ollama.com) and install it.
2. **Open Ollama.** Launch the app so it runs in the background.
3. **Choose Ollama in EnviousWispr.** Open **Settings** > **AI Polish** and choose **Ollama** as your provider.
4. **Download a model.** In the model list, click **Download** next to a model. If you prefer Terminal, run `ollama pull qwen2.5:3b` instead.
5. **Select your model.** Pick your downloaded model from the list.

EnviousWispr finds your installed models on its own, so they appear in the list without any configuration. You can download and remove local models from the same settings page.

### Which Ollama model should I pick?

Start with `qwen2.5:3b`, the model EnviousWispr suggests. It scored best of the local models we offer when we tested how well each one cleans up dictation.

Two others carry the **Recommended** label:

- `qwen3:0.6b` earned the label from a download about a quarter the size of the suggested model.
- `qwen2.5:7b` is the most careful of the three, but also the slowest and largest.

The label beside each model comes from those tests, not from the model's size. Several of the smallest models produced no acceptable result at all in our tests, so download size does not tell you quality. If polish feels slow, pick a **Recommended** model rather than the smallest one you can find.

### Do Ollama's hosted models keep my text on my Mac?

No. Ollama offers two kinds of models. Models you download run on your Mac. Hosted models run on Ollama's own servers, so they send your transcribed text over the internet.

EnviousWispr lists hosted models under their own heading, **Runs on Ollama's servers**, and never selects one for you. To keep your text on your Mac, choose a model that is not in that group. A hosted model has an **Add** button instead of **Download**, and there is nothing on your Mac to remove.

### What happens if Ollama is not running?

The AI Polish step is skipped and you still get your text, without the AI clean-up. Ollama has to be running by the time polish starts, which is a moment after your speech finishes transcribing.

### Use AI Polish without installing another app

If you want AI Polish on your Mac without a separate app, try EG-1, the model Envious Labs built for this, or S1-mini by Superwhisper, the lightest option. Both download from inside EnviousWispr settings and need no other software. See [S1-mini by Superwhisper and Its Writing Style Settings](/help/s1-mini-by-superwhisper-and-writing-style/).
