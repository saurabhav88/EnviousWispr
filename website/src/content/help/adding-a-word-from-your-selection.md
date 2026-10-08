---
title: "Adding a Word From Your Selection"
description: "Highlight a word anywhere on your Mac, press the shortcut, and teach EnviousWispr the spelling."
category: "custom-words"
section: "Dictionary"
order: 4
keywords: ["quick add", "add selected word", "highlight a word", "selection", "shortcut", "whatsapp", "terminal", "menu bar", "clipboard", "add word from selection", "could not read your selection", "shortcut starts a recording", "Control Shift W"]
related: ["adding-custom-words", "clipboard-preservation", "how-custom-word-correction-works", "customizing-your-keybind"]
updated: 2026-09-29
deflection: "can_resolve"
---
When EnviousWispr writes a name the wrong way, you do not have to open settings to fix it. Highlight the word it should have written and press the Quick Add shortcut. A small panel appears offering to attach that spelling to the word it keeps getting wrong.

### Add a word you highlighted

There are two ways in, and both do the same thing.

1. **Use the shortcut.** Highlight the word, then press your Quick Add keybind. It is **Control Shift W** unless you have changed it. To see or change it, go to **Keybinds** and look at the **Add selected word to Dictionary** row.
2. **Use the menu bar.** Highlight the word, click the EnviousWispr icon, and choose the item that starts with **Add**. It names the word it found, so you can check it before you click.

The panel shows the word first and ranks the words already in your library, so you pick which one this spelling belongs to. Nothing is saved until you choose.

### The shortcut opens a recording instead

Before version 2.4.7, the shortcut shared the Option key with the record key, so pressing it could start a recording instead of opening the panel. The shortcut is now Control Shift W. If you had chosen your own keys, they are untouched. If you still see this, check the keys under **Keybinds** > **Add selected word to Dictionary**.

### It says it could not read my selection

The panel always states the reason, and each one has a different fix:

- **Nothing was selected.** Highlight the word and press again.
- **EnviousWispr needs Accessibility permission.** Grant it in **System Settings** > **Privacy & Security** > **Accessibility**.
- **EnviousWispr is in front.** The shortcut is global, so it works even while you are in our own settings window, but there is nothing of yours to read there. Click into the app you are writing in first.
- **macOS is protecting what you are typing.** Something on your Mac has secure keyboard entry switched on, usually a password field. Click elsewhere and try again.
- **Your shortcut keys were still held down.** Let go of them, then press the shortcut again.

Whatever the reason, you can always type the word by hand in the panel that opens.

### It does not work in some apps

Most apps tell other apps what you have selected. Some do not, and nothing can be done about that from outside. Messaging apps built for iPad and running on your Mac are the common case, and some terminals behave the same way.

In those apps EnviousWispr asks a second way. It copies your selection, reads it, then puts your clipboard back. It only does this when the first way found nothing, so in apps that answer normally your clipboard is never touched.

### My clipboard history shows extra entries

When EnviousWispr uses the copy method, your clipboard history shows two extra entries: the word that was copied, and the restore that put your own clipboard back. Every app that does this leaves the first one behind. EnviousWispr does not try to hide the second.

### I copied something while the panel was open

Your copy wins. EnviousWispr checks whether anything else claimed the clipboard before putting yours back, and if something did, it leaves it alone.

There is a fraction of a second, while it asks the app and before the panel appears, when a copy you make at that exact moment can be mistaken for the app's answer. If that happens, you see the wrong word in the panel, and your copy is lost when your clipboard is put back.

### Stop it from using my clipboard

1. Open **Dictation Settings** > **Clipboard**.
2. Switch off **Read selections through the clipboard**.

The setting takes effect on your very next press. The shortcut keeps working everywhere else. In the apps that will not share a selection, it tells you it could not read one.

EnviousWispr also turns this off automatically in several common remote desktop and virtual machine apps, where a copy would go to the other computer rather than yours. That list cannot cover every such app, so switch the setting off yourself if you use another remote-access app.
