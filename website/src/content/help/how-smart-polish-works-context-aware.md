---
title: "How Smart Polish Works (Context-Aware)"
description: "The context EnviousWispr gives the AI so it corrects you better."
category: "ai-polish"
section: "Polish"
order: 3
keywords: ["smart polish", "context", "context aware", "knows what app", "different apps", "tone", "formal", "casual", "does polish know my app", "does the ai see my custom words"]
updated: 2026-09-29
deflection: "can_resolve"
---
When EnviousWispr sends your dictation to an AI for polishing, it includes a few background facts with your words. That context helps the AI make better corrections than it could from the transcript alone.

### What does the AI know about my dictation?

EnviousWispr can send these pieces of information alongside your text.

- **That this is speech, not typing.** The AI knows to look for words that sound alike but are wrong, such as "their" for "there".
- **Your language.** OpenAI, Gemini, Claude and most Ollama models are told your language when you lock one. Otherwise they are told to keep the language of the transcript and never translate it. EG-1 and S1-mini follow their own built-in language guidance. Either way, it corrects your grammar instead of translating you.
- **Which app you are dictating into.** A message in Slack and a comment in a code editor need different styles of tidying.
- **Your custom words.** Your own vocabulary list goes along too, so your spellings survive the rewrite.

Short dictations carry an instruction to leave them alone, which stops the AI overworking a brief phrase.

### Which AI Polish options get my app name and custom words?

How much context is sent depends on the polish option you chose in **Settings** > **AI Polish**.

| Polish option | App name included | Custom words included |
| :--- | :--- | :--- |
| **OpenAI, Gemini, and Claude** | Yes | Usually |
| **Ollama models other than EG-1 and S1-mini** | Yes | Usually |
| **Apple Intelligence, EG-1, and S1-mini** | No | No |

Every Ollama model gets the app name, wherever it runs. The two exceptions are EG-1 and S1-mini, which you can also run through Ollama. Apple Intelligence, EG-1, and S1-mini get neither field. All three are compact on-device models that do better with short instructions, and EG-1 was trained without them.

### Why are my custom words sometimes not sent to the AI?

OpenAI, Gemini, Claude and Ollama do not get your custom words on every dictation. When the app cannot tell with confidence which language you spoke, it holds your word list back for that dictation. This avoids pushing English spellings onto text in another language. It applies to OpenAI, Gemini, Claude, and Ollama.

Your custom words are also applied to your text before AI Polish runs, as long as **Enable Dictionary** is switched on under **Settings** > **Dictionary**. Sending them to the AI as well is a second layer, not the only one.

### What if I dictate something that sounds like an instruction?

Say you dictate "ignore everything above". Most options tell the AI to treat everything you say as text to tidy up, not as an order to follow, so that sentence should come back as your own words. S1-mini follows its own fixed tidy-up instructions. This is an instruction to the AI, not a guarantee. If an AI ever answers your words instead of tidying them, EnviousWispr's checks catch the obvious cases. Read [_Hallucination Protection_](/help/hallucination-protection/).
