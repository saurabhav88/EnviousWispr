---
title: "Clipboard Preservation"
description: "How EnviousWispr avoids trampling what you already had copied."
category: "pasting-your-text"
section: "Paste System"
order: 2
keywords: ["clipboard", "copied text", "lost what i copied", "overwrites clipboard", "restore clipboard", "cmd v", "pasteboard"]
related: ["how-text-gets-pasted-into-your-app"]
updated: 2026-08-06
---
When you dictate, your text often has to travel through your clipboard to reach the app you are working in. EnviousWispr handles that by recording whatever is on your clipboard first, and putting it back immediately afterwards.

### How it works

EnviousWispr runs the paste in three steps, which is what protects what you already had.

- **Save your clipboard.** Everything currently on the clipboard is preserved, not only plain text.
- **Paste your dictation.** Your newly transcribed text appears in the text box you were working in.
- **Restore your original clipboard.** What you had copied goes back onto the clipboard, so you lose nothing.

### When it leaves your clipboard alone

In three situations that cycle changes, each one to avoid losing something.

- **Direct text insertion.** If your dictation went straight into the text box without using the clipboard, EnviousWispr never touched your clipboard at all.
- **Third-party clipboard managers.** If another application changes your clipboard while your dictation is in progress, EnviousWispr does not overwrite the new content.
- **Failed paste attempts.** If pasting failed and your dictation ended up on the clipboard instead, EnviousWispr leaves it there so you can paste it yourself.

### The two settings

You control this under **Settings** \> **Clipboard**. Both options are on by default.

- **Restore clipboard after paste.** Puts what you had copied back onto the clipboard after your dictation lands. Switch this off if you would rather keep the dictation on your clipboard to paste again somewhere else.
- **Auto-copy to clipboard.** Copies your dictation to the clipboard whenever EnviousWispr is not pasting it into an app for you.
