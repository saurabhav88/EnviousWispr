---
title: "Numbers, Dates and Times"
description: "How spoken numbers, money, dates and phone numbers get written out."
category: "features"
section: "Text Processing"
order: 4
keywords: ["numbers", "dates", "times", "money", "dollars", "percent", "phone number", "email address", "url", "version number", "ip address", "formatting numbers", "writes out numbers", "spelled out"]
related: ["spoken-punctuation-and-emoji", "how-text-gets-pasted-into-your-app"]
seeAlso: "spoken-text-formatting-dates-numbers-emails"
updated: 2026-09-26
---
Numbers, dates, and times are converted automatically from spoken words into the standard written forms. EnviousWispr writes numbers, money, dates, times, phone numbers, email addresses, and web addresses the way you would type them, rather than spelling out every word you said. It is switched on when you install the app, and there is nothing to configure.

### Examples of spoken input and written output

| You say | You get |
|---|---|
| "six thousand two hundred thirty nine dollars" | $6,239 |
| "july eleventh twenty twenty six" | July 11, 2026 |
| "six fifty p m" | 6:50 PM |
| "eight two four six one nine six one seven five" | 824-619-6175 |
| "version two point five point zero" | version 2.5.0 |
| "one nine two dot one six eight dot one dot one" | 192.168.1.1 |
| "S dash one" | S-1 |
| "twenty twenty six dash nine dash twenty six" | 2026-09-26 |
| "john dot smith at gmail dot com" | john.smith@gmail.com |

### Small numbers stay as words

Numbers below ten are written out as words, while numbers from ten upwards use digits. That follows the standard style used in most professional and general writing.

### Web addresses

A web address said out loud comes out ready to use when it ends in a common ending such as .com, .org, .net or .io, or is a supported country-code address with several dots, including one that starts with "www" or "https colon slash slash" and one with several dots, such as "docs dot example dot com" or "google dot co dot uk". A stray period at the end of it is dropped, while a real sentence period is kept. A leftover "dot" sitting beside an address that has already been joined up is folded into it, and a garbled "h slash slash" from a half-heard "https" is repaired. Dictating into a browser's address bar is covered in [_How Text Gets Pasted Into Your App_](/help/how-text-gets-pasted-into-your-app/).

### When the formatting happens

Formatting runs before any AI polish. If polish is switched off or hits an error, this formatted text is what gets pasted into your app. If a polish step runs successfully, the AI model may still reword it.

### Ambiguous phrases

Some phrases carry more than one meaning depending on the context. "Meet at one twenty" is a time, whereas "paid one twenty" is an amount of money. EnviousWispr leaves ambiguous phrases as you spoke them rather than guessing which you meant.

### Other languages

Spoken number words are converted only in English. When you dictate in another language, the speech engine usually writes numbers as digits itself, and EnviousWispr then tidies addresses, links and codes said with that language's own words:

- An email address with the local words for "at" and "dot", including names with accents: "maría punto lópez arroba gmail punto com" becomes maría.lópez@gmail.com, and "łukasz małpa przykład kropka pl" becomes łukasz@przykład.pl.
- A web address with the local words for "dot", "slash" and "colon" in French, Spanish, Polish and Dutch: "ejemplo punto es barra ayuda" becomes ejemplo.es/ayuda, "www punt voorbeeld punt nl" becomes www.voorbeeld.nl, "https deux points barre oblique barre oblique exemple point fr" becomes https://exemple.fr, and "localhost dos puntos 3000" becomes localhost:3000.
- A code with a spoken dash between letters and a number: "S trattino 1" and "S myślnik 1" become S-1, and "GPT streepje vier" becomes GPT-4 (a Dutch digit after a Dutch dash word is the only number word read outside English).
- A version number or IP address with a spoken dot between digits: "2 Punkt 5 Punkt 0" and "2 kropka 5 kropka 0" become 2.5.0.
- A date the engine wrote without leading zeros.

Set your dictation language in Speech Engine settings so EnviousWispr knows the language. A word the speech engine misheard is left as it is; add the right word to your custom words and it formats from then on. Other wording is left as you spoke it.
