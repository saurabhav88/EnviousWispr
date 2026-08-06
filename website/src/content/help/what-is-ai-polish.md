---
title: "What Is AI Polish?"
description: "What AI Polish changes about your dictation, and what it is designed not to do."
category: "ai-polish"
section: "Polish"
order: 1
keywords: ["polish", "ai polish", "cleanup", "clean up my text", "grammar", "punctuation", "tidy", "what does ai do", "editing"]
related: ["choosing-an-ai-provider-none-apple-intelligence-ollama-openai-gemini"]
updated: 2026-08-06
---
AI Polish is the optional step EnviousWispr runs after transcribing your speech, to tidy up what you said. It fixes grammar and punctuation, cuts filler words, and is instructed to keep your exact meaning and your language.

### What the AI is designed not to do

The polish step has strict limits, which exist to protect what you actually said.

- **Add ideas.** The model is not allowed to introduce new thoughts or expand on your points.
- **Answer questions.** If you dictate a question, the model tidies the wording rather than replying to it.
- **Translate text.** If you dictate in French, you get French back.
- **Touch very short dictations.** These skip the AI step entirely, though your other clean-up settings still apply.

AI can still make mistakes. EnviousWispr checks the result and rejects the obvious failures (read [_Hallucination Protection_](/help/hallucination-protection/) for details), but read anything important before you send it.

### How the fallback prevents lost words

If polish is unavailable, runs too slowly, or returns something unusable, EnviousWispr pastes the version of your dictation from immediately before the AI step. That version is not raw: your custom words, filler-word removal, and number and date formatting have already been applied to it. You never lose your dictation. How long the app waits before giving up depends on which polish option you chose.

### The default, and how to change it

Apple Intelligence is the option you begin with, and it requires macOS 26 or later. On a Mac that cannot run macOS 26, the AI step is quietly skipped and you receive that same pre-polish version of your text.

EnviousWispr uses a single polish style, tuned for dictation. To change your polish option or switch polish off entirely, open **Settings** and select **AI Polish**.
