---
title: "How Match Strictness Works in Your Dictionary"
description: "See what Loose, Default, and Strict do in EnviousWispr's dictionary, with real examples to help you fix words that get missed or swapped by mistake."
topic: tips-troubleshooting
pubDate: 2026-11-17
tags: ["custom words", "dictionary", "macos", "accuracy", "dictation"]
draft: false
keywords:
  - "custom dictionary dictation mac"
  - "dictation wrong name fix"
  - "dictation keeps misspelling names"
  - "match strictness"
  - "custom words dictation"
faqs:
  - question: "What does Match strictness do in the EnviousWispr dictionary?"
    answer: "It decides how close a word in your text needs to look to one of your dictionary words before EnviousWispr swaps it in. Loose catches more, Strict holds back unless the two are nearly identical, and Default sits in the middle."
  - question: "Which Match strictness setting should I use?"
    answer: "Leave most words on Default. Switch to Loose if a word keeps coming out slightly wrong and isn't getting fixed. Switch to Strict when a saved word keeps replacing a similar name or word you meant instead."
  - question: "Why does Loose still not fix my word?"
    answer: "Loose still has a limit. If what EnviousWispr wrote looks too different from your word, even Loose won't swap it. Add that wrong spelling as a mishearing of your word instead, since mishearings don't depend on how close the two words look."
  - question: "Does Match strictness change every word in my dictionary?"
    answer: "No, it applies one word at a time. Anything you haven't changed stays on Default."
---

Most people never touch **Match strictness**, right up until a name keeps coming out wrong or the wrong name keeps getting swapped into their text. Sometimes this small setting is why.

EnviousWispr is a free Mac dictation app. It includes a dictionary called **Your Words** where you save the names and terms you use. Below is how Match strictness works, with real examples so you can tell which option you need.

## The short version

As you dictate, EnviousWispr checks each word against **Your Words**. When a word looks close to one you saved, it swaps your spelling in. Match strictness controls how close is close enough.

- **Loose** steps in even when two words look fairly different. It catches more slips, though it's also more likely to change a word you meant to keep.
- **Default** sits in the middle and works well for most words.
- **Strict** holds back unless the two spellings are almost identical. You won't get many surprise swaps, though you'll miss more near-misses.

Because you pick this for one word at a time, tightening up a tricky name won't change how the rest of your dictionary behaves.

## What "looks close" means

Behind the scenes, EnviousWispr gives every pair of words a closeness score from 0% to 100%, where 100% is an exact match.

Most of that score comes from spelling. About 40% counts how many letters you'd have to change to turn one word into the other, and another 40% counts how many letter pairs the two words share. The last 20% is a simple sound code that gives a bonus when two words are spelled differently but sound alike.

So the app isn't going back to listen to your audio again. It's comparing the text your dictation produced against the word saved in your dictionary.

## Where each setting draws the line

Each option sets the minimum score two words need to reach before a swap happens.

| Setting | Closeness needed |
|---|---|
| Loose | 72% |
| Default | About 82% for words of five letters or more, 90% for words of four letters or fewer, and 85% for a phrase of several words |
| Strict | 92% |

Default moves around a little on its own: it's slightly easier on very long words and a bit pickier if you have a large dictionary. Loose and Strict stay put and use the exact same number every time.

Why does Default ask for 90% on short words? Because when a word only has a few letters, one wrong letter changes a lot. If Default were any looser there, it'd start swapping everyday short words you didn't mean to touch.

## Real examples

We ran these word pairs through the exact matching EnviousWispr uses, with only the one saved word in the dictionary for each test. "Looks alike" is the closeness score.

| Your dictionary word | What your text said | Looks alike | Loose | Default | Strict |
|---|---|---|---|---|---|
| Envious | enviose | 75% | Swaps | Leaves it | Leaves it |
| Envious | envius | 83% | Swaps | Swaps | Leaves it |
| Saurabh | saurab | 91% | Swaps | Swaps | Leaves it |
| Saurabh | sourab | 70% | Leaves it | Leaves it | Leaves it |
| Sara | Sarah | 86% | Swaps | Swaps | Leaves it |
| Alan | Allan | 86% | Swaps | Swaps | Leaves it |
| Alison | Allison | 91% | Swaps | Swaps | Leaves it |
| Erik | Eric | 77% | Swaps | Leaves it | Leaves it |
| Mark | Marc | 77% | Swaps | Leaves it | Leaves it |
| Kubernetes | kubernetis | 87% | Swaps | Swaps | Leaves it |

A few things stand out from that table:

- **When a name keeps coming out slightly off, Loose helps.** "enviose" for "Envious" scores 75%. Default wants around 82%, so it leaves "enviose" alone, while Loose (72%) steps in and fixes it.
- **When two people have similar names, Strict protects the other one.** Say you saved your colleague Sara in your dictionary, then dictate a sentence about a different person named Sarah. Those two score 86%. On Default, "Sarah" silently turns into "Sara", and you might not notice. Put Sara on Strict and "Sarah" stays untouched. Same story with Alan and Allan, or Alison and Allison. If both names come up for you, set the one you added to Strict.
- **Be careful with Loose on short names.** Erik and Eric score 77% (same as Mark and Marc). Because short words need 90% on Default, neither swaps unless the spelling is already almost spot-on. Dropping to 72% is a big leap for a short word, so save Loose for short words that don't have lookalikes you care about.
- **Strict really means strict.** Alison and Allison are only one letter apart and still score 91%, a little under Strict's 92%. If you put a word on Strict, it'll only swap when the dictation is nearly right already.
- **Loose won't fix everything.** "sourab" for "Saurabh" scores 70%, which falls under Loose's 72% cutoff. If dictation keeps getting a word wrong the exact same way, changing Match strictness won't reach it.

## When none of the settings fix it

If EnviousWispr keeps producing the same wrong spelling, the most reliable fix is to save that wrong version as a **mishearing** of your word. A mishearing doesn't depend on a closeness score. Whenever that exact spelling shows up, EnviousWispr swaps it out.

1. **Check what it wrote.** Say the word like you normally do, then open **History** to see the exact spelling EnviousWispr produced.
2. **Add it as a mishearing.** Go to **Settings** > **Dictionary** > **Your Words**, click **Edit** next to your word, type that wrong spelling into the mishearing box, click **Add**, and then click **Save**.

You can read more about this on the [custom word correction help page](/help/how-custom-word-correction-works/).

## Two things that surprise people

**Loose won't force a guess between two close words.** If two words in your dictionary both look close to what came out, one of them has to beat the other by a clear margin, about 5 points. When it's too close to call, EnviousWispr leaves the text alone rather than guessing between two of your own words. That rule applies on every setting, Loose included.

**Loose and Strict turn off the automatic adjustments.** Words on Default get those small nudges for very long words or large dictionaries. Put a word on Loose or Strict and it skips those adjustments completely, sticking to 72% or 92%.

## Which one should you pick?

Leave everything on Default until a specific word gives you trouble.

- **It keeps coming out slightly wrong:** switch that word to Loose. If it still misses, add the wrong spelling as a mishearing.
- **It keeps replacing a different word you meant:** switch it to Strict.
- **Everything else:** leave it on Default.

## How to change it

1. Open **Settings** > **Dictionary** > **Your Words**.
2. Click **Edit** next to the word you want to adjust.
3. Under **Recognition behavior**, choose **Loose**, **Default**, or **Strict** for **Match strictness**.
4. Click **Save**.

That change only applies to the word you edited. If you haven't added words yet, see [adding custom words](/help/adding-custom-words/).
