---
title: "Hallucination Protection"
description: "The checks that catch AI output which does not match what you said."
category: "ai-polish"
section: "Polish"
order: 7
keywords: ["hallucination", "made up words", "invented text", "wrong words added", "ai changed my meaning", "extra text", "it added things i didnt say"]
related: ["why-is-my-dictation-inaccurate"]
updated: 2026-08-05
---
AI models sometimes make things up. EnviousWispr checks the result before it reaches you and rejects the clear failures.

### What it checks

- **Text that grew far beyond what you said.** Something was added.
- **Text that lost most of what you said.** It was cut, not tidied.
- **An answer instead of an edit.** Ask a question out loud and you get your question back, not a reply to it.
- **Chatter.** Openers like "Certainly!" are stripped rather than pasted.
- **Very short dictations.** These skip AI Polish entirely and keep the earlier clean-up result.

Apple Intelligence also checks longer non-English results for a switch of language.

### What you get when a check rejects the result

The tidied-up version of your dictation from just before the AI step. You never lose what you said because polish went wrong.

These checks catch the obvious failures, not every bad edit. Read anything important before you send it.
