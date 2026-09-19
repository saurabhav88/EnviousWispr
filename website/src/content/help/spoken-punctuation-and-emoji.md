---
title: "Spoken Punctuation and Emoji"
description: "How to dictate slash commands, punctuation marks and emoji, and which settings control them."
category: "features"
section: "Text Processing"
order: 3
keywords: ["punctuation", "say comma", "period", "full stop", "slash", "backslash", "new line", "new paragraph", "emoji", "thumbs up", "smiley", "spoken commands"]
related: ["numbers-dates-and-times"]
seeAlso: "speak-emoji-dictation"
updated: 2026-09-18
---
Two transcription settings let you speak a phrase and get a symbol or a line break instead of the words you said. Both live under **Settings** \> **Transcription**.

### Spoken emoji

EnviousWispr converts certain spoken phrases into emoji. This setting is on by default.

**Speak the trigger phrase.** Say the name of the emoji followed immediately by the word "emoji". Saying "thumbs up emoji" inserts 👍 into your text.

Ordinary sentences are left alone, because the conversion only fires when you say the word "emoji" directly after the name. You can also talk about emoji without triggering one, so "the heart emoji category" stays as words.

The setting is **Convert spoken emoji**.

### Spoken slash

Slash works with the Convert spoken punctuation setting off. Say "slash clear" and you get `/clear`. Say "command is slash wfp" and you get `command is /wfp`, with the space kept before the command. Say "pros slash cons" and you get `pros/cons`. Say "slash the budget" and the words stay words. Some verb uses, like "slash prices", can still become a symbol; the app cannot always tell the verb from a command name.

### Spoken punctuation

EnviousWispr can convert spoken words like "comma" into punctuation marks, and "backslash" into a backslash. This setting is off by default.

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

Backslash joins the words on both sides, so "C colon backslash Users" becomes "C:\Users". The slash does not need this setting; see the section above.

**Understand the trade-off before turning it on.** EnviousWispr already punctuates for you, so spoken punctuation competes with that. It also cannot tell when you meant the word itself: saying "the grace period expires" puts a full stop in the middle of your sentence.

Turn this on if you need exact control over your punctuation and do not mind fixing the occasional unintended symbol. The setting is **Convert spoken punctuation**.
