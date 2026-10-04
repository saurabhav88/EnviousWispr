---
title: "How Text Gets Pasted Into Your App"
description: "How your dictation reaches the app you were typing in, and which apps work."
category: "pasting-your-text"
section: "Paste System"
order: 1
keywords: ["paste", "how does it type", "where does the text go", "delivery", "spacing", "capitals", "capitalisation", "capitalization", "stop capitalising", "stop capitalizing", "capital letters", "extra space", "no space", "jams words together", "smart insertion", "middle of a sentence", "cursor", "wrong window", "address bar", "trailing space", "web address"]
related: ["clipboard-preservation", "paste-not-working", "using-snippets"]
updated: 2026-10-03
deflection: "can_resolve"
---
EnviousWispr delivers your text to the app, window and text box you were typing in when you started recording. It works anywhere you can type, including native Mac apps, web browsers, and apps built on web technology such as VS Code, Slack, Discord, and Notion.

### My text went to the window I started in

EnviousWispr notes your active text box when you begin recording, not when you finish. AI polish can take a few seconds, and you might click into a different window while you wait. Because the destination is fixed at the start, your words land where you started talking, even when the app has several windows open, such as two browser windows.

If that window is gone by the time your text is ready, EnviousWispr does not paste into another one. It leaves the words on your clipboard and shows the **Copied. Press ⌘V to paste** notice.

### How EnviousWispr delivers the text

EnviousWispr tries these methods in order and stops at the first one that works:

1. **Write directly into the text box.** This does not touch your clipboard.
2. **Paste for you.** Some apps reject direct input. EnviousWispr then sends a normal paste (Cmd+V). In some apps, such as Word, Excel, Numbers and OneNote, it uses the app's own **Edit** > **Paste** menu instead.
3. **Paste with a script.** If the normal paste does not work, EnviousWispr asks macOS to paste for it. macOS may ask for the Automation permission at this point. See [_Granting Permissions_](/help/granting-permissions-microphone-accessibility-and-automation/).
4. **Copy to your clipboard and tell you.** You then paste it yourself. You never lose a dictation to a failed paste.

If your text does not show up, see [_Paste Not Working?_](/help/paste-not-working/).

### Space and capital letters around your cursor

**Smart insertion** looks at the text on either side of your cursor and matches it. Dictating into the middle of a sentence adds a space where one is needed and gets the capital letter right, instead of jamming your new words against what is already there.

To turn it off, open **Settings** > **Clipboard** and switch off **Smart insertion**. It is on by default.

Capital matching works in English, German, French, Italian, Spanish, Portuguese, Dutch, Danish, Swedish, Finnish, Russian, and Turkish. German follows its own rules, so nouns keep the capital letters they are supposed to have. In every other language, EnviousWispr adjusts the spacing and leaves your capitals exactly as you spoke them.

### Dictating a snippet

A dictation that expands a snippet skips the space and capital tidy-up. The text you saved arrives word for word, with any date, time or clipboard fill-ins filled in, and only the usual space after it. See [_Using Snippets_](/help/using-snippets/).

### Dictating a web address into the address bar

With **Smart insertion** on, dictating into the address bar of Safari, Chrome, Brave or Edge does not add a trailing space you would have to delete. In Chrome and Brave, pressing Return after dictating an address then goes to it.

If you switch **Smart insertion** off, this no longer applies.

### Will dictating erase what I copied?

Usually not. When **Restore clipboard after paste** is on (the default), EnviousWispr saves what was on your clipboard before you dictated and puts it back right after pasting. See [_Clipboard Preservation_](/help/clipboard-preservation/).

### Permission needed to insert text

EnviousWispr needs the macOS Accessibility permission to insert text for you. Without it, EnviousWispr copies your text to your clipboard and tells you instead. Full-screen games and other apps that block simulated typing also prevent direct insertion. See [_Accessibility Permission Not Working_](/help/accessibility-permission-not-working/).
