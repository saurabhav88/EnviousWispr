---
title: "Hallucination Protection"
description: "The checks that catch AI output which does not match what you said."
category: "ai-polish"
section: "Polish"
order: 7
keywords: ["hallucination", "made up words", "invented text", "wrong words added", "ai changed my meaning", "extra text", "it added things i didnt say"]
related: ["why-is-my-dictation-inaccurate"]
updated: 2026-08-06
---
EnviousWispr can hand your dictation to an AI model to tidy up, and AI models sometimes invent content you never spoke. EnviousWispr checks the result before it reaches your cursor and throws out the clear failures.

### What it checks

EnviousWispr tests the polished text against a set of known failure patterns before pasting anything into your app.

- **Text that grew far beyond what you said.** The model added material that was not in your speech.
- **Text that lost most of what you said.** The model cut your words instead of tidying them.
- **An answer instead of an edit.** If you speak a question out loud, the polish step might return an answer to it rather than a tidied version of the words you spoke.
- **Chatter.** Conversational openers such as "Certainly!" are stripped from the output rather than pasted into your document.
- **Very short dictations.** These skip the AI polish step entirely and keep the earlier clean-up result.

Apple Intelligence also checks longer results in other languages, in case the model switched language partway through.

### What you get when a check rejects the result

When a check rejects the polished text, EnviousWispr gives you the tidied-up version of your dictation from immediately before the AI step. You never lose what you said because the polish went wrong.

These checks catch the obvious failures rather than every bad edit. Read anything important before you send it.
