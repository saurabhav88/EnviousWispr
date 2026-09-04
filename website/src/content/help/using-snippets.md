---
title: "Using Snippets"
description: "Say a short keyword and a trigger, and EnviousWispr pastes the text you saved."
category: "features"
section: "Text Processing"
order: 7
keywords: ["snippets", "text expansion", "voice shortcut", "paste my email", "keyword", "backslash", "signature", "expand phrase", "saved text"]
related: ["adding-custom-words", "ai-polish-and-cloud-data"]
updated: 2026-09-01
---
A snippet is a voice shortcut. You save a piece of text once, then say a short phrase to paste it. An email address, a sign-off, a link you send people every week.

Snippets live in **Settings** \> **Snippets**.

### What you start with

EnviousWispr ships with six example snippets so you can try the feature before you write anything. They belong to a made-up person called John Doe, and each one is marked **Example** in the list until you change it.

| Say | You get |
| --- | --- |
| `backslash my email` | john.doe@example.com |
| `backslash my phone` | (555) 010-4477 |
| `backslash my address` | 1600 Example Way, Suite 200, Springfield, IL 62704 |
| `backslash my calendar` | https://cal.example.com/john-doe |
| `backslash my signature` | Thanks so much. John Doe, Product at Example Co. |
| `backslash my intro` | Hi, I'm John Doe. I lead product at Example Co, and I'm happy to help however I can. |

These are ordinary snippets. Open one, replace John Doe's details with yours, and click **Save**. The **Example** mark disappears once the text is yours.

Delete the ones you do not want. They stay deleted, and EnviousWispr will not add them back on the next launch.

### How a snippet fires

A snippet only expands when you say your **keyword** first, then the trigger. The keyword is `backslash` unless you change it.

Say this:

> Feel free to email me at **backslash my email** any time.

You get this:

> Feel free to email me at john.doe@example.com any time.

The keyword is what keeps snippets out of your way. Say the same trigger without it and nothing happens:

> Can you send me **my email** from that form?

That sentence comes out exactly as you said it.

The same is true if you say the keyword and nothing after it matches a snippet you saved. No snippet fires, and your words carry on through EnviousWispr normally. (Normally still includes AI Polish, so a sentence can be tidied up the way any other sentence would be. Snippets simply had nothing to do with it.)

### Add a snippet

1. Open **Settings** \> **Snippets**.
2. Click **Add snippet**.
3. Type the words you will say in **Snippet**, and the text you want pasted in **Expands to**. Your keyword sits to the left of the **Snippet** box, so you can read the whole phrase you will say.
4. Click **Save**.

### Change your keyword

The keyword field is at the top of the Snippets screen. Pick a word you would not say by accident. `backslash` is the default because most people rarely say it out loud.

Clearing the field puts the default back rather than switching snippets off.

### What EnviousWispr will not do to your snippet

The text you save is pasted exactly as you typed it. AI Polish never rewrites it, so an email address, a web link or a signature arrives character for character. Everything else you dictate is still polished as normal.

Line breaks are kept, so a two-line sign-off arrives as two lines.

### One thing worth knowing

**A dictation containing a snippet skips the cursor tidy-up.** Normally, when you dictate into the middle of a sentence you already typed, EnviousWispr fixes the spacing and capital letters where the two halves meet. On a dictation that expanded a snippet, it leaves the text alone instead, so nothing can alter your saved text.

### Rules the screen enforces

- A snippet needs both a trigger and some text. An empty snippet would delete the words you said.
- Two snippets cannot share the same spoken words. If they did, there would be no way to say which one you meant.
- Matching ignores capital letters and trailing punctuation, so "My Email Address." and "my email address" are the same trigger.

### Keep a copy

**Export** writes your snippets and your keyword to a file you choose. Useful when you move to a new Mac. EnviousWispr will refuse to save over its own snippets file, because that would erase the snippets you were trying to back up.

Import is coming soon.
