---
title: "How Text Gets Pasted Into Your App"
description: "How your dictation reaches the app you were typing in, and which apps work."
category: "pasting-your-text"
section: "Paste System"
order: 1
keywords: ["paste", "how does it type", "where does the text go", "delivery", "spacing", "capitals", "capitalisation", "capitalization", "stop capitalising", "stop capitalizing", "capital letters", "extra space", "no space", "jams words together", "smart insertion", "middle of a sentence", "cursor"]
related: ["clipboard-preservation", "paste-not-working"]
updated: 2026-08-06
---
EnviousWispr remembers the app and text field that were focused when you started recording, and delivers your text there. It works anywhere you can type, including native Mac apps, web browsers, and apps built on web technology such as VS Code, Slack, Discord, and Notion.

### The destination is locked in at the start

EnviousWispr captures your active text field when you begin recording rather than when you finish. AI polish can take a few seconds, and you might click into a different window while you wait. Locking the destination at the beginning is what makes sure your words land where you started talking. Keep that text field open until your text arrives.

### Three ways to deliver the text, tried in order

EnviousWispr first tries to write your text directly into the text box, without touching your clipboard. Some apps reject direct input, so it falls back to an ordinary paste command, and then to the app's own Edit \> Paste menu.

If all three fail, EnviousWispr copies your text to your clipboard and tells you, so you can paste it yourself. You never lose a dictation to a failed paste.

### Spacing and capitals are handled for you

EnviousWispr looks at the text on either side of your cursor and matches it. Dictating into the middle of a sentence adds a space where one is needed and gets the capital letter right, instead of jamming your new words against what is already there.

Capital matching works in English, German, French, Italian, Spanish, Portuguese, Dutch, Danish, Swedish, Finnish, Russian, and Turkish. German follows its own rules, so nouns keep the capital letters they are supposed to have. In every other language, EnviousWispr handles the spacing and leaves your capitals exactly as you spoke them.

You can turn this behaviour off under **Settings** \> **Clipboard**, where the setting is named **Smart insertion**.

### Your clipboard contents are preserved

When **Restore clipboard after paste** is switched on, EnviousWispr saves whatever was on your clipboard before you dictated and puts it back immediately after pasting. This setting is on by default. See [_Clipboard Preservation_](/help/clipboard-preservation/) for the detail.

### The permission this needs

EnviousWispr needs macOS Accessibility permission to insert text for you. Without it, the app copies your text to your clipboard and tells you instead. Full-screen games and applications that block simulated typing also prevent direct insertion.
