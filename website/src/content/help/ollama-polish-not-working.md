---
title: "Ollama Polish Not Working"
description: "Fixing AI Polish when you are using Ollama."
category: "troubleshooting"
section: "AI Polish Issues"
order: 5
keywords: ["ollama not working", "ollama error", "cant connect to ollama", "ollama failed", "local ai broken"]
related: ["using-ollama-for-fully-offline-ai-polish"]
updated: 2026-08-05
---
EnviousWispr is a free dictation app for macOS. Ollama is one of the AI options it can use to tidy up what you dictated. When that step fails, it is nearly always because Ollama itself is not running.

### Work through these

1. **Is Ollama installed?** Get it from [ollama.com](https://ollama.com).
2. **Is it running?** Open the Ollama app, or run `ollama serve` in Terminal. It has to be running before you start recording.
3. **Do you have a model?** Run `ollama list` in Terminal. If nothing comes back, run `ollama pull llama3.2`.
4. **Is the right model selected?** Open EnviousWispr's settings, go to **AI Polish**, and check the model picker.

### If you picked one of Ollama's hosted models

Ollama offers models that run on its own servers as well as models you download to your Mac. Hosted models still go through the Ollama app, so everything above still applies, and two more things matter:

- **You have to be signed in to Ollama.** Run `ollama signin` in Terminal. If you are not signed in, EnviousWispr says so after the first failed dictation.
- **Some hosted models are paid.** If the one you picked needs a subscription you do not have, Ollama refuses the request. Choose a free model instead, or subscribe.

### If it is slow rather than broken

A large model on a busy Mac can take longer than EnviousWispr waits, which is about fifteen seconds. Try a smaller model.

### What happens meanwhile

You still get your dictation. It arrives without the AI clean-up, which is the only part that failed.
