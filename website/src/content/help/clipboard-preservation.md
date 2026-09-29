---
title: "Clipboard Preservation"
description: "How EnviousWispr avoids trampling what you already had copied."
category: "pasting-your-text"
section: "Paste System"
order: 2
keywords: ["clipboard", "copied text", "lost what i copied", "overwrites clipboard", "restore clipboard", "cmd v", "pasteboard", "dictation replaced my clipboard", "clipboard history", "auto-copy"]
related: ["how-text-gets-pasted-into-your-app", "adding-a-word-from-your-selection"]
updated: 2026-09-29
deflection: "can_resolve"
---
### Does dictating erase what I copied?

No, not in the normal case. When your dictation has to go through the clipboard to reach an app, EnviousWispr saves what you had copied, pastes your text, then puts your original clipboard back. This is the **Restore clipboard after paste** setting, and it is on by default.

The saved clipboard is not limited to plain text. Everything on it is kept.

### When EnviousWispr leaves your clipboard alone

In three situations EnviousWispr does not put your old clipboard back, each to avoid losing something.

- **The text went straight into the text box.** EnviousWispr never touched your clipboard at all.
- **Another app changed your clipboard while you dictated.** This can happen with a clipboard manager. EnviousWispr does not overwrite the new content.
- **The paste failed.** Your dictation is on the clipboard so you can paste it yourself, and EnviousWispr leaves it there.

### Keep my dictation on the clipboard

Two settings on the **Clipboard** page control this. Open **Settings** > **Clipboard**. Both are on by default.

- **Restore clipboard after paste.** Puts what you had copied back after your dictation lands. Switch it off if you would rather keep the dictation on your clipboard to paste again somewhere else.
- **Auto-copy to clipboard.** Copies your dictation to the clipboard whenever EnviousWispr is not pasting it into an app for you.

**Settings** > **Clipboard** also holds **Smart insertion**, which matches spacing and capitals to the text around your cursor. See [_How Text Gets Pasted Into Your App_](/help/how-text-gets-pasted-into-your-app/).

### Quick Add and your clipboard

Adding a word from a selection normally reads what you highlighted without touching your clipboard. Some apps will not say what you have selected, such as messaging apps built for iPad and some terminals. In those, EnviousWispr briefly copies your selection, reads it, and puts your clipboard back. Your clipboard history will show both entries.

The switch is **Read selections through the clipboard**, under **Quick Add** on the same **Clipboard** page. It is on by default, and it turns itself off in common remote desktop and virtual machine apps. See [_Adding a Word From Your Selection_](/help/adding-a-word-from-your-selection/).
