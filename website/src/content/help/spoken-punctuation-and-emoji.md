---
title: "Spoken Punctuation and Emoji"
description: "How to dictate slash commands, punctuation marks, brackets, quotes, other symbols and emoji, including punctuation in German, French, Spanish and Italian, and which settings control them."
category: "features"
section: "Text Processing"
order: 3
keywords: ["punctuation", "say comma", "period", "full stop", "slash", "backslash", "new line", "new paragraph", "emoji", "thumbs up", "smiley", "spoken commands", "emoji not working", "comma written as a word", "period in the middle of my sentence", "start word", "German punctuation", "Satzzeichen diktieren", "Diktiere Punkt", "neuer Absatz", "French punctuation", "Place point", "Spanish punctuation", "Añade punto", "Italian punctuation", "Metti punto", "Punkt written as a word", "spoken punctuation other languages", "double period", "two commas in a row", "extra comma next to my comma", "doubled punctuation", "casual mode", "full stop at the end", "period at the end of every dictation", "remove the final period", "no period at the end", "turn off the final full stop", "parenthesis", "left parenthesis", "brackets", "quotes", "open quote", "underscore", "hyphen", "symbols", "say a symbol"]
related: ["numbers-dates-and-times"]
seeAlso: "speak-emoji-dictation"
updated: 2026-10-14
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

### Dictate brackets, quotes and other symbols

With **Spoken punctuation** on, you can also say the name of a symbol. "Tuesday left parenthesis the fourteenth right parenthesis" becomes "Tuesday (the 14th)". "report underscore final" becomes "report_final". "She said open quote I will be there close quote" becomes She said "I will be there".

Each symbol lands with the spacing you would type. Opening brackets and quotes join the next word, closing ones join the word before. A hyphen, an underscore, an apostrophe and an em dash join both words. An ampersand, a plus sign, an equals sign, a vertical bar and an en dash get a space on each side.

When you talk about a symbol with a word like "a", "an" or "the" in front, the words stay: "use an asterisk for the footnote" stays as you said it. Without such a word, the name becomes the symbol, so "hyphen separates words" starts with a hyphen. Give English a start word (see below) if you need symbol names as ordinary words.

Say "open square bracket" or "open parenthesis" rather than "open bracket": "bracket" means a round bracket in British English and a square one in American English, so EnviousWispr does not guess. For percent, dollar and at, say the number or the address: "five percent" gives "5%" and "five dollars" gives "$5".

| Say this | You get |
|---|---|
| open parenthesis | ( |
| open paren | ( |
| left parenthesis | ( |
| left paren | ( |
| close parenthesis | ) |
| close paren | ) |
| right parenthesis | ) |
| right paren | ) |
| open square bracket | [ |
| left square bracket | [ |
| close square bracket | ] |
| right square bracket | ] |
| open curly bracket | { |
| open curly brace | { |
| open brace | { |
| left curly bracket | { |
| left curly brace | { |
| left brace | { |
| close curly bracket | } |
| close curly brace | } |
| close brace | } |
| right curly bracket | } |
| right curly brace | } |
| right brace | } |
| open angle bracket | < |
| left angle bracket | < |
| close angle bracket | > |
| right angle bracket | > |
| open double quote | " |
| begin double quote | " |
| open quotes | " |
| begin quotes | " |
| open quote | " |
| begin quote | " |
| close double quote | " |
| end double quote | " |
| close quotes | " |
| end quotes | " |
| close quote | " |
| end quote | " |
| unquote | " |
| open single quote | ' |
| begin single quote | ' |
| close single quote | ' |
| end single quote | ' |
| hyphen | - |
| underscore | _ |
| apostrophe | ' |
| em dash | an em dash |
| en dash | an en dash |
| ellipsis | … |
| ampersand | & |
| plus sign | + |
| equals sign | = |
| equal sign | = |
| vertical bar | \| |
| asterisk | * |
| hash sign | # |
| number sign | # |
| tilde | ~ |

### Leave off the final full stop (Casual mode)

Your speech engine puts a full stop at the end of a sentence, so a dictation usually ends with one. In a chat message or a search box that full stop can feel too formal. Turn on **Casual mode** in **Dictation Settings** > **Engine** and the full stop at the very end of each dictation is left off. It is off by default.

Only the last full stop goes. "Sounds good, see you at three." becomes "Sounds good, see you at three". "Hi. See you soon." becomes "Hi. See you soon", so the full stop inside the text stays. These stay as they are:

- Question marks and exclamation marks, because they change what you mean.
- An ellipsis, and dotted endings such as "9 a.m.", "the U.S." and "Ph.D.".
- In languages other than English, a dot right after a number, because it can be an ordinal, like German "am 3.".
- A full stop you say out loud with **Spoken punctuation** on, like "see you period". If your speech engine already turned the word into a full stop before EnviousWispr saw it, EnviousWispr cannot tell, and the full stop may still be left off.
- The ending of a snippet, when the dictation ends with one.

A final "etc.", "Dr." or "Inc." loses its dot.

Casual mode only changes the ending. It does not change **Transcribe a File** or dictations already in your History. When you dictate twice into the same line, spacing and starting capitals depend on Smart insertion and what the target app supports. A question mark, exclamation mark or protected full stop still separates the sentences.

Casual mode works with every speech engine, with AI polish on or off. The **Casual** tone of [S1-mini](/help/s1-mini-by-superwhisper-and-writing-style/) is a different option: it is part of AI polish and changes more than the ending.

### Dictate punctuation in German, French, Spanish and Italian

In these four languages the command words are also everyday words. "Punkt" is a noun as well as a full stop. So you say a start word first, and then the command. "Diktiere Punkt" gives a full stop. "Punkt" on its own stays the word.

The default start words are:

- German: **Diktiere**
- French: **Place**
- Spanish: **Añade**
- Italian: **Metti**

Spoken punctuation must be on. It works when your dictation language is German, French, Spanish or Italian, whether you chose the language or EnviousWispr detected it. English works as it does today: say the word on its own. You can also give English a start word, see Choose your own start word below.

In French, a mark is written straight after the word before it, with no space. In Spanish, EnviousWispr writes only the closing question mark or exclamation mark, not the opening one. Brackets, quotes, the hyphen and the ellipsis work in these four languages too, with the quotation marks each language uses; French guillemets keep a no-break space inside them. The other symbols are English only.

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
| Diktiere linke Klammer | ( |
| Diktiere Klammer auf | ( |
| Diktiere rechte Klammer | ) |
| Diktiere Klammer zu | ) |
| Diktiere Anführungszeichen unten | „ |
| Diktiere Anführungszeichen auf | „ |
| Diktiere Anführungszeichen oben | “ |
| Diktiere Anführungszeichen zu | “ |
| Diktiere Bindestrich | - |
| Diktiere Auslassungspunkte | … |

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
| Place parenthèse ouvrante | ( |
| Place parenthèse fermante | ) |
| Place guillemet ouvrant | « and a no-break space |
| Place guillemet fermant | a no-break space and » |
| Place trait d'union | - |
| Place points de suspension | … |

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
| Añade paréntesis de apertura | ( |
| Añade abrir paréntesis | ( |
| Añade paréntesis de cierre | ) |
| Añade cerrar paréntesis | ) |
| Añade abrir comillas | “ |
| Añade comillas de cierre | ” |
| Añade cerrar comillas | ” |
| Añade guion | - |
| Añade puntos suspensivos | … |

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
| Metti parentesi aperta | ( |
| Metti parentesi tonda aperta | ( |
| Metti parentesi chiusa | ) |
| Metti parentesi tonda chiusa | ) |
| Metti apri virgolette | “ |
| Metti chiudi virgolette | ” |
| Metti trattino | - |
| Metti puntini di sospensione | … |

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

In English with no start word, and **Spoken punctuation** on, EnviousWispr cannot tell when you meant the word itself. Saying "the grace period expires" puts a full stop in the middle of your sentence. Give English a start word to stop this.

In German, French, Spanish and Italian a command word stays a word unless the start word comes right before it. A start word of your own can still come up in a normal sentence, so choose one you would not say. If you chose no start word, a command word is a mark every time you say it.

### Why a mark you did not say appears next to one you did

With **Spoken punctuation** on, the marks you say are not the only marks in your text. EnviousWispr already adds punctuation for you, so this can compete with it. Your speech engine also writes commas and periods of its own, and it sometimes writes one right next to the mark you said, so you would get a comma and a period together, or two periods.

EnviousWispr cleans up the clear cases:

- **An extra mark right next to a spoken one.** You say "comma" and the engine also writes a comma or a period beside it. You get one comma.
- **A command the engine wrote twice.** "Period. period." becomes one full stop.
- **A pause in the middle of a command.** If a pause makes the engine put a full stop or comma between the start word and the command, as in "Diktiere. Punkt", it still counts as one command.

This cleanup works in English, German, French, Spanish and Italian. Other languages, and dictation with **Spoken punctuation** off, behave as before.

Some things stay as they are:

- **The engine's other marks.** A comma or period the engine adds somewhere else in your sentence stays, because EnviousWispr cannot tell it from one you meant.
- **A start word the engine leaves behind.** Sometimes the engine turns your command into a mark itself and leaves the start word in the text, for example "Anna, diktiere, Jonas". Delete the extra word by hand.
- **A mark in front of a new line or new paragraph.** A full stop before the break stays. When the break follows a sentence-ending mark, a spoken mark command, or an engine-added comma, semicolon or colon, cleanup can remove a full stop or comma after the break. It cannot tell whether you wanted that mark there; add it back by hand if needed.
- **Marks that belong to a word.** Abbreviations such as "Dr." and "p.m.", the German "z.B.", the German dot after a number as in "am 2. Juni", marks joined to the next word as in "example.com", and an ellipsis ("...") are not touched.
- **A command you say twice on purpose.** "Period period" gives two full stops.
- **Marks added by AI polish.** AI polish can change the punctuation again after this cleanup.

If an engine mark still lands where you did not want it, delete it by hand. If **Spoken punctuation** gets in your way, switch it off.

### Type a backslash

In English, saying "backslash" types `\` when **Spoken punctuation** is on and English has no start word. If you use [Snippets](/help/using-snippets/), a saved snippet wins when its words follow your snippet keyword, which is `backslash` unless you changed it. A saved snippet wins over a start word command in the same way.
