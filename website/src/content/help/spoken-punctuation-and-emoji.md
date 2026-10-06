---
title: "Spoken Punctuation and Emoji"
description: "How to dictate slash commands, punctuation marks and emoji, including punctuation in German, French, Spanish and Italian, and which settings control them."
category: "features"
section: "Text Processing"
order: 3
keywords: ["punctuation", "say comma", "period", "full stop", "slash", "backslash", "new line", "new paragraph", "emoji", "thumbs up", "smiley", "spoken commands", "emoji not working", "comma written as a word", "period in the middle of my sentence", "start word", "German punctuation", "Satzzeichen diktieren", "Diktiere Punkt", "neuer Absatz", "French punctuation", "Place point", "Spanish punctuation", "Añade punto", "Italian punctuation", "Metti punto", "Punkt written as a word", "spoken punctuation other languages"]
related: ["numbers-dates-and-times"]
seeAlso: "speak-emoji-dictation"
updated: 2026-10-04
deflection: "can_resolve"
---
You can speak a phrase and get a symbol, an emoji or a line break instead of the words you said. Emoji and slash work by default. Spoken punctuation is off until you turn it on. The settings are under **Dictation Settings** > **Engine**.

### Dictate an emoji

Say the name of the emoji followed directly by the word "emoji". Saying "thumbs up emoji" inserts 👍.

The setting is **Convert spoken emoji**. It is on by default. If emoji stop appearing, check it is still on.

Ordinary sentences are left alone, because the conversion only fires when you say "emoji" right after the name. You can talk about emoji without triggering one, so "the heart emoji category" stays as words.

### Dictate a slash command

Slash works without any setting. Say "slash clear" and you get `/clear`. Say "command is slash wfp" and you get `command is /wfp`, with the space kept before the command. Say "pros slash cons" and you get `pros/cons`.

Say "slash the budget" and the words stay words. Some verb uses, like "slash prices", can still become a symbol, because the app cannot always tell the verb from a command name.

### Dictate a comma, full stop or new line

Turn on **Spoken punctuation** in **Dictation Settings** > **Engine**. It is off by default. In English, with it on, you say the word on its own and it becomes a mark:

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

### Dictate punctuation in German, French, Spanish and Italian

In these four languages the command words are also everyday words. "Punkt" is a noun as well as a full stop. So you say a start word first, and then the command. "Diktiere Punkt" gives a full stop. "Punkt" on its own stays the word.

The default start words are:

- German: **Diktiere**
- French: **Place**
- Spanish: **Añade**
- Italian: **Metti**

Spoken punctuation must be on. It works when your dictation language is German, French, Spanish or Italian, whether you chose the language or EnviousWispr detected it. English works as it does today: say the word on its own. You can also give English a start word, see Choose your own start word below.

In French, a mark is written straight after the word before it, with no space. In Spanish, EnviousWispr writes only the closing question mark or exclamation mark, not the opening one.

Say the start word, then the command, in the language you dictate in. These tables list every command.

#### German

| Say this | You get |
|---|---|
| Diktiere Punkt | . |
| Diktiere Komma | , |
| Diktiere Fragezeichen | ? |
| Diktiere Ausrufezeichen | ! |
| Diktiere Doppelpunkt | : |
| Diktiere Semikolon | ; |
| Diktiere Strichpunkt | ; |
| Diktiere neue Zeile | a line break |
| Diktiere neuer Absatz | a blank line |
| Diktiere neuen Absatz | a blank line |
| Diktiere Neuabsatz | a blank line |

#### French

| Say this | You get |
|---|---|
| Place point | . |
| Place virgule | , |
| Place point d'interrogation | ? |
| Place point d'exclamation | ! |
| Place deux points | : |
| Place point-virgule | ; |
| Place nouvelle ligne | a line break |
| Place à la ligne | a line break |
| Place nouveau paragraphe | a blank line |

#### Spanish

| Say this | You get |
|---|---|
| Añade punto | . |
| Añade coma | , |
| Añade signo de interrogación | ? |
| Añade signo de exclamación | ! |
| Añade dos puntos | : |
| Añade punto y coma | ; |
| Añade nueva línea | a line break |
| Añade nuevo párrafo | a blank line |

#### Italian

| Say this | You get |
|---|---|
| Metti punto | . |
| Metti virgola | , |
| Metti punto interrogativo | ? |
| Metti punto esclamativo | ! |
| Metti due punti | : |
| Metti punto e virgola | ; |
| Metti nuova riga | a line break |
| Metti nuovo paragrafo | a blank line |

### Choose your own start word

Turn on **Spoken punctuation**. A **Start word** row appears under it.

1. Pick a language in **Start word for**.
2. Type your word and press Return.
3. Press **Reset** to bring back the default word for that language.

Picking a language here only chooses which start word you edit. It does not change your dictation language.

If your speech engine often writes a different word for your start word, pick another word. A word the engine hears clearly works best.

English has no start word by default, so its commands work on their own. To use a start word in English, pick **English** in **Start word for** and type a word, for example "Insert". Then "insert period" gives a full stop, and "the grace period expires" stays words. A start word works with comma, period, full stop, question mark, exclamation mark, exclamation point, colon, semicolon, new line and new paragraph. Backslash is not one of them and is off while English has a start word. The spoken slash is not affected. Clear the field to go back to no start word.

To use no start word, clear the field and press Return. The field then shows **No start word**. Every command word of that language now becomes a mark wherever you say it, as English does. In German, "der springende Punkt" then becomes "der springende." and "drei Komma fünf" becomes "drei, fünf". Press **Reset** to bring back the default start word.

Pick a word you would not say in a normal sentence. A start word is one word of 2 to 20 letters. It cannot be a command word, or the first word of one. If your word does not fit, the field goes back to the old start word and tells you why.

When **Remove filler words** is on, sounds such as "uh", "hmm", "mm" and "ah" can be removed before the start word is read. Avoid choosing a filler sound as your start word. Removal depends on the dictation language: German keeps "um" and "er" because they are ordinary German words.

Spoken punctuation is meant for dictating with AI polish off. With AI polish on, polish can change the marks a command inserted.

If you do not see the **Start word** row, check that **Spoken punctuation** is on. If it is on and the row is still missing, update EnviousWispr to the latest version.

### A punctuation word appears in the wrong place

In English, with **Spoken punctuation** on, EnviousWispr cannot tell when you meant the word itself. Saying "the grace period expires" puts a full stop in the middle of your sentence.

In German, French, Spanish and Italian a command word stays a word unless the start word comes right before it. A start word of your own can still come up in a normal sentence, so choose one you would not say. If you chose no start word, a command word is a mark every time you say it.

EnviousWispr already punctuates for you, so spoken punctuation competes with that. Turn it on if you need exact control over your punctuation and do not mind fixing the occasional unintended symbol. If it gets in your way, switch **Spoken punctuation** off.

### Type a backslash

In English, saying "backslash" types `\` only when **Spoken punctuation** is on. If you use [Snippets](/help/using-snippets/), a saved snippet wins when its words follow your snippet keyword, which is `backslash` unless you changed it. A saved snippet wins over a start word command in the same way.
