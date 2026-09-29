---
title: "Spoken Punctuation and Emoji"
description: "How to dictate slash commands, punctuation marks and emoji, and which settings control them."
category: "features"
section: "Text Processing"
order: 3
keywords: ["punctuation", "say comma", "period", "full stop", "slash", "backslash", "new line", "new paragraph", "emoji", "thumbs up", "smiley", "spoken commands", "emoji not working", "comma written as a word", "period in the middle of my sentence"]
related: ["numbers-dates-and-times"]
seeAlso: "speak-emoji-dictation"
updated: 2026-09-29
deflection: "can_resolve"
---
You can speak a phrase and get a symbol, an emoji or a line break instead of the words you said. Emoji and slash work by default. Spoken punctuation is off until you turn it on. The settings are under **Settings** > **Transcription**.

### Dictate an emoji

Say the name of the emoji followed directly by the word "emoji". Saying "thumbs up emoji" inserts 👍.

The setting is **Convert spoken emoji**. It is on by default. If emoji stop appearing, check it is still on.

Ordinary sentences are left alone, because the conversion only fires when you say "emoji" right after the name. You can talk about emoji without triggering one, so "the heart emoji category" stays as words.

### Dictate a slash command

Slash works without any setting. Say "slash clear" and you get `/clear`. Say "command is slash wfp" and you get `command is /wfp`, with the space kept before the command. Say "pros slash cons" and you get `pros/cons`.

Say "slash the budget" and the words stay words. Some verb uses, like "slash prices", can still become a symbol, because the app cannot always tell the verb from a command name.

### Dictate a comma, full stop or new line

Turn on **Convert spoken punctuation** in **Settings** > **Transcription**. It is off by default. With it on, spoken words become marks:

| Say this | You get |
|---|---|
| comma | , |
| period | . |
| full stop | . |
| question mark | ? |
| exclamation mark | ! |
| exclamation point | ! |
| colon | : |
| semicolon | ; |
| backslash | \ |
| new line | a line break |
| new paragraph | a blank line |

Backslash joins the words on both sides, so "C colon backslash Users" becomes "C:\Users".

### A punctuation word appears in the wrong place

With **Convert spoken punctuation** on, EnviousWispr cannot tell when you meant the word itself. Saying "the grace period expires" puts a full stop in the middle of your sentence.

EnviousWispr already punctuates for you, so spoken punctuation competes with that. Turn it on if you need exact control over your punctuation and do not mind fixing the occasional unintended symbol. If it gets in your way, switch **Convert spoken punctuation** off.

### Type a backslash

Saying "backslash" types `\` only when **Convert spoken punctuation** is on. If you use [Snippets](/help/using-snippets/), a saved snippet wins when its words follow your snippet keyword, which is `backslash` unless you changed it.
