---
title: "Hallucination Protection"
description: "The checks that catch AI Polish output which does not match what you said."
category: "ai-polish"
section: "Polish"
order: 7
keywords: ["hallucination", "made up words", "invented text", "wrong words added", "ai changed my meaning", "extra text", "it added things i didnt say", "ai answered my question", "polish removed words", "slash missing"]
related: ["why-is-my-dictation-inaccurate"]
updated: 2026-09-29
deflection: "show_but_always_send"
---
AI Polish sometimes makes mistakes, including inventing content you never spoke. EnviousWispr checks the polished text before it reaches your cursor and throws out the clear failures. If a check rejects the result, you get the tidied-up version from immediately before the AI step.

### What if AI Polish added or removed words?

The checks catch the obvious failures, not every bad edit. If the polished text looks wrong, read it before you send it, and run the dictation again if needed. To stop the AI step entirely, turn off **Enable AI Polish** in **Settings** > **AI Polish**.

### What does EnviousWispr check?

Before pasting anything, EnviousWispr tests the polished text against these known failure patterns.

- **Text that grew far beyond what you said.** The model added material that was not in your speech.
- **Text that lost most of what you said.** The model cut your words instead of tidying them.
- **An answer instead of an edit.** If you speak a question out loud, the model might return an answer instead of a tidied version of your question.
- **A missing slash.** If your dictation contained a slash or backslash joined to a word, such as /clear or a file path, and the polished text lost it, the result is rejected. A slash on its own is not checked.
- **Chatter.** Conversational openers such as "Certainly!" are stripped from the output instead of being pasted into your document.
- **Very short dictations.** These skip the AI step entirely and keep the earlier clean-up result.

Apple Intelligence also checks longer results in other languages, in case the model switched language partway through.

### What do I get when a check rejects the result?

EnviousWispr gives you the tidied-up version of your dictation from immediately before the AI step. That version has already been through the clean-up steps you have switched on, such as custom words, filler-word removal and number formatting. You do not lose what you said because the polish went wrong.
