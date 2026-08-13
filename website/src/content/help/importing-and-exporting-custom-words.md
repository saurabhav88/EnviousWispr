---
title: "Importing and Exporting Custom Words"
description: "Moving your custom words between Macs, or bringing them in from another app."
category: "custom-words"
section: "Custom Words"
order: 3
keywords: ["import", "export", "backup my words", "csv", "move to a new mac", "transfer", "share my word list"]
related: ["adding-custom-words"]
updated: 2026-08-06
---
Your custom words are the names and specialised terms you have taught EnviousWispr to recognise. You can move them to another Mac or bring them in from another dictation app. Every control mentioned on this page lives under **Settings** \> **Your Words**.

### Importing custom words

Importing adds new terms to your list without changing the words you already have. You can bring in a plain text file, paste a list directly, or pull terms from another dictation app installed on your Mac.

**Open the import tool.** Click **Import** on the Your Words page.

**Choose your source.** Select whether you want to paste a list of words, open a saved file, or import from another dictation app. EnviousWispr can read your existing vocabulary straight out of Wispr Flow, FluidVoice, Superwhisper, Vox, TypeWhisper, Spokenly, Juno, or Handy if you have them installed. If you are importing from a file, that file can be a previous export from EnviousWispr or any plain text document with one word per line.

**What comes across, app by app.** EnviousWispr brings over the words you added yourself, along with any misspellings that app was already correcting for you. A few apps store more than a word list, and only the word list comes across:

- **Handy** keeps a separate list of filler words it strips out of your dictation. Those are not brought across, because they are words you asked Handy to remove rather than words you want kept. Its prompts and tuning settings stay behind too. You do not need to quit Handy first.
- **Juno** ships with around 400 built-in terms of its own. Only the words you added are imported, so your list stays yours.
- **Spokenly** can store find-and-replace rules written as patterns rather than plain words. Those are skipped, because a pattern is not a word.
- **TypeWhisper** entries you have switched off stay off, and its case-sensitivity setting for each word comes across with it. Its match-strictness setting does not.
- **Wispr Flow** text shortcuts are skipped. Those are text expansions rather than vocabulary.

If an app holds entries but none of them can come across, EnviousWispr tells you how many it found rather than saying it found nothing.

**Nothing is read until you ask for it.** EnviousWispr does not look inside another app's files in the background. It reads them only after you pick that app in the import screen, and it reads them on your Mac. Envious Labs never receives your words. The other app's own files are only ever read, never changed, and you review every word before anything is added to your list.

Once you add them, they are ordinary custom words and behave like any others. If you have chosen a cloud provider for AI Polish, your custom words are sent to that provider along with your text so your spellings survive the rewrite, exactly as described in [Adding custom words](/help/adding-custom-words/). The import itself does not change that either way.

**Review and confirm.** Check the list of terms it found, then add them to your list.

### Exporting your vocabulary

Exporting creates a file holding your whole custom word list, which you can keep as a backup or carry to another Mac.

**Start the export.** Click **Export your words**.

**Save the file.** Choose where on your Mac you want to store it, then confirm the location.

### Removing several words at once

If you want to clear out several terms together, you can select them as a group rather than deleting them one at a time.

**Turn on selection.** Click **Select**, which sits directly above your list of terms.

**Choose the words.** Tick the box next to every word you want to remove.

**Delete the selection.** Click **Delete** to remove all the ticked words at once.
