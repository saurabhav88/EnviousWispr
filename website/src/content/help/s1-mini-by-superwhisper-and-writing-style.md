---
title: "S1-mini by Superwhisper and Its Writing Style Settings"
description: "S1-mini is the lightest on-device AI Polish option, and its Tone, Structure and Context settings change how your dictation is written."
category: "ai-polish"
section: "Polish"
order: 4
keywords: ["s1-mini", "s1 mini", "superwhisper", "writing style", "tone", "casual", "formal", "lists", "prose", "email", "context", "lightweight", "small model", "8 gb mac", "on-device polish", "bullet points", "too formal", "too casual", "polish skipped on long dictation"]
related: ["choosing-an-ai-provider-none-apple-intelligence-ollama-openai-gemini", "model-downloads-and-management", "using-ollama-for-fully-offline-ai-polish"]
updated: 2026-09-29
deflection: "can_resolve"
---
S1-mini is a small AI model, made by Superwhisper, that tidies up dictated text. It is the lightest of the two on-device AI Polish options, next to EG-1. It runs entirely on your Mac, it is free, and there is no API key to manage. To use it, open **Settings** > **AI Polish** and pick **S1-mini**.

### Should I pick S1-mini or EG-1?

EG-1 stays the recommended choice. Pick S1-mini if you dictate in English and want the lightest on-device option, or if EG-1 is more than your Mac has room for.

- **Small download.** S1-mini is a 484 MB download, about a sixth the size of EG-1. It starts faster and uses far less memory. It needs around 1 GB of free disk space while it installs.
- **English first.** It cleans up other languages without translating them, but it may miss a mid-sentence correction you make in those languages.

### Why was my long dictation not polished?

S1-mini works best on short and medium dictations. When a dictation is longer than S1-mini can polish, the app skips polish for that dictation and gives you the cleaned-up transcription instead. The S1-mini card under **Settings** > **AI Polish** shows how long a dictation it can polish. If you often dictate for longer, EG-1 handles longer dictations.

### Make the text more casual or more formal

Set **Tone** on the **Writing style** card. To find the card, open **Settings** > **AI Polish** and pick **S1-mini**. A change applies to your next dictation.

- **Casual** and **Semi-casual** write the way you would text.
- **Semi-formal** keeps capitals and full stops. This is the default.
- **Formal** keeps capitals and full stops and is the most formal of the four.

### Turn a spoken list into bullet points, or stop it

Set **Structure** on the **Writing style** card.

- **Lists** turns "apples, oranges, bananas" into bullet points when you speak a run of items. Ordinary sentences are left alone. This is the default.
- **Prose** keeps everything as sentences.

### Get a greeting and sign-off laid out for an email

Set **Context** on the **Writing style** card.

- **General** is the default and changes nothing about layout.
- **Email** lays out a greeting line and a sign-off block when you dictate them. It does not invent a greeting or a signature that you did not say, so a plain sentence comes out the same under either setting.

Every writing style setting starts on its default. If you never open the card, S1-mini behaves the way it did before the card existed.

### Use S1-mini through Ollama

If you pulled S1-mini into Ollama yourself and selected it there, EnviousWispr recognises it and sends it the same instructions it sends the built-in copy. The **Writing style** card appears on the Ollama page for that model too. For Ollama setup, see [Using Ollama for Fully Offline AI Polish](/help/using-ollama-for-fully-offline-ai-polish/).

### Where does the S1-mini name and licence appear?

Superwhisper's licence asks that the model is identified as S1-mini wherever it appears, and EnviousWispr does that. The licence and notice files ship inside the app under **Open Source Licenses**.
