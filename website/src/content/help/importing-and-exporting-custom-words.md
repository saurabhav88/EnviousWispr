---
title: "Importing and Exporting Custom Words"
description: "Move your custom words to another Mac, or bring them in from another dictation app."
category: "custom-words"
section: "Dictionary"
order: 3
keywords: ["import", "export", "backup my words", "csv", "move to a new mac", "transfer", "share my word list", "switch from another dictation app", "bring my words over", "delete several words", "remove many words"]
related: ["adding-custom-words", "using-snippets"]
updated: 2026-10-04
deflection: "can_resolve"
---
Your custom words are the names and specialised words you have taught EnviousWispr. You can back them up, move them to another Mac, or bring them in from another dictation app. Every control on this page is under **Settings** > **Dictionary** > **Your Words**.

### Bring in words from a file, a list or another app

Importing adds new words to your list without changing the words you already have.

1. **Open the import tool.** Click **Import** on the **Your Words** tab.
2. **Choose your source.** Paste a list of words, open a saved file, or import from another dictation app. A file can be a previous export from EnviousWispr, or any plain text document with one word per line.
3. **Review the list.** Check the words it found.
4. **Add them.** Confirm, and the words join your list. They are ordinary custom words and behave like any others.

### Import words from another dictation app

EnviousWispr can read your vocabulary from Wispr Flow, FluidVoice, Superwhisper, Vox, TypeWhisper, Spokenly, Juno, or Handy, if they are installed on your Mac. Click **Import** under **Settings** > **Dictionary** > **Your Words**, choose to import from another app, and pick it.

It brings over the words you added yourself, along with any misspellings that app was already correcting for you. A few apps store more than a word list, and only the word list comes across:

- **Handy** keeps a separate list of filler words it removes from your dictation. Those are not brought across, because you asked Handy to remove them, not keep them. Its prompts and tuning settings stay behind too. You do not need to quit Handy first.
- **Juno** ships with around 400 built-in words. Only the words you added are imported, so your list stays yours.
- **Spokenly** can store find-and-replace rules written as patterns rather than plain words. Those are skipped, because a pattern is not a word.
- **TypeWhisper** entries you have switched off are not imported at all. For the entries that are, its case-sensitivity setting for each word comes across. Its match-strictness setting does not.
- **Wispr Flow** text shortcuts are skipped, because they are text expansions rather than vocabulary. EnviousWispr's version of those is [Snippets](/help/using-snippets/), and you can import them from Wispr Flow separately under **Settings** > **Snippets**.

If an app holds entries but none of them can come across, EnviousWispr tells you how many it found rather than saying it found nothing.

### Does importing read another app's files?

Only after you pick that app in the import screen. EnviousWispr does not look inside another app's files in the background. It reads them on your Mac, and Envious Labs never receives your words. The other app's files are only read, never changed, and you review every word before anything is added.

If you use a cloud provider for AI Polish, your custom words are sent to it along with your text, whether or not you imported them. See [Adding Custom Words](/help/adding-custom-words/).

### Back up your words or move them to a new Mac

Exporting creates a file holding your whole custom word list.

1. **Start the export.** On the **Your Words** tab, click **Export your words**.
2. **Save the file.** Choose where on your Mac to store it, then confirm.

To use the file on another Mac, install EnviousWispr there, open **Settings** > **Dictionary** > **Your Words**, click **Import**, and open the file you saved.

### Delete several words at once

You can select a group of words instead of deleting them one at a time.

1. **Turn on selection.** Click **Mass edit**, beside the search box above your list of words.
2. **Choose the words.** Tick the box next to every word you want to remove.
3. **Delete them.** Click **Delete…** to remove all the ticked words at once.
