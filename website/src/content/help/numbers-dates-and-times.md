---
title: "Numbers, Dates and Times"
description: "How spoken numbers, money, dates, times, phone numbers, addresses and web addresses are written out."
category: "features"
section: "Text Processing"
order: 4
keywords: ["street address", "mailing address", "zip code", "numbers", "dates", "times", "money", "dollars", "percent", "phone number", "email address", "url", "version number", "ip address", "formatting numbers", "writes out numbers", "spelled out", "numbers come out as words", "web address wrong", "one twenty"]
related: ["spoken-punctuation-and-emoji", "how-text-gets-pasted-into-your-app"]
seeAlso: "spoken-text-formatting-dates-numbers-emails"
updated: 2026-09-29
deflection: "show_but_always_send"
---
EnviousWispr writes spoken numbers, money, dates, times, phone numbers, email addresses and web addresses the way you would type them, instead of spelling out every word you said. It is on from the moment you install the app, and there is nothing to configure.

### What do numbers, dates and times look like?

| You say | You get |
|---|---|
| "six thousand two hundred thirty nine dollars" | $6,239 |
| "july eleventh twenty twenty six" | July 11, 2026 |
| "six fifty p m" | 6:50 PM |
| "eight two four six one nine six one seven five" | 824-619-6175 |
| "version two point five point zero" | version 2.5.0 |
| "one nine two dot one six eight dot one dot one" | 192.168.1.1 |
| "localhost colon three thousand" | localhost:3000 |
| "S dash one" | S-1 |
| "twenty twenty six dash nine dash twenty six" | 2026-09-26 |
| "john dot smith at gmail dot com" | john.smith@gmail.com |
| "nine High Plains Road Shelton Connecticut zero six four eight four" | 9 High Plains Road, Shelton, Connecticut 06484 |

### Why are small numbers written as words?

Numbers below ten are written out as words, and numbers from ten upwards use digits. That follows the standard style used in most professional and general writing. A full street address is the exception: its house and apartment numbers are written as digits.

### How are street addresses written?

A US street address said in full, from the house number through the state and ZIP code, comes out with digits and commas, in the words you said. For example, "three twenty West Thirty Eighth Street, apartment two twenty, New York, New York one zero zero one eight" becomes 320 West 38th Street, apartment 220, New York, New York 10018.

Street and state names are not shortened to postal abbreviations. An address without a state or a ZIP code is left as you spoke it. So is a ZIP code the speech engine misheard.

### How are web addresses written?

A web address said out loud comes out ready to use when it ends in a common ending such as .com, .org, .net or .io, or has several dots and a supported country-code ending, such as google.co.uk. It can start with "www" or "https colon slash slash", and it can have several dots, such as "docs dot example dot com" or "google dot co dot uk".

EnviousWispr also tidies the edges:

- A stray period at the end of the address is dropped. A real sentence period is kept.
- A leftover "dot" sitting beside an address that has already been joined up is folded into it.
- A garbled "h slash slash" from a half-heard "https" is repaired.

To dictate into a browser's address bar, see [How Text Gets Pasted Into Your App](/help/how-text-gets-pasted-into-your-app/).

### Why did "one twenty" stay as I said it?

Some phrases carry more than one meaning. "Meet at one twenty" is a time, whereas "paid one twenty" is an amount of money. EnviousWispr leaves ambiguous phrases as you spoke them rather than guessing which you meant.

### Does AI Polish change my formatted numbers?

Number formatting runs before any AI polish. If polish is switched off or hits an error, this formatted text is what gets pasted into your app. If polish runs successfully, the AI model may still reword it.

### Do numbers, dates and times work in other languages?

Spoken number words are converted only in English. When you dictate in another language, the speech engine usually writes numbers as digits itself. EnviousWispr then tidies addresses, links and codes said with that language's own words.

First, set your dictation language under **Settings** > **Transcription** so EnviousWispr knows the language. Then it handles these:

- **Email addresses** with the local words for "at" and "dot", including names with accents. "maría punto lópez arroba gmail punto com" becomes maría.lópez@gmail.com.
- **Web addresses** with the local words for "dot", "slash" and "colon" in French, Spanish, Polish, Dutch, German, Russian, Portuguese and Italian. "beispiel Punkt de Schrägstrich hilfe" becomes beispiel.de/hilfe.
- **Codes** with a spoken dash between letters and a number. "S trattino 1" becomes S-1. A Dutch digit after a Dutch dash word is the only number word read outside English, so "GPT streepje vier" becomes GPT-4.
- **Version numbers and IP addresses** with a spoken dot between digits. "2 Punkt 5 Punkt 0" becomes 2.5.0.
- **Dates** the speech engine wrote without leading zeros.

A word the speech engine misheard is left as it is. Add the right word to your custom words and it formats correctly from then on. Any other wording is left as you spoke it.
