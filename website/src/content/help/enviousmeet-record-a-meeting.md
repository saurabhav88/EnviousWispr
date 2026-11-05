---
title: "EnviousMeet: Record a Meeting"
description: "Record a call or an in-person meeting on your Mac and get a transcript with who said what, your own notes and an optional summary."
category: "features"
section: "EnviousMeet"
order: 10
keywords: ["enviousmeet", "record a meeting", "meeting recorder", "record a call", "zoom transcript", "google meet transcript", "teams transcript", "meeting notes", "who said what", "speaker labels", "speaker names", "meeting summary", "summary engine", "call sound", "system audio", "record without a bot", "consent", "calendar meeting names", "invited people", "meeting audio", "probable echo", "echo", "mute", "leave my voice out when muted", "turn off dictation during meetings", "live preview", "live words", "transcript engine", "transcript language", "long meeting summary"]
related: ["enviousmeet-when-a-call-starts", "transcript-history", "transcribe-a-file-speaker-labels", "ai-polish-and-cloud-data", "privacy-overview"]
updated: 2026-11-05
deflection: "show_but_always_send"
---
EnviousMeet records a call or a meeting on your Mac and writes a transcript that shows who said what. No bot joins your call. The audio stays on your Mac, and the transcript is written on your Mac.

EnviousMeet is in Beta. It shows a **Beta** tag in the sidebar.

### Set up EnviousMeet

Open EnviousWispr and click **EnviousMeet** in the sidebar. The first time, the page walks you through a short setup. If you quit in the middle, setup starts again from the beginning next time.

1. **Get Started.** The first screen says what EnviousMeet does. Click **Get Started**.
2. **Good meetings start with a heads-up.** Read the consent text, tick **Got it. I'll get consent where the law needs it.**, and click **Let's go**. The button stays off until the box is ticked.
3. **Permissions.** Allow **Microphone** and, on macOS 14.2 or later, **Call sound** to continue. macOS may ask about call sound during your first recording. **Calendar** is optional and has **Not now**. Below macOS 14.2, call sound is not available, and only your microphone is recorded.
4. **You're all set!** Click **Open EnviousMeet**. If something is still off, the screen lists it under "Not allowed yet".

Finishing setup also starts the **Speaker labels** download, which live speaker labels use (see below).

### What you agree to before you record

This is the text on the consent screen. The same text is on the EnviousMeet page.

> Recording laws differ by place. In some places, everyone in a call or a room must agree before you record. You are responsible for telling people and getting their consent where the law requires it. Envious Labs is not responsible for recordings you make without consent. Check the laws that apply to you and to the people you record.

### What each permission is for

| Permission | What it is for |
| --- | --- |
| **Microphone** | To hear your voice. EnviousMeet cannot record without it. |
| **Call sound** | To hear the other people on a call, also with AirPods. Only the sound your Mac plays is recorded, never your screen. Needs macOS 14.2 or later. |
| **Calendar** | To name each meeting after its calendar event and save who was invited. If you say no, meetings are named from the summary, or by the call app and the date. |

### Turn a permission on later

Each permission has its own row on the **Permissions** tab of the EnviousMeet page.

- **Microphone.** Click **Allow Microphone**. If you said no before, it opens System Settings. The row says **Allowed** when it worked.
- **Call sound.** If you said no to macOS, click **Open System Settings** and allow EnviousWispr under **Privacy & Security > Screen & System Audio Recording**. macOS can only answer during a recording, so the row always reminds you of this. You know it worked when the menu says **Recording the call sound** while a meeting records.
- **Calendar.** If the row says "Not asked yet", turn on **Name meetings from my calendar** on the **General** tab, and macOS asks. If you said no to macOS, click **Open System Settings** and allow EnviousWispr under **Privacy & Security > Calendars**. The row says **Allowed** when it worked.

To record only your microphone, turn on **Record only my voice** on the **General** tab.

### Record a meeting

**Start.** Click the EnviousWispr icon in your menu bar and choose **Start Meeting Recording**. You can also open **History**, choose **M** for Meetings, and click **Record a meeting**. While a meeting records, a rainbow wave moves across the lips in the menu bar. With Reduce Motion on, the lips show the colours without moving.

**While it records.** The menu shows what is being recorded: **Recording the call sound**, **Recording your microphone only**, or **Call sound not recorded**. In History, the recording meeting shows its live words and a **Stop Recording** button.

**Dictating during a meeting.** You can keep dictating while EnviousMeet records, unless **Turn off dictation during meetings** is on. While a summary runs on the same local engine as your AI Polish, a dictation may skip AI Polish and paste the cleaned text instead. An EG-1 summary can also make S1-mini dictation skip AI Polish.

**Turn off dictation during meetings.** This switch is on the **General** tab, and it is off at first. When it is on, the dictation key records nothing while a meeting records, and a short note says **Dictation is off during meetings.** A dictation that started before the meeting finishes normally. After you stop the meeting, dictation works again once the meeting is saved.

**Stop.** Choose **Stop Meeting Recording** in the menu, or click **Stop Recording** in History. The menu shows **Saving Meeting Recording** while it finishes.

EnviousMeet can also offer to record when a call starts. See [EnviousMeet: When a Call Starts](/help/enviousmeet-when-a-call-starts/).

### Leave your voice out while you are muted

**Leave my voice out when I'm muted** is on the **General** tab, and it is on at first. It follows your mute button in the Zoom app, the Microsoft Teams app, and Google Meet in Chrome or Safari. It needs Accessibility, the same permission EnviousMeet uses to notice calls.

While the call app shows you muted, your microphone is left out of the meeting's recording, live words, transcript and summary. The other people on the call are still recorded. It never mutes you in the call, and it never turns off your Mac's microphone or dictation. A few seconds around a mute change may be kept or left out.

While a meeting records, the page tells you what is happening:

- **You're muted in Zoom. Your voice is left out of the notes.** (with your call app's name)
- **Checking your mute button. Your voice is being recorded.**
- **EnviousMeet can't see your mute button, so your voice is being recorded.**

### See live words while a meeting records

Live words show what is said into your microphone and in the call while a meeting records. They are a preview: the full transcript is written after the meeting and does not depend on them.

On the **Models** tab of the EnviousMeet page, choose the engine under **Live Preview** and its language under **Live Preview language**.

| Engine | What it needs |
| --- | --- |
| **Apple** | This Mac's own speech recognition. Needs macOS 26 and a download for each language. |
| **Universal** | Works on any Mac that runs EnviousWispr. Needs one download. |

**Download.** Choosing Universal starts its download. During a meeting, the download waits until the meeting is recorded and transcribed. Apple language downloads are unavailable until recording and transcription finish; start the download then. Downloads already running continue. If Universal is not downloaded yet, an installed Apple language can show live words meanwhile. Until live words are ready, a meeting records without them.

**Live speaker labels.** With live words and call sound working, and the **Speaker labels** download ready (its card is on the **Models** tab), call words first show under **Speaker**. Words the speaker model can assign move into numbered blocks such as **Speaker 1** and **Speaker 2**, and show names from supported call apps when there is enough evidence. Words it cannot assign stay under **Speaker**, and similar or overlapping voices can share a label. Your microphone is labeled **You**. A Speaker labels download that finishes during a meeting is used from the next meeting.

### Choose the transcript engine and language

On the **Models** tab, **Transcript engine** offers Parakeet and, once downloaded, Whisper Large v3 Turbo. Parakeet is shared with dictation, and dictation goes first. The transcript language row sets the language of the full transcript. With **Auto**, no language is set. A change applies to the next meeting and to a new **Transcribe again**.

### My transcript shows repeated lines

**With headphones,** your microphone hears only you, and the other people come from the call sound. **Without headphones,** your microphone also picks up the call. When call sound is recorded, EnviousMeet reduces that echo in the microphone audio. If it has to use the original microphone audio instead, it may hide repeated passages as probable echo. When passages were hidden, the finished meeting has a **Show probable echo** switch to show them again.

### What you get after a meeting

Your meetings are in **History** under **M**, for Meetings. On the EnviousMeet page, **Show recordings** takes you there.

- **Transcript.** The transcript with who said what is written when you stop. When the call sound has speech in it, everything your microphone hears is marked **You**, with or without headphones. Someone in the room with you is also marked **You**, because the microphone does not split voices during a call. The people on the call get numbered speaker labels, or names from supported call apps (the Zoom app, the Teams app, Google Meet, and Teams and Zoom on the web) when EnviousMeet has enough evidence. If the voices in the call sound cannot be told apart, their words are marked **Call**. When the call sound has no transcribed speech, such as an in-person meeting recorded on the microphone, voices the app can tell apart get numbered speaker labels.
- **Notes.** Type your own notes on the **Notes** tab.
- **Summary.** When automatic summaries are on, your EnviousMeet summary engine writes one on the meeting's **Summary** tab.
- **If a change cannot be saved.** History says **Your notes could not be saved.** or **Your summary changes could not be saved.** Click **Try again**. Your typing stays in the app until a save works.
- **Audio.** Each recording keeps its audio until you delete it. **Delete audio** removes only the audio and keeps the transcript. **Delete meeting** removes everything.
- **Transcribe again** writes the transcript again from the kept audio, with any ready transcript engine. Your current transcript stays until the new one is ready.

### How meetings are named

A new meeting gets its name in this order:

1. **Your calendar.** With **Name meetings from my calendar** on, EnviousMeet uses the title of the calendar event at the time the meeting starts, allowing up to 10 minutes before or after the event's times. It skips all-day events. If it cannot tell which event it is, the meeting does not take a calendar name.
2. **The summary.** With summaries on, the summary writer suggests a short title when the meeting has no name yet.
3. **The call app and the date,** such as "Zoom call" and the date. A meeting without a call app is named "Meeting" and the date.

You can rename any meeting in History.

The calendar is only read, never changed. EnviousMeet reads the matching calendar event on your Mac and saves its title, start and end times, and invited people with the meeting, shown as an **Invited** line. macOS asks for full calendar access because that is the only way to read titles. The calendar never makes EnviousMeet start or offer to record.

### Get a meeting summary, and where the text goes

Choose the engine under **Summary engine** on the **Summaries** tab of the EnviousMeet page. It is separate from dictation's AI Polish. With **Write a summary when a meeting ends** on, that engine writes a summary from the transcript and your notes. In History, for a meeting with transcript text, you can also click **Write summary**, or **Write again** to replace a summary. Replacing a summary you edited asks you first. Without a summary engine, no summary is written.

| Summary engine | Where the transcript, notes and meeting details go |
| --- | --- |
| EG-1 | Stay on your Mac. |
| Apple Intelligence (macOS 26) | Stay on your Mac. |
| Ollama, a model on this Mac | Stay on your Mac. |
| Ollama, a hosted model | Sent to Ollama's servers. |
| OpenAI, Gemini or Claude | Sent to that provider under your own key. Needs a saved key and a chosen model. |

The meeting details a summary uses are the start time, recorded length, call app, and, when available, the calendar event's title and invited people.

**Long meetings with Apple Intelligence.** Apple Intelligence can read only part of a long meeting at once, so it writes the summary in parts. When that happens, and while Apple Intelligence is still your summary engine, the **Summary** tab says **Long meeting: this summary was written in parts.** and adds that some cloud models can fit longer meetings in one piece. Click **Open Summaries settings** to choose another summary engine. This does not change dictation's AI Polish.

Summaries with Ollama need Ollama 0.12.6 or later. Turning summaries off does not stop a summary that has already started.

### What stays on your Mac

Meeting audio, transcripts, notes and calendar details are stored on your Mac. Only a cloud summary engine you chose receives the transcript, notes and meeting details, as the summary table shows. Anonymous usage data, which you can turn off in **App Settings** > **Privacy**, tells Envious Labs things like how long a meeting was, how many speakers it had, which call app a call offer was about and how you answered. It never includes audio, words, people's names or calendar events. See [What Data Is Collected](/help/what-data-is-collected/).
