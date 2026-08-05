---
title: "How Text Gets Pasted Into Your App"
description: "How your dictation reaches the app you were typing in, and which apps work."
category: "pasting-your-text"
section: "Paste System"
order: 1
keywords: ["paste", "how does it type", "where does the text go", "delivery", "spacing", "capitals", "capitalisation", "capitalization", "stop capitalising", "stop capitalizing", "capital letters", "extra space", "no space", "jams words together", "smart insertion", "middle of a sentence", "cursor"]
related: ["clipboard-preservation", "paste-not-working"]
updated: 2026-08-05
---
EnviousWispr remembers the app and text field that were focused when you started recording, and delivers your text there. It works anywhere you can type: native Mac apps, browsers, and apps built on web technology such as VS Code, Slack, Discord and Notion.

### It picks the destination at the start

Not at the end. AI Polish can take a few seconds, and you may have clicked elsewhere. Locking it in at the start means your words land where you were talking. Keep that field open until the text arrives.

### It tries the cleanest method first

Writing straight into the text box, without touching your clipboard. Some apps will not accept that, so EnviousWispr falls back to a normal paste, and then to the app's own Edit \> Paste menu.

If none of that works, your text goes to your clipboard and you are told, so you can paste it yourself. You never lose a dictation to a failed paste.

### Spacing and capitals

EnviousWispr looks at the text either side of your cursor and matches it. Dictating into the middle of a sentence adds a space where one is needed and keeps the capital letter right, instead of jamming your words against what is already there.

You can switch this off under **Clipboard** in Settings, where it is called **Smart insertion**.

### Your clipboard

When **Restore clipboard after paste** is on, EnviousWispr saves what was on your clipboard and puts it back after pasting. It is on out of the box. See [[_Clipboard Preservation_](/help/clipboard-preservation/)](/help/clipboard-preservation/).

### What this needs

Accessibility permission. Without it, EnviousWispr copies your text to the clipboard and tells you instead. Full-screen games and apps that block simulated typing are the other exceptions.
