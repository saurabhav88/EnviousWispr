---
title: "S1-mini by Superwhisper and Its Writing Style Settings"
description: "The lightest on-device polish option, where it comes from, and what the Tone, Structure and Context pickers do."
category: "ai-polish"
section: "Polish"
order: 4
keywords: ["s1-mini", "s1 mini", "superwhisper", "writing style", "tone", "casual", "formal", "lists", "prose", "email", "context", "lightweight", "small model", "8 gb mac", "on-device polish"]
related: ["choosing-an-ai-provider-none-apple-intelligence-ollama-openai-gemini", "model-downloads-and-management", "using-ollama-for-fully-offline-ai-polish"]
updated: 2026-09-04
---
S1-mini is a small open model made by Superwhisper for one job: tidying up dictated text. EnviousWispr offers it as a second on-device polish option beside EG-1. It runs entirely on your Mac, it is free, and there is no API key to manage. Open **Settings**, then **AI Polish**, and pick **S1-mini** to use it.

### What you get

- **A 484 MB download.** About a sixth the size of EG-1, so it starts faster and uses far less memory. It needs around 1 GB of free disk space while it installs.
- **English first.** It cleans up other languages without translating them, but it will not always catch a correction you make mid-sentence in those languages.
- **Short and medium dictations.** It is best for dictations up to about 4 minutes. Past that, the app skips polish for that dictation and gives you the cleaned-up transcription instead.

EG-1 stays the recommended choice. Pick S1-mini if you dictate in English and want the lightest on-device option, or if EG-1 is more than your Mac has room for.

### The writing style settings

S1-mini was trained with three settings that you choose. They appear on the **Writing style** card on the S1-mini page. A change applies to your next dictation.

**Tone** sets the register.

- **Casual** and **Semi-casual** write the way you would text: sentence starts stay lowercase and there is no final full stop.
- **Semi-formal** keeps capitals and full stops. This is the default.
- **Formal** keeps capitals and full stops and reads a little more buttoned up.

**Structure** decides what happens to a spoken run of items.

- **Lists** turns "apples, oranges, bananas" into bullet points when you speak an enumeration, and leaves ordinary sentences alone. This is the default.
- **Prose** keeps everything as sentences.

**Context** tells the model where the text is going.

- **General** is the default and changes nothing about layout.
- **Email** lays out a greeting line and a sign-off block when you dictate them. It does not invent a greeting or a signature that you did not say, so a plain sentence comes out the same under either setting.

Every setting starts on its default, so if you never open the card, S1-mini behaves exactly as it did before the card existed.

### If you run S1-mini through Ollama

If you pulled S1-mini into Ollama yourself and selected it there, EnviousWispr recognises it and sends it the same instructions it sends the built-in copy. The Writing style card appears on the Ollama page for that model too.

### About the name

The model is called S1-mini and it is made by Superwhisper. Its licence asks that it be identified that way wherever it appears, and EnviousWispr does. The licence and notice files ship inside the app under **Open Source Licenses**.
