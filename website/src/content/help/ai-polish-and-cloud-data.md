---
title: "AI Polish and Cloud Data"
description: "Which AI Polish options keep your text on your Mac, and what is sent when one does not."
category: "privacy-and-security"
section: "Privacy"
order: 3
keywords: ["cloud", "does it send my text anywhere", "sent to openai", "sent to google", "leaves my mac", "third party", "who sees my text", "confidential", "work data", "hipaa"]
related: ["privacy-overview", "choosing-an-ai-provider-none-apple-intelligence-ollama-openai-gemini"]
seeAlso: "cloud-ai-polish-not-stored"
updated: 2026-08-05
---
EnviousWispr is a free dictation app for macOS. Whether any of your text leaves your Mac depends entirely on which AI Polish option you picked. Go to **Settings** \> **AI Polish** to see which one is yours.

### Nothing leaves your Mac

- **None.** No AI step at all.
- **Apple Intelligence.** Apple's model, running on your Mac.
- **EG-1.** The model EnviousWispr built, running on your Mac.
- **Ollama, when you pick a model you downloaded.** Ollama also offers hosted models that run on its own servers, and those do send your transcribed text. EnviousWispr shows them under their own heading so you can tell which kind you are choosing.

### Your text is sent

OpenAI, Gemini, Claude and Ollama's hosted models all run on their own servers. Your account is with that company, on their terms. Envious Labs is not in the middle of it: everything goes straight from your Mac to them, so it is never seen here either.

#### What is sent

- The text to polish.
- The instructions for cleaning it up, plus your custom words.
- The name of the app you are dictating into.
- Your API key, so the provider can confirm the request is yours. Ollama's hosted models use your Ollama sign-in instead of a key.

#### What is never sent

- Your audio. Ever, on any option.
- Your other transcripts, or your History.

EnviousWispr adds nothing to the request that identifies you or your Mac. The provider still sees the ordinary details of any internet connection, such as your IP address.

With OpenAI and Gemini, EnviousWispr also asks them not to keep a copy of that request. That is a request to them, not something EnviousWispr can enforce, and your text still has to reach them to be polished.

### If polish fails

You get the tidied-up version of your dictation from immediately before the AI step. A network problem, a slow provider, or a reply that arrives cut short costs you the polish, never your words.
