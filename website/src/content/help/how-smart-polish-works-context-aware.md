---
title: "How Smart Polish Works (Context-Aware)"
description: "The context EnviousWispr gives the AI so it corrects you better."
category: "ai-polish"
section: "Polish"
order: 3
keywords: ["smart polish", "context", "context aware", "knows what app", "different apps", "tone", "formal", "casual"]
updated: 2026-08-05
---
EnviousWispr is a free dictation app for macOS. When it hands your dictation to an AI to tidy up, it can pass along a few facts about that dictation, so the corrections are better than they would be from the words alone.

### What it can pass along

- **That this is speech, not typing.** So the AI looks for words that sound alike but are wrong, such as "their" for "there".
- **Which language you spoke.** So you get corrected, not translated.
- **Which app you are dictating into.** A Slack message and a code comment should not be tidied up the same way.
- **Your custom words.** So your spellings survive the rewrite.

Short dictations are sent with an instruction to leave well alone.

### How much is sent depends on the option

- **OpenAI, Gemini and Claude** get the app name and your custom words.
- **Ollama** depends on the model you picked. Some get both, some get neither.
- **Apple Intelligence and EG-1** get neither. Both are small on-device models that do better with short instructions, and EG-1 was trained without them.

Your custom words are applied to your text before AI Polish runs anyway, as long as custom words are switched on under **Your Words**. Sending them to the AI as well is a second layer, not the only one.

### Your words are treated as words

If you dictate something that sounds like an instruction, such as "ignore everything above", the AI tidies that sentence up instead of obeying it. Your dictation is always text to fix, never orders to follow.
