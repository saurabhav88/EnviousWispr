---
title: "Ollama Polish Not Working"
description: "Fix AI Polish when it fails or gets skipped while you are using Ollama."
category: "troubleshooting"
section: "AI Polish Issues"
order: 5
keywords: ["ollama not working", "ollama error", "cant connect to ollama", "ollama failed", "local ai broken", "ollama isn't signed in", "ollama signin", "ollama timeout", "ollama not running", "polish skipped ollama"]
related: ["using-ollama-for-fully-offline-ai-polish"]
updated: 2026-09-29
deflection: "show_but_always_send"
---
When Ollama polish fails to tidy up your dictation, the cause is nearly always that the Ollama app is not running. Work through this checklist in order. Your dictation still arrives while you fix it.

### Fix Ollama polish that fails or gets skipped

1. **Install Ollama.** EnviousWispr cannot send any text to Ollama until the app is installed. Download it from [ollama.com](https://ollama.com) if you have not installed it yet.
2. **Start Ollama before you record.** Open your Applications folder and launch the Ollama app. Or open Terminal, the app where you type commands, and run `ollama serve`.
3. **Check that you have a model.** In Terminal, run `ollama list`. It shows the models on your Mac. If the list is empty, run `ollama pull qwen2.5:3b` to download a working one.
4. **Match the model in EnviousWispr.** Open **Settings** > **AI Polish** and check the model list. The model you select there has to be one that is installed on your Mac.

If you use a hosted model, one that runs on Ollama's own servers, keep Ollama running and check the four points in this list, because hosted models still go through the Ollama app. Hosted models also need you to sign in with `ollama signin`, and some need a paid Ollama plan.

### Fix "Ollama isn't signed in"

Hosted models need you to be signed in to your Ollama account. In Terminal, run `ollama signin`, then dictate again. EnviousWispr tells you after the first failed dictation if you are not signed in.

### Fix a hosted model that Ollama rejects

Some hosted models need a paid Ollama plan. If the model you selected needs a plan you do not have, Ollama rejects the request. In **Settings** > **AI Polish**, choose a free model, or subscribe through Ollama.

### Fix polish that times out on a slow Mac

EnviousWispr waits fifteen seconds for the AI step. A large model on a busy Mac can take longer.

1. Open **Settings** > **AI Polish**.
2. Pick a model labelled **Recommended**. There are three: `qwen2.5:3b`, `qwen3:0.6b` and `qwen2.5:7b`.
3. For a timeout specifically, try `qwen3:0.6b` first. It is the smallest by a wide margin and still scored well in our tests.

Do not choose by size alone. Several of the smallest models EnviousWispr offers produced no acceptable result in our tests, so a smaller download can mean much worse cleanup without reliably fixing a timeout. No **Recommended** model can promise to finish inside fifteen seconds on every Mac or for every dictation. A long dictation on a busy Mac may still run out of time.

### Do I lose my dictation when Ollama polish fails?

No. Only the AI rewrite is missing. Your text still arrives with the clean-up EnviousWispr does on your Mac, such as filler-word removal and your custom words.

For the full setup, see [Using Ollama for Fully Offline AI Polish](/help/using-ollama-for-fully-offline-ai-polish/).
