---
title: "EnviousMeet: Record a Meeting"
description: "Record a call or an in-person meeting on your Mac and get a transcript with who said what, plus notes and an optional summary."
category: "features"
section: "EnviousMeet"
order: 10
keywords: ["enviousmeet", "record a meeting", "meeting recorder", "record a call", "zoom transcript", "google meet transcript", "teams transcript", "meeting notes", "who said what", "speaker labels", "meeting summary", "call sound", "system audio", "record without a bot", "consent", "calendar meeting names", "meeting audio", "probable echo"]
related: ["enviousmeet-when-a-call-starts", "transcript-history", "transcribe-a-file-speaker-labels", "choosing-an-ai-provider-none-apple-intelligence-ollama-openai-gemini", "privacy-overview"]
updated: 2026-10-24
deflection: "show_but_always_send"
---
EnviousMeet records a call or a meeting on your Mac and writes a transcript that shows who said what. No bot joins your call. The audio stays on your Mac, and the transcript is written on your Mac.

### Set up EnviousMeet

Open EnviousWispr and click **EnviousMeet** in the sidebar. The first time, the page walks you through a short setup. If you quit in the middle, setup starts again from the beginning next time.

1. **Get Started.** The first screen says what EnviousMeet does. Click **Get Started**.
2. **Before you record.** Read the consent text, tick **I understand. I will get consent where the law requires it.**, and click **Accept and continue**. The button stays off until the box is ticked.
3. **Three quick permissions.** Each row has **Allow**. Call sound and Calendar also have **Not now**. You can say no to any of them and turn it on later. Click **Continue** whatever you chose.
4. **You're all set!** Click **Open EnviousMeet**. If something is still off, the screen lists it under "Not allowed yet".

### What you agree to before you record

This is the text on the consent screen. The same text is on the EnviousMeet page.

> Recording laws differ by place. In some places, everyone in a call or a room must agree before you record. You are responsible for telling people and getting their consent where the law requires it. Envious Labs is not responsible for recordings you make without consent. Check the laws that apply to you and to the people you record.

### What each permission is for

| Permission | What it is for | If you say no |
| --- | --- | --- |
| **Microphone** | To hear your voice. | EnviousMeet cannot record. |
| **Call sound** | To hear the other people on a call, also with AirPods. Only the sound your Mac plays is recorded, never your screen. | Only your microphone is recorded. |
| **Calendar** | To name each meeting after its calendar event. | Meetings are named from the summary, or by the call app and the date. |

### Turn a permission on later

Each permission has its own row on the **Permissions** tab of the EnviousMeet page.

- **Microphone.** Click **Allow Microphone**. If you said no before, it opens System Settings. The row says **Allowed** when it worked.
- **Call sound.** If you clicked **Not now** during setup, turn off **Record only my voice** on the **General** tab. If you said no to macOS, click **Open System Settings** and allow EnviousWispr under **Privacy & Security > Screen & System Audio Recording**. macOS can only answer during a recording, so the row always reminds you of this. You know it worked when the menu says **Recording the call sound** while a meeting records.
- **Calendar.** If the row says "Not asked yet", turn on **Name meetings from my calendar** on the **General** tab, and macOS asks. If you said no to macOS, click **Open System Settings** and allow EnviousWispr under **Privacy & Security > Calendars**. The row says **Allowed** when it worked.

### Record a meeting

**Start.** Click the EnviousWispr icon in your menu bar and choose **Start Meeting Recording**. You can also click **Start Recording** in History. The lips in the menu bar glow while a meeting records.

**While it records.** The menu shows what is being recorded: **Recording the call sound**, **Recording your microphone only**, or **Call sound not recorded**. In History, the recording meeting shows its live words and a **Stop Recording** button. You can keep dictating while EnviousMeet records; meeting work waits while you dictate, so your dictation never slows down.

**Stop.** Choose **Stop Meeting Recording** in the menu, or click **Stop Recording** in History. The menu shows **Saving Meeting Recording** while it finishes.

EnviousMeet can also ask to record when a call starts. See [EnviousMeet: When a Call Starts](/help/enviousmeet-when-a-call-starts/).

### Recording the call sound

EnviousMeet records what your Mac plays, such as the other people on a call, unless **Record only my voice** is on (on the **General** tab). Recording the call sound needs macOS 14.2 or later; on an older Mac, only your microphone is recorded. It works with any headphones. The choice applies to the next meeting you start.

The first time you record the call sound, EnviousWispr explains that macOS will ask for permission. Click **Continue**, then answer the macOS question. **Cancel** starts nothing.

### My transcript shows repeated lines, or none

**With headphones,** your microphone hears only you, and the other people come from the call sound. **Without headphones,** your microphone also picks up the call, so some lines are heard twice. EnviousMeet hides those repeated lines as probable echo. When lines were hidden, the finished meeting has a **Show probable echo** switch to show them again.

### What you get after a meeting

Your recordings are in **History**, under **Recordings**. On the EnviousMeet page, **Show recordings** takes you there.

- **Live words.** While a meeting records, its words appear about a minute behind, marked **You** or **Call**.
- **Transcript.** The transcript with who said what is written when you stop. Your voice is marked **You** when the call sound has speech in it and the microphone heard one voice that is mostly not echo. Other voices are **Speaker 1**, **Speaker 2** and so on, in the order they first speak. If the voices in the call sound cannot be told apart, their words are marked **Call**. In an in-person meeting recorded on the microphone alone, everyone is a numbered speaker.
- **Notes.** Type your own notes on the **Notes** tab.
- **Summary.** When summaries are on, your AI Polish provider writes one after the meeting, on the **Summary** tab.
- **Audio.** Each recording keeps its audio until you delete it. **Delete audio** removes only the audio and keeps the transcript. **Delete meeting** removes everything. **Transcribe again** writes the transcript again from the kept audio.

### How meetings are named

A new meeting gets its name in this order:

1. **Your calendar.** With **Name meetings from my calendar** on, EnviousMeet uses the title of the calendar event at the time the meeting starts, allowing up to 10 minutes before or after the event's times. It skips all-day events. If it cannot tell which event it is, the meeting does not take a calendar name.
2. **The summary.** With summaries on, the summary writer suggests a short title when the meeting has no name yet.
3. **The call app and the date,** such as "Zoom call" and the date. A meeting without a call app is named "Meeting" and the date.

You can rename any meeting in History.

The calendar is only read, never changed. EnviousMeet reads event titles, times and meeting links, on your Mac. macOS asks for full calendar access because that is the only way to read titles. The calendar never makes EnviousMeet start or ask to record.

### Get a meeting summary, and where the text goes

With **Write a summary when a meeting ends** on, your AI Polish provider writes a summary from the transcript and your notes. In History you can also click **Write summary** for any meeting that has a transcript, or **Write again** to replace one.

| Provider | Where the transcript and notes go |
| --- | --- |
| Apple Intelligence (macOS 26) | Stay on your Mac. |
| Ollama, a model on this Mac | Stay on your Mac. |
| Ollama, a hosted model | Sent to Ollama's servers. |
| OpenAI, Gemini or Claude | Sent to that provider under your own key. |

Summaries with Ollama need Ollama 0.12.6 or later. If no AI Polish provider is chosen, no summary is written. The EnviousMeet page says when the selected model can't write summaries; click **Open AI Polish settings** to pick another one. Turning summaries off does not stop a summary that has already started.

### What stays on your Mac

Meeting audio, transcripts and notes are stored on your Mac. Only a cloud summary provider you chose receives the transcript and notes, as the summary table shows. Anonymous usage data, which you can turn off in **App Settings** > **Privacy**, tells Envious Labs things like how long a meeting was, how many speakers it had, which call app a call question was about and how you answered. It never includes audio, words, people's names or calendar events. See [What Data Is Collected](/help/what-data-is-collected/).
