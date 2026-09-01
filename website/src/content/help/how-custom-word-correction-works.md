---
title: "How Custom Word Correction Works"
description: "How EnviousWispr recognises the wrong versions of a word you added."
category: "custom-words"
section: "Dictionary"
order: 2
keywords: ["how correction works", "why didnt my word work", "fuzzy match", "sounds like", "replacement rules"]
related: ["adding-custom-words"]
updated: 2026-09-01
---
When you teach EnviousWispr a custom word, you give it one correct spelling, and it then recognises the many ways that word can come out wrong during transcription and corrects them for you.

### The three kinds of mistake it catches

Transcription errors on an unfamiliar word fall into three groups, and custom word correction handles all three.

- **Split apart.** A single word that arrived in pieces is put back together. Both "Chat G P T" and "Chat GPT" become "ChatGPT".
- **Sounds right, spelled wrong.** A word the engine heard correctly but wrote phonetically is corrected to your spelling. "Cue Bernetes" becomes "Kubernetes".
- **Close but not exact.** Small spelling slips from the speech engine are fixed. "Kubernettes" becomes "Kubernetes".

### When custom word correction runs

Custom word correction runs first, before anything else touches the text. Your words are therefore already right by the time filler removal and AI Polish see them.

### If a word is not being caught

If one of your custom words keeps slipping through, work through these checks.

- **Verify your spelling.** Check that the spelling you saved is exactly what you want to see in your text.
- **Inspect your history.** Say the word as you normally would, then open **History** to see what EnviousWispr actually heard. That transcript tells you which wrong version to add.
- **Consider the word's length.** Very short words are harder to match safely, because matching them broadly enough to catch would also change common words you did not mean to touch.
