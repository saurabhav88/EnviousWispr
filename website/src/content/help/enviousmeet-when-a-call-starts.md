---
title: "EnviousMeet: When a Call Starts"
description: "EnviousMeet can offer to record when Zoom, Teams, FaceTime, Slack or a meeting in your browser starts using your microphone, and stop when the call ends."
category: "features"
section: "EnviousMeet"
order: 11
keywords: ["take notes on this call", "call detection", "auto record meetings", "start recording automatically", "enviousmeet asks to record", "recording stops in", "keep recording", "end recording", "still in a meeting", "meeting recorded", "your notes are ready", "zoom", "microsoft teams", "facetime", "slack huddle", "google meet", "webex", "turn off call prompts", "didn't ask to record", "stopped recording by itself"]
related: ["enviousmeet-record-a-meeting", "accessibility-permission-not-working", "granting-permissions-microphone-accessibility-and-automation"]
updated: 2026-11-05
deflection: "show_but_always_send"
---
When a call app starts using your microphone in a real call, EnviousMeet can show a small card under the menu bar that offers to take notes, such as **Take notes on this Zoom call?** with your call app's name. For Slack it says **Take notes on this Slack huddle?**. The card never takes the focus from your call. EnviousMeet asks macOS to leave it out of screen sharing, but macOS does not promise that on every version.

### Choose what happens when a call starts

On the **General** tab of the EnviousMeet page, **When a call starts** has three choices.

| Choice | What happens |
| --- | --- |
| **Ask** | The card offers to record, with **Start recording** and **Not now**. |
| **Start by itself** | A recording starts without asking. A new call during a recording still asks before it switches. |
| **Off** | EnviousMeet never notices calls. You can still start recordings from the menu bar or History. |

Noticing calls needs macOS 14.2 or later, and setup on the EnviousMeet page must be finished. It also needs Accessibility: the EnviousMeet page says **Allowed. EnviousMeet can notice when a call starts.** when it is on. If it says **Not allowed**, click **Allow Accessibility**. See [Accessibility permission not working](/help/accessibility-permission-not-working/) if the switch does not stick.

### Which apps and websites it notices

**Apps:** Zoom, Microsoft Teams, FaceTime, Webex, Slack, Dialpad Meetings, Gather, Lark and VooV Meeting. Zoom counts only while its meeting or webinar window is open, and Slack only while a huddle window is open, because both apps also use the microphone outside calls.

The Microsoft Teams app also uses the microphone for its sound test before you join a call. With **Ask**, that test can show the card, and you can click **Not now**. With **Start by itself**, the Teams app starts a recording only once you are in the call, so the sound test never starts one.

**In a browser:** Google Meet, Zoom, Microsoft Teams, Webex, Whereby, Jitsi and Slack huddles, in Chrome, Safari, Arc, Dia, Edge, Brave, Opera, Vivaldi, Zen, Comet and ChatGPT Atlas. The meeting page must be the tab you are on when the call starts.

Firefox, Discord and WhatsApp are not on the list yet.

### Stop being asked about one app

On the **Call Apps** tab, under **Notice calls in**, switch off any app you never want to be asked about. The list shows the call apps installed on your Mac, plus **Meetings in a browser**, which covers every browser at once. The switches are greyed out while **When a call starts** is **Off**.

### What the call card shows

- **Take notes on this Zoom call?** Click **Start recording** to record or **Not now** to skip. An offer you do not answer closes after two minutes. If the call app later starts using the microphone again, EnviousMeet can offer again after a short pause.
- **New Zoom call. Take notes on it instead?** A new call started while a meeting records. **Start recording** stops the current recording and starts one for the new call. If EnviousMeet knows before stopping that the new recording cannot start, such as a missing permission, the current recording keeps going and the card says so. If the new call cannot be confirmed after the stop, the card says **Couldn't confirm the new Zoom call** and offers **Start recording** or **Not now**.
- **Recording stops in 10 seconds** counts down when the call you were recording has ended. Click **Keep recording** to keep going, or **End recording** to stop now.
- **Meeting recorded**, then **Writing your notes…**, then **Your notes are ready** with **Open**, which opens the meeting in History.
- **Still in a meeting?** With call detection on, after some words have appeared and then 10 quiet minutes with live words working, the card gives you 30 seconds before the recording stops. New words cancel it. Choose **Keep recording** or **End recording**. Closing a countdown card only hides it; the countdown goes on.
- **EnviousMeet needs your attention before it can record** means a permission or the call-sound step must be done first. Click **Open settings**.
- **EnviousMeet could not start recording** comes with "Open EnviousMeet to see why." For example, the disk is almost full. Click **Open settings** to see the reason.

### When a recording stops by itself

A recording stops because the call ended only after the **Recording stops in 10 seconds** countdown. The countdown starts when EnviousMeet is sure the call ended, such as when the call app's meeting window closes or it stops using the microphone. For a meeting in a browser, EnviousMeet may ask **Did your call end?** instead and keeps recording until you choose. A short drop, a reconnect, or a moment the app cannot check does not stop it. A recording you start yourself from the menu bar or History during a call can link to that call, and then it can also stop after the countdown. Any recording can still stop if the disk fills up or the recording fails.

For 10 seconds after your Mac wakes from sleep, EnviousMeet does not start or end any call.

### Why do I see a tip after Not now?

**Not now** skips this offer. After your first one ever, a tip tells you that you can turn off call prompts for some apps. After the third **Not now** for one app, a last reminder names it. All meetings in a browser share one count. EnviousMeet never turns an app off by itself.

### What EnviousMeet looks at

To tell a call from other microphone use, EnviousMeet checks which app holds the microphone, the title of its window, and, in a browser, the address of the tab you are on. Window titles and page addresses are checked on your Mac and never stored or sent. EnviousMeet keeps which app a call was in, to name the meeting, and its anonymous usage data includes that app's name and your answer. Your calendar is never used to notice calls; it is only used to name meetings.

### It did not offer to record

- **The app or browser is switched off** under **Notice calls in** on the **Call Apps** tab, or **When a call starts** is **Off**.
- **Accessibility is not allowed.** Without it, EnviousMeet cannot tell a call from other microphone use, so it never asks.
- **The meeting was in a background tab.** A browser does not say which tab uses the microphone, so the meeting page must be the tab you are on when the call starts.
- **You were dictating.** The offer waits until the dictation ends. An offer to switch from a meeting that is already recording can still appear.
- **You clicked Not now a moment ago.** Another offer needs a new change in microphone use, at least two minutes after the last offer.

You can always start the recording yourself from the menu bar with **Start Meeting Recording**.

### It stopped while I was still in the call

If the call app lets go of the microphone while you are on mute, it can look like the call ended. When **Recording stops in 10 seconds** appears, click **Keep recording**. That cancels this countdown. Another countdown can appear later if the app starts using the microphone again and then lets go of it.
