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
Almost always, Ollama is not running.

### Work through these

1. **Is Ollama installed?** Get it from [ollama.com](https://ollama.com).
2. **Is it running?** Open the Ollama app, or run `ollama serve` in Terminal. It has to be running before you start recording.
3. **Do you have a model?** Run `ollama list` in Terminal. If it is empty, run `ollama pull llama3.2`.
4. **Is the right model selected?** Open Settings, go to **AI Polish**, and check the model picker.

### If it is slow rather than broken

A big model on a busy Mac can take longer than EnviousWispr waits, which is about fifteen seconds for a local model. Try a smaller one.

### What happens meanwhile

You still get your dictation. It just arrives without the AI clean-up.
