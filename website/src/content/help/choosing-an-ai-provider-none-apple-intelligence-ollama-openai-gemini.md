---
title: "Choosing an AI Provider"
description: "The AI Polish options, what each one costs, and which ones keep your text on your Mac."
category: "ai-polish"
section: "Polish"
order: 2
keywords: ["turn off ai", "turn ai off", "disable ai", "no ai", "none", "provider", "openai", "chatgpt", "gemini", "claude", "apple intelligence", "ollama", "s1-mini", "superwhisper", "eg-1", "which ai", "api key", "change provider", "stop rewriting my words"]
related: ["ai-polish-and-cloud-data", "api-key-security", "s1-mini-by-superwhisper-and-writing-style"]
updated: 2026-09-29
deflection: "can_resolve"
---
AI Polish tidies up your dictation after transcription, and you choose which provider does the work. Your audio stays on your Mac on every option. Open **Settings** > **AI Polish** to choose.

### Which AI Polish option should I pick?

- **macOS 26 or later, on a Mac that supports Apple Intelligence:** leave it on Apple Intelligence. It is the default and it is free. Apple Intelligence must be switched on in System Settings, and its model must have finished downloading.
- **macOS 14 or 15, or a Mac that does not support Apple Intelligence:** choose EG-1. Apple Intelligence polish needs macOS 26, so on an older macOS the AI step is skipped and you get the cleaned-up text without AI polish.
- **A Mac with little free space:** choose S1-mini if EG-1 is too big for your Mac.

### How do I turn AI Polish off?

Turn off **Enable AI Polish** at the top of **Settings** > **AI Polish**. There is no separate "None" option. With the switch off, no AI step runs. You still get filler-word removal and your custom words.

### Which options keep my text on my Mac?

- **Apple Intelligence.** Free. It must be switched on in System Settings, with its model downloaded. It needs macOS 26 or later on a Mac that supports Apple Intelligence. It is the default when you install the app.
- **EG-1.** The model Envious Labs built for dictation, marked **Recommended** on the AI Polish page. It is free. Download it from the AI Polish page. It takes about 2.9 GB of storage.
- **S1-mini.** A small model made by Superwhisper, and the lightest on-device option. It is free. Download it from the AI Polish page. It takes about 484 MB and has three writing style settings. See [_S1-mini by Superwhisper and Its Writing Style Settings_](/help/s1-mini-by-superwhisper-and-writing-style/).

### How do I use Ollama?

Ollama is a free app that runs AI models on your Mac. You install it yourself, then pick a model in EnviousWispr under **Your own setup**. Models you download to your Mac are free and keep your text on the machine. Ollama also offers hosted models that run on its own servers. EnviousWispr lists them separately and never picks one for you. A hosted model needs you signed in to Ollama, and some need a paid Ollama plan.

### Which options send my text to a company?

OpenAI, Gemini, and Claude need an account and an API key from that company. An API key is a private password that lets EnviousWispr use your account. You pay the company directly for what you use. Your transcribed text goes to them, never your audio.

With OpenAI and Gemini, EnviousWispr also asks them not to keep a copy of your request. For the full list of what is sent, read [_AI Polish and Cloud Data_](/help/ai-polish-and-cloud-data/).

### How do the AI Polish options compare?

| Option | Where your text goes | Cost | Needs |
|---|---|---|---|
| Apple Intelligence | Stays on your Mac | Free | macOS 26 or later |
| EG-1 | Stays on your Mac | Free | A 2.9 GB download |
| S1-mini | Stays on your Mac | Free | A 484 MB download |
| Ollama | Your Mac, or Ollama's servers if you pick a hosted model | Free on your Mac; a hosted model may need a paid Ollama plan | Ollama installed and running |
| OpenAI | To OpenAI | You pay OpenAI | An API key |
| Gemini | To Google | You pay Google | An API key |
| Claude | To Anthropic | You pay Anthropic | An API key |
