---
title: "History"
description: "Find, reuse and delete your past dictations and transcripts, and paste your last dictation again."
category: "features"
section: "History"
order: 1
keywords: ["history", "past dictations", "transcripts", "speaker labels", "previous", "find an old dictation", "where did my text go", "recover", "lost text", "copy again", "log", "paste again", "paste last dictation", "copy last dictation", "history is empty", "paste last dictation greyed out", "cancelled dictation saved", "delete history"]
related: ["transcribe-a-file", "transcribe-a-file-speaker-labels", "clipboard-preservation", "escape-recovery"]
updated: 2026-09-29
deflection: "can_resolve"
---
EnviousWispr saves everything it transcribes so you can find it again later. To see it, click the EnviousWispr icon in your menu bar and choose **Open EnviousWispr**. The window opens on **History**.

### What History holds

History holds two kinds of item. A **dictation** is a recording you made with your keybind. A **transcript** is a recording you imported with [Transcribe a File](/help/transcribe-a-file/).

Each row says which kind it is. The **All**, **Dictations** and **Transcripts** buttons above the list show one kind or both. A transcript with more than one voice shows its speakers, named **Speaker 1**, **Speaker 2** and so on. Click a name to rename it. What the labels mean, and what **Both** and **Not fully polished** mean, is in [speaker labels in Transcribe a File](/help/transcribe-a-file-speaker-labels/).

### Find, copy or delete a past dictation

- **Search.** Type in **Search history** to find text from an earlier dictation or transcript, the name of an imported file, or a speaker you renamed.
- **Copy or paste.** Copy a past dictation or transcript back to your clipboard, or paste it straight into the app you are in.
- **Delete records.** Remove a single dictation or transcript you no longer need, or delete all of them at once. Delete all removes every item in History, including any a filter or search is hiding.

### Is a cancelled dictation saved?

It depends on how you cancelled.

- **Cancelled with your keybind:** it is saved, because [Escape Recovery](/help/escape-recovery/) is on unless you switch it off. It stays in History for 24 hours with a countdown badge. Press **Keep** to make it permanent, and it then shows a **Kept** badge. Until you do, it stays out of search and out of your counts.
- **Cancelled with the Cancel button beside Stop in the EnviousWispr window, or with Escape Recovery switched off:** nothing is saved.
- **No speech found:** recordings where no speech was found are not saved.

If saving fails for a storage reason, EnviousWispr tells you.

### Paste my last dictation again

You do not need to open History to reuse your most recent dictation.

- **Paste it.** Press **Control Command V** (unless you changed it in Keybinds), or choose **Paste Last Dictation** in the menu bar menu. It pastes into the app you are in. The menu shows the start of the text under the item, so you can check it before you click.
- **Copy it.** Press **Control Command C** (unless you changed it) to put it on your clipboard.

Your **Restore clipboard after paste** setting works here too: see [Clipboard Preservation](/help/clipboard-preservation/). Change either key in **Keybinds**: see [Customizing Your Keybind](/help/customizing-your-keybind/).

### Paste Last Dictation is greyed out

Paste Last Dictation uses the newest dictation in History that it can reuse. It skips imported transcripts, cancelled dictations still counting down, and deleted items. The menu item is greyed out only when no dictation it can reuse is left.

Two other things to know. Nothing happens while you are recording. And paste does nothing while an EnviousWispr window such as History is in front, though copy still works.

### Where History is kept

Your past dictations and transcripts are stored on your Mac, inside your user folder. They survive quitting the app, updating it, and restarting your computer. Envious Labs never receives a copy of your History, and there is no limit on how many items are kept.

### History looks empty

If the History page shows nothing, check these two things.

- **Complete a dictation, or import a file.** Finish at least one, so there is something to display. If a filter is on, choose **All**.
- **Check the storage folder.** If items you know you recorded are missing, check whether `~/Library/Application Support/EnviousWispr` was moved or deleted. Every copy of the app on your Mac reads that same folder.
