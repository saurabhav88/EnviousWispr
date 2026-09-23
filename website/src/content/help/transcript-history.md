---
title: "History"
description: "Finding, reusing, and deleting your past dictations and transcripts."
category: "features"
section: "History"
order: 1
keywords: ["history", "past dictations", "transcripts", "speaker labels", "previous", "find an old dictation", "where did my text go", "recover", "lost text", "copy again", "log", "paste again", "paste last dictation", "copy last dictation"]
related: ["transcribe-a-file", "transcribe-a-file-speaker-labels", "clipboard-preservation", "escape-recovery"]
updated: 2026-09-23
---
EnviousWispr saves everything it transcribes so you can find it again later. History holds two kinds of item. A **dictation** is a recording you made with your keybind. A **transcript** is a recording you imported with [Transcribe a File](/help/transcribe-a-file/). To see them, click the EnviousWispr icon in your menu bar, choose **Settings**, and go to **History**.

Each row says which kind it is. The **All**, **Dictations** and **Transcripts** buttons above the list show one kind or both. A transcript with more than one voice shows its speakers, named **Speaker 1**, **Speaker 2** and so on; click a name to rename it. What the labels mean, and what **Both** and **Not fully polished** mean, is in [speaker labels in Transcribe a File](/help/transcribe-a-file-speaker-labels/).

Recordings where no speech was found are not saved. A dictation you cancel with your keybind IS saved, because [Escape Recovery](/help/escape-recovery/) is on unless you switch it off: it is kept here for 24 hours with a **Kept** badge and a countdown, and press **Keep** to make it permanent. Switch that setting off, or use the Cancel button in the recording bar, and nothing is saved. Until you do, it stays out of search and out of your counts. If saving fails for a storage reason, EnviousWispr tells you.

### What you can do

History gives you several ways to work with past recordings.

- **Search.** Type in **Search history** to find text from an earlier dictation or transcript, the name of an imported file, or a speaker you renamed.
- **Copy or paste.** Copy a past dictation or transcript back to your clipboard, or paste it straight into the app you are in.
- **Delete records.** Remove a single dictation or transcript you no longer need, or delete all of them at once. Delete all removes every item in History, including any a filter or search is hiding.

### Paste your last dictation again

You do not need to open History to reuse your most recent dictation.

- **Paste it.** Press **Control Command V**, or choose **Paste Last Dictation** in the menu bar menu. It pastes into the app you are in. The menu shows the start of the text under the item, so you can check it before you click.
- **Copy it.** Press **Control Command C** to put it on your clipboard.

The last dictation is your newest dictation in History. Imported transcripts are skipped, and so is a cancelled dictation still counting down in History, until you press **Keep** on it. Anything you have deleted is skipped too. When there is nothing to reuse, the menu item is greyed out. Nothing happens while you are recording, and paste does nothing while an EnviousWispr window such as History is in front, though copy still works. Your **Restore clipboard after paste** setting works here too: see [Clipboard Preservation](/help/clipboard-preservation/). Change either key in **Keybinds**: see [Customizing Your Keybind](/help/customizing-your-keybind/).

### Where it is kept

Your past dictations and transcripts are stored on your Mac, inside your user folder. They survive quitting the app, updating it, and restarting your computer. Envious Labs never receives a copy of your History, and there is no limit on how many items are kept.

### If History looks empty

If the history view shows nothing, check these two things.

- **Complete a dictation, or import a file.** Finish at least one, so there is something to display. If a filter is on, choose **All**.
- **Check the storage folder.** If items you know you recorded are missing, check whether `~/Library/Application Support/EnviousWispr` was moved or deleted. Every copy of the app on your Mac reads that same folder.
