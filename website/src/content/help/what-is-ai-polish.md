---
title: "What Is AI Polish?"
description: "What AI Polish changes about your dictation, and what it is designed not to do."
category: "ai-polish"
section: "Polish"
order: 1
keywords: ["polish", "ai polish", "cleanup", "clean up my text", "grammar", "punctuation", "tidy", "what does ai do", "editing", "email", "dictate an email", "email formatting", "paragraphs", "paragraph breaks", "bullet list", "make a list"]
related: ["choosing-an-ai-provider-none-apple-intelligence-ollama-openai-gemini", "s1-mini-by-superwhisper-and-writing-style"]
updated: 2026-09-06
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

### Your polish options

Every option is listed under **Settings** \> **AI Polish**, in three groups.

- **On this Mac.** EG-1, our own model tuned for dictation, and the recommended choice. Apple Intelligence, built into macOS 26. S1-mini by Superwhisper, a small open model that is a 484 MB download. Nothing you dictate leaves your Mac with any of these.
- **Your own setup.** Ollama, running an open model you choose, on your Mac or hosted.
- **Cloud.** OpenAI, Google Gemini or Claude, with your own API key. These receive your transcribed text, never your audio.

### How EG-1 lays out what you dictate

From version 2.4.7, EG-1 gives your dictation a shape rather than returning one long paragraph.

- **A new topic starts a new paragraph.** When you move from one subject to the next, EG-1 puts a break there.
- **A list you announce comes out as a list.** Say that you have three points and then give them, and you get three lines rather than one run-on sentence.
- **An email gets a greeting on its own line.** Dictate a message start to finish and the opening line sits above the body. A sign-off usually lands on its own line too, though less reliably than the greeting, so check that one before you send.

EG-1 still adds nothing you did not say, and it does not write a subject line for you.

### The default, and how to change it

Apple Intelligence is the option you begin with, and it requires macOS 26 or later. On a Mac that cannot run macOS 26, the AI step is quietly skipped and you receive that same pre-polish version of your text. EG-1 and S1-mini do not need macOS 26, so either gives you on-device polish on an older Mac.

EnviousWispr uses a single polish style, tuned for dictation. The one exception is S1-mini, which has three writing style settings, Tone, Structure and Context. Read [_S1-mini by Superwhisper and Its Writing Style Settings_](/help/s1-mini-by-superwhisper-and-writing-style/). To change your polish option or switch polish off entirely, open **Settings** and select **AI Polish**.
