---
title: "How Match Strictness Works in Your Dictionary"
description: "What Loose, Default and Strict do in the EnviousWispr dictionary, with real examples, so you can fix a word that gets missed or swapped by mistake."
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
    answer: "It sets how close a word in your text must look to a dictionary word before EnviousWispr swaps it in. Loose swaps more, Default is the balanced choice, and Strict swaps only when the two words are nearly identical."
  - question: "Which Match strictness setting should I use?"
    answer: "Keep Default for most words. Choose Loose when a word keeps coming out slightly wrong and nothing swaps it. Choose Strict when a word keeps replacing a different word you meant, such as one name replacing a similar name."
  - question: "Why does Loose still not fix my word?"
    answer: "Loose has a limit. If the word in your text is too different from the dictionary word, nothing swaps it, even on Loose. Add the wrong version as a mishearing of your word. That fix does not depend on how close the words look."
  - question: "Does Match strictness change every word in my dictionary?"
    answer: "No. It is set one word at a time. A word you never changed stays on Default."
---

Most people never touch **Match strictness**. Then one day a name keeps coming out wrong, or the wrong name keeps getting swapped in, and this small setting is the reason.

EnviousWispr is a free dictation app for Mac. It has a dictionary, called **Your Words**, where you add the names and terms you use. This post explains what that setting does, with real examples, so you know which one to pick.

## The short version

When you dictate, EnviousWispr checks each word in your text against your dictionary. If a word looks almost like one of yours, it swaps in your spelling. Match strictness controls how "almost" has to be.

- **Loose:** swaps even when the two words look fairly different. You catch more slips. You also get more swaps you did not want.
- **Default:** a balanced choice for most words.
- **Strict:** swaps only when the two words are nearly identical. You get fewer surprise swaps. You also miss more slips.

You set it for one word at a time, so a name that needs special care does not change how everything else behaves.

## What "looks close" means

EnviousWispr gives each pair of words a closeness score from 0% to 100%. 100% means the same word.

The score is mostly about spelling. About 40% of it counts how many letters you would have to change to turn one word into the other. Another 40% counts how many letter pairs the two words share. The last 20% is a simple sound code, which gives a bonus when two words are spelled differently but are said alike.

So the app does not listen again. It compares the text your dictation produced with the word in your dictionary.

## The bar each setting uses

Each setting is a closeness score the pair of words has to reach.

| Setting | Closeness needed |
|---|---|
| Loose | 72% |
| Default | About 82% for words of five letters or more, 90% for words of four letters or fewer, and 85% for a phrase of several words |
| Strict | 92% |

Default adjusts itself a little. It is slightly easier for very long words and slightly pickier when your dictionary is large. Loose and Strict do not adjust. They always use the same bar.

Short words are the reason Default asks for 90%. A short word has few letters, so one wrong letter changes a lot. If Default were looser there, it would swap everyday short words you did not mean to change.

## Real examples

We ran each pair below through the same matching EnviousWispr uses. The dictionary in each test held only the one word shown. The "looks alike" number is the closeness score.

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

Here is what each row shows.

**A name that keeps coming out slightly wrong (Loose helps).** "Envious" written as "enviose" scores 75%. Default needs about 82%, so it leaves the word alone. Loose needs 72%, so it fixes it.

**Two people with similar names (Strict helps).** Say you added your colleague Sara to the dictionary. Then you dictate a sentence about Sarah, a different person. The two names score 86%. On Default, "Sarah" becomes "Sara" and you may not notice. On Strict, it stays "Sarah". The same happens with Alan and Allan, and with Alison and Allison. If two similar names both matter to you, put the one you add on Strict.

**Short names (Loose is a big step).** Erik and Eric score 77%. Short words need 90% on Default, so neither Erik nor Mark swaps unless the text matches almost perfectly. Loose lowers that bar to 72%, which is a large jump for a short word. Use it only for a short word that you are sure nothing else is competing with.

**Strict is very strict.** Allison and Alison differ by one letter and still score 91%, narrowly under Strict's 92%. If you choose Strict for a word, expect it to swap only when the text is nearly perfect already.

**Loose has a limit.** "sourab" for "Saurabh" scores 70%. That is below even Loose, so nothing swaps it. If a word keeps coming out the same wrong way, the setting will not fix it.

## When the setting does not fix it

The most reliable fix for one repeated mistake is to add the wrong version as a **mishearing** of your word. A mishearing you add yourself does not depend on how close the words look. EnviousWispr swaps it whenever it sees exactly that spelling.

Here is how to find the wrong version and add it.

1. **Find what it wrote.** Say the word as you normally would, then open **History** to see exactly what EnviousWispr produced. That is the wrong version.
2. **Add it as a mishearing.** Go to **Settings** > **Dictionary** > **Your Words**, click **Edit** next to your word, type the wrong version in the mishearing box, and click **Add**. Then click **Save**.

The [custom word correction help page](/help/how-custom-word-correction-works/) covers this fix in more detail.

## Two things that surprise people

**Loose cannot force a swap when two words compete.** If your dictionary holds two words that both look close to what you said, EnviousWispr needs the better one to win by a clear margin, about 5 points. If neither wins clearly, it leaves the word alone. This holds on every setting, including Loose. It protects you from the app guessing between two of your own words.

**Loose and Strict replace the automatic adjustments.** A word on Default gets the small adjustments for long words and large dictionaries. A word on Loose or Strict skips them and always uses 72% or 92%.

## Which one should you pick

Start with Default and change a word only when it gives you trouble.

- **A word keeps coming out slightly wrong, and nothing swaps it:** try Loose. If it still does not swap, add the wrong version as a mishearing.
- **A word keeps replacing a different word you meant:** use Strict.
- **Everything else:** leave it on Default.

## How to change it

1. Open **Settings** > **Dictionary** > **Your Words**.
2. Click **Edit** next to the word.
3. Under **Recognition behavior**, choose **Loose**, **Default** or **Strict** for **Match strictness**.
4. Click **Save**.

The setting applies to that one word. To learn how to add words in the first place, see [adding custom words](/help/adding-custom-words/).
