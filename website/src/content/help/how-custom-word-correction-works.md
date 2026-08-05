---
title: "How Custom Word Correction Works"
description: "How EnviousWispr recognises the wrong versions of a word you added."
category: "custom-words"
section: "Custom Words"
order: 2
keywords: ["how correction works", "why didnt my word work", "fuzzy match", "sounds like", "replacement rules"]
related: ["adding-custom-words"]
updated: 2026-08-05
---
You add the spelling you want. EnviousWispr then recognises the many ways it can come out wrong, and fixes them.

### Three kinds of mistake it catches

- **Split apart.** "Chat G P T" and "Chat GPT" both become "ChatGPT".
- **Sounds right, spelled wrong.** "Cue Bernetes" becomes "Kubernetes".
- **Close but not exact.** "Kubernettes" becomes "Kubernetes".

### It happens first

Your words are corrected before anything else touches the text, so they are already right by the time filler removal and AI Polish see it.

### If a word is not being caught

- Check the spelling you saved is exactly what you want to see.
- Say it as you normally would, then look in **History** to see what the app actually heard. That tells you what to add.
- Very short words are harder to match safely, because doing so would change words you did not mean.
