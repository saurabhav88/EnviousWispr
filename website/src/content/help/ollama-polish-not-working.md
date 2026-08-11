---
title: "Ollama Polish Not Working"
description: "Fixing AI Polish when you are using Ollama."
category: "troubleshooting"
section: "AI Polish Issues"
order: 5
keywords: ["ollama not working", "ollama error", "cant connect to ollama", "ollama failed", "local ai broken"]
related: ["using-ollama-for-fully-offline-ai-polish"]
updated: 2026-08-11
---
When Ollama polish fails to tidy up your dictation, the cause is nearly always that Ollama itself is not running.

### Confirm Ollama is installed

Ollama must be installed on your Mac before EnviousWispr can send any text to it. Download the app from [ollama.com](https://ollama.com) if you have not installed it yet.

### Start the application

Ollama needs to be running before you start recording. Open your Applications folder and launch the Ollama app, or run `ollama serve` in Terminal.

### Verify your model

EnviousWispr relies on a model you have downloaded to process your text. Run `ollama list` in Terminal to see which models are on your machine. If the list is empty, run `ollama pull qwen2.5:3b` to download a working one.

### Match your settings

The model selected in EnviousWispr has to match one that is installed on your system. Open EnviousWispr settings, go to **AI Polish**, and check the model picker.

### Sign in for hosted models

Ollama offers both models you download to your Mac and models it hosts on its own servers. Hosted models still route through the Ollama app, so everything above still applies, and you also have to be signed in to your Ollama account. Run `ollama signin` in Terminal. EnviousWispr tells you after the first failed dictation if you are not signed in.

### Check subscription status

Some hosted models need a paid account with Ollama. If the model you selected requires a subscription you do not have, Ollama rejects the request. Choose a free model in your settings, or subscribe through Ollama.

### Address slow processing times

A large model running on a busy Mac can take longer than the fifteen seconds EnviousWispr waits. If your dictations time out often, open EnviousWispr settings, go to **AI Polish**, and pick a model labelled Recommended. There are three: `qwen2.5:3b`, `qwen3:0.6b` and `qwen2.5:7b`. For a timeout specifically, `qwen3:0.6b` is the smallest by a wide margin and still scored well in our tests, so try that one first.

Do not choose by size alone. Several of the smallest models EnviousWispr offers produced no acceptable result in our tests, so a smaller download can mean much worse cleanup without reliably solving a timeout. No Recommended model can promise to finish inside fifteen seconds on every Mac or for every dictation, and a long dictation on a busy machine may still run out of time.

### You still get your dictation

The polish step is the only part that failed. Your text still arrives, carrying the clean-up EnviousWispr does on your Mac, such as filler-word removal and your custom words. Only the AI rewrite is missing.
