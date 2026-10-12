---
title: "Clipboard Preservation"
description: "How EnviousWispr avoids trampling what you already had copied."
category: "pasting-your-text"
section: "Paste System"
order: 2
keywords: ["clipboard", "copied text", "lost what i copied", "overwrites clipboard", "restore clipboard", "cmd v", "pasteboard", "dictation replaced my clipboard", "clipboard history", "auto-copy"]
related: ["how-text-gets-pasted-into-your-app", "adding-a-word-from-your-selection"]
updated: 2026-10-12
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

Three settings on the **Clipboard** tab control this. Open **Dictation Settings** > **Clipboard**. The first two are on by default.

- **Restore clipboard after paste.** Puts what you had copied back after your dictation lands. Switch it off if you would rather keep the dictation on your clipboard to paste again somewhere else.
- **Auto-copy to clipboard.** Copies your dictation to the clipboard whenever EnviousWispr is not pasting it into an app for you.
- **Keep dictations out of clipboard history apps.** Off by default. See the next section.

### Will my clipboard history app save my dictation?

By default it may. When EnviousWispr uses the clipboard to paste your dictation, a clipboard history app such as Maccy, Raycast or Paste can record it. Direct insertion into a text box does not use the clipboard.

Switch on **Keep dictations out of clipboard history apps** to ask those apps to skip it. EnviousWispr then marks the temporary copy of your dictation, and the clipboard it puts back, with the common "do not record" label. Apps that follow that label will not save them. An app that ignores the label still may. The setting only applies while **Restore clipboard after paste** is on, because that is when the dictation is on your clipboard only for a moment. When a paste fails and EnviousWispr leaves your dictation on the clipboard for you, history apps can still save it.

**Dictation Settings** > **Clipboard** also holds **Smart insertion**, which matches spacing and capitals to the text around your cursor. See [_How Text Gets Pasted Into Your App_](/help/how-text-gets-pasted-into-your-app/).

### Quick Add and your clipboard

Adding a word from a selection normally reads what you highlighted without touching your clipboard. Some apps will not say what you have selected, such as messaging apps built for iPad and some terminals. In those, EnviousWispr briefly copies your selection, reads it, and puts your clipboard back. Your clipboard history will show both entries.

The switch is **Read selections through the clipboard**, under **Quick Add** on the same **Clipboard** tab. It is on by default, and it turns itself off in common remote desktop and virtual machine apps. See [_Adding a Word From Your Selection_](/help/adding-a-word-from-your-selection/).
