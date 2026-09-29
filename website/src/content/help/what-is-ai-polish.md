---
title: "What Is AI Polish?"
description: "What AI Polish changes about your dictation, and what it is designed not to do."
category: "ai-polish"
section: "Polish"
order: 1
keywords: ["polish", "ai polish", "cleanup", "clean up my text", "grammar", "punctuation", "tidy", "what does ai do", "editing", "email", "dictate an email", "email formatting", "paragraphs", "paragraph breaks", "bullet list", "make a list", "polish not working", "turn off polish"]
related: ["choosing-an-ai-provider-none-apple-intelligence-ollama-openai-gemini", "s1-mini-by-superwhisper-and-writing-style"]
updated: 2026-09-29
deflection: "can_resolve"
---
AI Polish is the optional step EnviousWispr runs after transcribing your speech. It fixes grammar and punctuation, cuts filler words, and is told to keep your meaning and your language.

### How do I change or turn off AI Polish?

Open **Settings** > **AI Polish**. Pick an option from the list, or turn off **Enable AI Polish** at the top to run no AI step. Apple Intelligence is the option you start with.

### Why is AI Polish not changing my text?

Apple Intelligence polish needs macOS 26 or later. On a Mac running macOS 14 or 15, the AI step is quietly skipped and you get the cleaned-up text from immediately before it. EG-1 and S1-mini do not need macOS 26. Choose either one in **Settings** > **AI Polish** to get on-device polish on an older Mac. Very short dictations also skip the AI step, and your other clean-up settings still apply.

### What is AI Polish told not to do?

The polish step has limits that protect what you said.

- **Add ideas.** The model is not allowed to add new thoughts or expand on your points.
- **Answer questions.** If you dictate a question, the model tidies the wording instead of replying.
- **Translate text.** It is told to keep your language. If you dictate in French, you should get French back.

AI can still make mistakes. EnviousWispr checks the result and rejects the obvious failures. Read [_Hallucination Protection_](/help/hallucination-protection/) for details, and read anything important before you send it.

### What do I get if AI Polish fails?

If polish is unavailable, runs too slowly, or returns something unusable, EnviousWispr pastes the version of your dictation from immediately before the AI step. That version is not raw. Your custom words, filler-word removal, and number and date formatting have already been applied. You do not lose your dictation. How long the app waits before giving up depends on the polish option you chose.

### Which AI Polish options are there?

Every option is listed under **Settings** > **AI Polish**, in three groups.

- **On this Mac.** EG-1, our own model tuned for dictation, which is marked **Recommended**. Apple Intelligence, built into macOS 26. S1-mini by Superwhisper, a small model that is a 484 MB download. These options polish your dictation text on your Mac.
- **Your own setup.** Ollama, a free app that runs AI models you choose, on your Mac or hosted on Ollama's servers.
- **Cloud.** OpenAI, Google Gemini, or Claude, with your own API key. These receive your transcribed text, never your audio.

To compare them, read [_Choosing an AI Provider_](/help/choosing-an-ai-provider-none-apple-intelligence-ollama-openai-gemini/).

### Does AI Polish have style settings?

EnviousWispr uses a single polish style, tuned for dictation. The one exception is S1-mini, which has three writing style settings: Tone, Structure and Context. Read [_S1-mini by Superwhisper and Its Writing Style Settings_](/help/s1-mini-by-superwhisper-and-writing-style/).

### Will EG-1 add paragraphs and lists?

From version 2.4.7, EG-1 gives your dictation a shape instead of returning one long paragraph. It gets this right most of the time, not every time, so read anything long before you send it.

- **A new topic starts a new paragraph.** When you move to a different subject, EG-1 usually puts a break there.
- **A list you announce comes out as a list.** Say that you have three points and then give them, and you usually get three lines instead of one run-on sentence. This is the one it misses most often.
- **An email gets a greeting on its own line.** Dictate a message start to finish and the opening line almost always sits above the body. A sign-off usually lands on its own line too, though less reliably.

This is layout, not content. EG-1 is not allowed to add anything you did not say, and it is not asked to write you a subject line.
