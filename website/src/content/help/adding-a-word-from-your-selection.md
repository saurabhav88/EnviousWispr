---
title: "Adding a Word From Your Selection"
description: "Highlight a word anywhere on your Mac, press the shortcut, and teach EnviousWispr the spelling."
category: "custom-words"
section: "Dictionary"
order: 4
keywords: ["quick add", "add selected word", "highlight a word", "selection", "shortcut", "whatsapp", "terminal", "menu bar", "clipboard", "add word from selection"]
related: ["adding-custom-words", "clipboard-preservation", "how-custom-word-correction-works"]
updated: 2026-09-01
---
When EnviousWispr writes a name the wrong way, you do not have to open settings to fix it. Highlight the word it should have written, press the Quick Add shortcut, and a small panel appears offering to attach that spelling to the word it keeps getting wrong.

### Two ways in

Both do the same thing, so use whichever is closer to hand.

1. **The shortcut.** Highlight the word, then press your Quick Add keybind. You can see and change it in **Settings**, under your keybinds.
2. **The menu bar.** Highlight the word, click the EnviousWispr icon, and choose **Add Selected Word**. The row names the word it found, so you can check it before you click.

The panel shows you the word first and ranks the words already in your library, so you pick which one this spelling belongs to. Nothing is written until you choose.

### When an app will not say what you highlighted

Most apps tell other apps what you have selected. Some do not, and there is nothing you can do about that from the outside. Messaging apps built for iPad and running on your Mac are the common case, and some terminals behave the same way.

In those apps EnviousWispr asks a second way: it copies your selection, reads it, and then puts your clipboard back. It only ever does this when the first way found nothing, so in every app that answers normally your clipboard is never touched at all.

Two things follow from that, and both are worth knowing:

- **Your clipboard history will show two extra entries** when this happens: the word that was copied, and the restore that put your own clipboard back. Every app that does this leaves the first one behind. We do not try to hide the second.
- **If you copy something yourself while the panel is open, your copy wins.** EnviousWispr checks whether anything else claimed the clipboard before putting yours back, and if something did, it leaves it alone. There is a fraction of a second while it is asking the app, before the panel appears, where a copy you make at that exact moment can be mistaken for the app's answer. If that happens you will see the wrong word in the panel, and that copy of yours is lost when your clipboard is put back.

### Turning it off

If you would rather EnviousWispr never touched your clipboard for this, open **Settings**, go to **Clipboard**, and switch off **Read selections through the clipboard**. The shortcut keeps working everywhere else; in the apps that will not share a selection, it will simply tell you it could not read one.

The setting takes effect on your very next press. It is also turned off automatically in several common remote desktop and virtual machine apps, where a copy would be sent to the other computer rather than to yours. That list cannot cover every such app, so use the setting to turn it off for any other remote-access app you use.

### If it says it could not read your selection

The panel always states the reason, and each one has a different fix:

- **Nothing was selected.** Highlight the word and press again.
- **EnviousWispr needs Accessibility permission.** Grant it in **System Settings** under **Privacy and Security**, then **Accessibility**.
- **EnviousWispr is in front.** The shortcut is global, so it works even while you are in our own settings window. Click into the app you are writing in first.
- **macOS is protecting what you are typing.** Something on your Mac has secure keyboard entry switched on, usually a password field. Click elsewhere and try again.
- **Your shortcut keys were still held down.** Let go of them, then press the shortcut again.

Whatever the reason, you can always type the word by hand in the panel that opens.
