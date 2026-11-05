---
title: "AI Polish and Cloud Data"
description: "Which AI Polish options keep your text on your Mac, and what is sent when one does not."
category: "privacy-and-security"
section: "Privacy"
order: 3
keywords: ["cloud", "does it send my text anywhere", "sent to openai", "sent to google", "leaves my mac", "third party", "who sees my text", "confidential", "work data", "hipaa", "turn off ai polish", "keep my text private", "meeting summary", "enviousmeet summary", "what does a meeting summary send"]
related: ["privacy-overview", "choosing-an-ai-provider-none-apple-intelligence-ollama-openai-gemini"]
seeAlso: "cloud-ai-polish-not-stored"
updated: 2026-11-05
deflection: "show_but_always_send"
---
Whether your text leaves your Mac for polishing depends on which AI Polish option you picked. Your audio never leaves your Mac on any option. To check your choice, open **Settings** > **AI Polish**.

### Which AI Polish options keep my text on my Mac?

These options keep your transcription and the polish request on your device.

- **Apple Intelligence.** Apple's model, running on your Mac.
- **EG-1.** The model built by Envious Labs, running on your Mac.
- **S1-mini.** The small model made by Superwhisper, running on your Mac.
- **Ollama, with a model you downloaded.** Ollama is a free app that runs AI models. Ollama also offers hosted models that run on its own servers, and those do send your text. EnviousWispr lists hosted models under a separate heading so you can tell which kind you are choosing.

### Which AI Polish options send my text, and to whom?

OpenAI, Gemini, Claude, and Ollama's hosted models run on the provider's servers. Your account is with that company, on its terms. Your text goes straight from your Mac to the provider. Envious Labs is not in the middle, so Envious Labs never sees your text.

### What does the provider receive?

- The text that needs polishing.
- The instructions for cleaning it up, plus your custom words.
- The name of the app you are dictating into.
- Your API key, a private password from the provider that shows the request is yours. Ollama's hosted models use your Ollama sign-in instead.

For dictation, EnviousWispr adds nothing to the request that identifies you or your Mac. The provider still sees the ordinary details of any internet connection, such as your IP address.

With OpenAI and Gemini, EnviousWispr also asks them not to keep a copy of the request. That is a request to the provider, not something EnviousWispr can enforce. Your text still has to reach their servers to be polished.

### What is never sent to the provider?

- Your audio. That holds on every option.
- Your other dictations and transcripts, or your History.

### How do I stop my text from being sent?

Pick an option that stays on your Mac: Apple Intelligence, EG-1, S1-mini, or an Ollama model you downloaded. To run no AI step at all, turn off **Enable AI Polish** at the top of **Settings** > **AI Polish**. Filler-word removal and your custom words still apply.

### What about EnviousMeet summaries?

Meeting summaries have their own choice, under **Summary engine** on the **Summaries** tab of the EnviousMeet page. It is separate from AI Polish, and turning off **Enable AI Polish** does not turn off meeting summaries.

EG-1, Apple Intelligence and an Ollama model you downloaded keep the summary on your Mac. A cloud summary engine (OpenAI, Gemini, Claude, or an Ollama hosted model) receives, straight from your Mac: the meeting transcript, your notes, and meeting details such as the start time, recorded length and call app, plus, when available, the calendar event's title and the invited people's names and email details. Envious Labs never receives any of it. To keep summaries on your Mac, choose an on-Mac summary engine. See [EnviousMeet: Record a Meeting](/help/enviousmeet-record-a-meeting/).

### What do I get if AI Polish fails?

You still receive the tidied-up version of your dictation from immediately before the AI step. A network problem, a slow provider, or a reply that arrives cut short costs you the polish, never your words.
