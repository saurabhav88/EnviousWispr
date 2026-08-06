---
title: "Clipboard Preservation"
description: "How EnviousWispr avoids trampling what you already had copied."
category: "pasting-your-text"
section: "Paste System"
order: 2
keywords: ["clipboard", "copied text", "lost what i copied", "overwrites clipboard", "restore clipboard", "cmd v", "pasteboard"]
related: ["how-text-gets-pasted-into-your-app"]
updated: 2026-08-05
---
EnviousWispr is a free dictation app for macOS. Some of the ways it delivers your text have to use your clipboard, so it saves whatever was there first and puts it back afterwards.

### How it works

1. Your clipboard is saved, everything on it, not only plain text.
2. Your dictation is pasted.
3. Your original clipboard comes back.

### When it leaves your clipboard alone

- If your text went straight into the box, the clipboard was never touched.
- If another app, such as a clipboard manager, changed the clipboard in between, EnviousWispr does not overwrite it.
- If pasting failed and your dictation ended up on the clipboard, it stays there so you can paste it yourself.

### The two settings

Both live under **Settings** \> **Clipboard**, and both are on out of the box.

- **Restore clipboard after paste.** Puts back what you had copied. Switch it off if you would rather keep your dictation on the clipboard to paste again somewhere else.
- **Auto-copy to clipboard.** Copies your dictation whenever EnviousWispr is not pasting it into an app for you.
