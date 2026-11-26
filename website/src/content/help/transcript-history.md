---
title: "History"
description: "Find, play back, reuse and delete your past dictations, transcripts and meetings, and paste your last dictation again."
category: "features"
section: "History"
order: 1
keywords: ["history", "past dictations", "transcripts", "speaker labels", "previous", "find an old dictation", "where did my text go", "recover", "lost text", "copy again", "log", "paste again", "paste last dictation", "copy last dictation", "history is empty", "paste last dictation greyed out", "cancelled dictation saved", "delete history", "meetings", "find a meeting", "search by invited person"]
related: ["transcribe-a-file", "transcribe-a-file-speaker-labels", "clipboard-preservation", "escape-recovery"]
updated: 2026-11-20
deflection: "can_resolve"
---
History shows your saved dictations, file transcripts and meetings, so you can come back to them later. Click the EnviousWispr icon in your menu bar and choose **Open EnviousWispr**. The window opens on **History**.

### What History holds

History has three tabs: **Dictations** for recordings you made with your keybind, **Transcripts** for files you imported with [Transcribe a File](/help/transcribe-a-file/), and **Meetings** for recordings made with [EnviousMeet](/help/enviousmeet-record-a-meeting/), including one that is still recording.

Each tab lists items newest first, grouped under **Today**, **Yesterday** and then the date. Click **Load more history** at the bottom for older items. If a transcript has more than one voice and the app can tell them apart, speakers appear as **Speaker 1**, **Speaker 2** and so on. See [speaker labels in Transcribe a File](/help/transcribe-a-file-speaker-labels/) for what those labels, **Both** and **Not fully polished** mean.

### Find a past item

- **Search.** Type in **Search history** to find text from an earlier dictation or transcript, the name of an imported file, or a speaker you renamed. You can also search finished meetings by their transcript, title, speaker names, notes, or an invited person's name, email or email domain. ("Invited" means the person was on the calendar invitation, not that they joined.)
- **Filter by date.** Choose **Any time**, **Today**, **Yesterday**, **Last 7 days** or **Last 30 days**, or pick one day or a start and end date in the calendar and click **Apply**.
- **Filter by app.** On **Dictations**, choose the app you dictated into. On **Meetings**, choose the call app.

Each tab keeps its own search and filters.

### Use a dictation

Each dictation card shows your text, with **Show more** for longer entries.

- **Play it back.** If the card includes a recording, press play, or drag along the wave to jump to a spot. See [Play back your dictations](#play-back-your-dictations) below.
- **See what polishing changed.** Click **Show edits**, then switch between **Polished**, **Marked up** and **Original**. In **Marked up**, click any marked word to compare the text before and after AI Polish. (**Show edits** only appears when AI Polish changed the text.)
- **Copy it.** Click the copy button. To paste it back into the app you came from, share it or save it as a file, click **···** and choose **Paste**, **Share…** or **Save as…**.
- **Polish it again.** Click **···**, choose **Polish again with** and pick a model you have set up. You will need to keep a cancelled dictation first. A **Compare versions** window shows the current and new text; click **Keep new** or **Keep current**.
- **Restore the text before AI Polish.** When polishing changed the text, click **···** and choose **Restore original text**. To switch back, choose **Use polished text**.

### Play back your dictations

When **Save dictation recordings** is on, EnviousWispr saves a recording of each saved dictation on your Mac so you can listen to it from its card. Recordings never leave your Mac. Failed and cancelled dictations are not recorded.

- **Choose how long recordings stay.** Go to **Settings** > **App Settings** > **Recordings** to set **Keep dictation recordings** and the **Storage warning threshold**, or to turn off **Save dictation recordings**. Turning it off stops new recordings; existing ones still follow your keep period and storage settings.
- **Keep one recording for good.** Click **···** on its card and choose **Keep this recording**. EnviousWispr keeps it regardless of your keep period.
- **Delete a recording but keep the text.** Click **···** and choose **Delete recording, keep text**. To remove every dictation recording at once, use **Delete all dictation recordings** on the **Recordings** page. Your text always stays.
- **Save a recording as a file.** Click **···** on the card and choose **Save audio…** when it appears. EnviousWispr saves the recording as an M4A file where you choose and shows it in Finder. The saved file is your own copy: deleting the dictation or its recording later does not touch it.

### Use a transcript

Click **Open** on a transcript card to view the full transcript. To rename it, click the pencil beside the title.

- **Listen along.** When the original file can be played, a player lets you listen at speeds from 0.75× to 2× and jump back or forward 15 seconds. If the transcript has saved times, **Transcript settings** offers **Timestamps**, and **Follow playback** keeps the playing line in view while audio plays.
- **Transcribe it again.** Click **···**, choose **Transcribe again with**, pick a ready speech engine and confirm. The new text replaces the existing transcript, including speaker names and cleanup, without changing your original file. This only works while the original file can be played.
- **Find the original file.** When the original file can be played, click **···** and choose **Show in Finder** to see it in Finder.
- **Find a moved file.** If the original is unavailable and **Locate original…** appears, choose it and select the original file.
- **Polish it again, share it or open it in its own window.** You will find **Polish again with**, **Share…**, **Save as…** and **Open in new window** in the **···** menu as well.

### Use a meeting

Click **Open** on a meeting card to open the meeting. **Your notes** and **AI summary** sit beside the **Transcript**, along with a player for the recording. You can learn how to take notes, write or rewrite a summary, and transcribe a meeting again in [Record a Meeting with EnviousMeet](/help/enviousmeet-record-a-meeting/).

### Delete items

- **Delete one item.** Click **···** on its card, choose **Delete dictation**, **Delete transcript** or **Delete meeting**, and confirm.
- **Delete several.** Click **Select**, select items (or Shift-click for a range), then choose an option: **Delete recordings only** or **Delete text and recordings** on **Dictations**, **Delete transcripts** on **Transcripts**, and **Delete meetings** on **Meetings**, then confirm.
- **Delete everything.** Click **Select**, then **Delete all history**, then **Delete all**. This removes every item in History, including meetings and anything hidden by a filter or search. It cannot be undone.

### Is a cancelled dictation saved?

That depends on how you cancelled.

- **Cancelled with your keybind:** EnviousWispr saves it, since [Escape Recovery](/help/escape-recovery/) is on unless you switch it off. It stays in History for 24 hours with a countdown badge. Press **Keep** to save it permanently; the badge changes to **Kept**. Until you do, it stays out of search and out of your counts.
- **Cancelled with the Cancel button beside Stop in the EnviousWispr window, or with Escape Recovery switched off:** nothing is saved.
- **No speech found:** recordings where no speech was found are not saved.

If saving fails because of a storage reason, EnviousWispr lets you know.

### Paste my last dictation again

You do not have to open History to reuse your most recent dictation.

- **Paste it.** Press **Control Command V** (unless you changed it in Keybinds), or choose **Paste Last Dictation** in the menu bar menu. It pastes into the app you are in. The menu shows the start of the text under the item so you can check it before you click.
- **Copy it.** Press **Control Command C** (unless you changed it) to put it on your clipboard.

Your **Restore clipboard after paste** setting works here too; see [Clipboard Preservation](/help/clipboard-preservation/). Change either key in **Keybinds**; see [Customizing Your Keybind](/help/customizing-your-keybind/).

### Paste Last Dictation is greyed out

Paste Last Dictation uses the newest reusable dictation in History. It skips imported transcripts, meetings, cancelled dictations still counting down, and deleted items. The menu item only appears greyed out when no reusable dictation is left.

Two other things to keep in mind: nothing happens while you are recording, and paste does nothing while an EnviousWispr window such as History is in front (though copy still works).

### Where History is kept

Your past dictations, transcripts and meetings live on your Mac, inside your user folder. They stay put when you quit the app, update it, or restart your computer. Envious Labs never receives a copy of your History, and there is no limit on how many items are kept.

### History looks empty

If the History page shows nothing, check these two things:

- **Complete a dictation, or import a file.** Finish at least one so there is something to display. Check that you are on the right tab, and set the date filter to **Any time**.
- **Check the storage folder.** If items you know you recorded are missing, check whether `~/Library/Application Support/EnviousWispr` was moved or deleted. Every copy of the app on your Mac reads that same folder.
