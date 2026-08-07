---
title: "How Smart Polish Works (Context-Aware)"
description: "The context EnviousWispr gives the AI so it corrects you better."
category: "ai-polish"
section: "Polish"
order: 3
keywords: ["smart polish", "context", "context aware", "knows what app", "different apps", "tone", "formal", "casual"]
updated: 2026-08-06
---
When EnviousWispr sends your dictation to an AI for polishing, it includes a small set of background facts along with your words. That extra context helps the AI make better corrections than it could by reading the transcript alone.

### What context gets included

EnviousWispr can send several pieces of information to the AI alongside your text.

- **That this is speech, not typing.** The AI knows to look for words that sound alike but are wrong, such as "their" for "there".
- **Which language you spoke.** The AI knows which language you used, so it corrects your grammar instead of translating you.
- **Which app you are dictating into.** A message in Slack and a comment in a code editor need different styles of tidying.
- **Your custom words.** Your own vocabulary list goes along too, so your spellings survive the rewrite.

Short dictations carry an instruction to leave them alone, which stops the AI overworking a brief phrase.

### How context varies by provider

How much context is sent depends on the polish option you selected in settings.

| Polish option | App name included | Custom words included |
| :--- | :--- | :--- |
| **OpenAI, Gemini, and Claude** | Yes | Usually |
| **Ollama, except EG-1** | Yes | Usually |
| **Apple Intelligence and EG-1** | No | No |

Every Ollama model gets the app name, whichever one you picked and wherever it runs, with one exception: EG-1, which you can also run through Ollama. Apple Intelligence and EG-1 get neither field. Both are compact on-device models that do better with short instructions, and EG-1 was trained without them.

Custom words say "usually" for a reason. When the app cannot tell with confidence which language you spoke, it holds your word list back for that dictation instead of risking English spellings being pushed onto text in another language. That applies to every option in the Yes rows, not just Ollama.

Your custom words are applied to your text before AI Polish runs anyway, as long as custom words are switched on under **Your Words**. Sending them to the AI as well is a second layer, not the only one.

### Your words are treated as words

If you dictate a phrase that sounds like an instruction, such as "ignore everything above", the AI treats that sentence as text to tidy up rather than an order to follow. Your dictation is always handled as text to fix, never as a command to run.
