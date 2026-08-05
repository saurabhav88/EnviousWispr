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
Whether anything leaves your Mac depends entirely on which AI Polish option you picked. Open Settings and go to **AI Polish** to see yours.

### Nothing leaves your Mac

- **None.** No AI step at all.
- **Apple Intelligence.** Apple's model, running on your Mac.
- **EG-1.** Our own model, running on your Mac.
- **Ollama.** A model you chose, running on your Mac.

### Your text is sent

OpenAI, Gemini and Claude run on their own servers. You bring your own key, and your account is with them, on their terms. We are not in the middle of it: everything goes straight from your Mac to them, so we never see it either.

#### What is sent

- The text to polish.
- The instructions for cleaning it up, plus your custom words.
- The name of the app you are dictating into.
- Your API key, so the provider can authenticate the request.

#### What is never sent

- Your audio. Ever, on any option.
- Your other transcripts, or your History.

EnviousWispr does not add anything identifying you or your Mac to the request. The provider still sees the ordinary details of any internet connection, such as your IP address.

With OpenAI and Gemini, EnviousWispr also asks them not to keep a copy of that request. That is a request to them, not something we can enforce, and your text still has to reach them to be polished.

### If polish fails

You get the tidied-up version of your dictation from just before the AI step. A network problem, a slow provider, or a reply that arrives cut short costs you the polish, never your words.
