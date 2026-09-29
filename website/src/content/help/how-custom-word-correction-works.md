---
title: "How Custom Word Correction Works"
description: "Why a custom word may still come out wrong, and how EnviousWispr recognises the wrong versions of a word you added."
category: "custom-words"
section: "Dictionary"
order: 2
keywords: ["how correction works", "why didnt my word work", "fuzzy match", "sounds like", "replacement rules", "custom word still wrong", "word not being caught", "sound-alike", "my word keeps coming out wrong"]
related: ["adding-custom-words", "using-snippets"]
updated: 2026-09-29
deflection: "can_resolve"
---
When you add a custom word, you give EnviousWispr one correct spelling. It then recognises the many ways that word can come out wrong and corrects them for you.

### My custom word still comes out wrong

The fix is to add the wrong version as a mishearing of your word. Then EnviousWispr knows to change it.

1. **Find what it heard.** Say the word as you normally would, then open **History** to see exactly what EnviousWispr wrote. That is the wrong version to add.
2. **Add it as a mishearing.** Go to **Settings** > **Dictionary** > **Your Words**, click **Edit** next to your word, type the wrong version in the mishearing box, and click **Add**. Then click **Save**.
3. **Check your spelling.** Make sure the spelling you saved is exactly what you want to see in your text.

Very short words are harder to match. Matching them broadly enough to catch every slip would also change common words you did not mean to touch. For a short word, adding the exact wrong version is the most reliable fix.

If nothing is corrected at all, check that **Enable Dictionary** is on at the top of **Settings** > **Dictionary**.

### What kinds of mistake does it catch?

Mistakes on an unfamiliar word fall into three groups, and custom word correction handles all three.

- **Split apart.** A single word that arrived in pieces is put back together. Both "Chat G P T" and "Chat GPT" become "ChatGPT".
- **Sounds right, spelled wrong.** A word the engine heard correctly but wrote as it sounds is corrected to your spelling. "Cue Bernetes" becomes "Kubernetes".
- **Close but not exact.** Small spelling slips from the speech engine are fixed. "Kubernettes" becomes "Kubernetes".

### When does correction happen?

Custom word correction runs early. Only [snippet expansion](/help/using-snippets/) comes before it. Your words are already right by the time filler word removal and AI Polish see the text.
