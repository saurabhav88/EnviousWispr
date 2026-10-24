---
title: "EnviousMeet: When a Call Starts"
description: "EnviousMeet can ask to record when Zoom, Teams, FaceTime, Slack or a meeting in your browser starts using your microphone, and stop when the call ends."
category: "features"
section: "EnviousMeet"
order: 11
keywords: ["record this call", "call detection", "auto record meetings", "start recording automatically", "enviousmeet asks to record", "meeting ending in", "keep recording", "recording stopped", "start a new recording", "zoom", "microsoft teams", "facetime", "slack huddle", "google meet", "webex", "turn off call prompts", "didn't ask to record", "stopped recording by itself"]
related: ["enviousmeet-record-a-meeting", "accessibility-permission-not-working", "granting-permissions-microphone-accessibility-and-automation"]
updated: 2026-10-24
deflection: "show_but_always_send"
---
When a call app starts using your microphone in a real call, EnviousMeet can show a small panel under the menu bar that asks **Record this call?** The panel never takes the focus from your call. EnviousMeet asks macOS to leave it out of screen sharing, but macOS does not promise that on every version.

### Choose what happens when a call starts

On the **General** tab of the EnviousMeet page, **When a call starts** has three choices.

| Choice | What happens |
| --- | --- |
| **Ask** | The panel asks **Record this call?** with **Yes** and **No**. |
| **Start by itself** | A recording starts without asking. A new call during a recording still asks before it switches. |
| **Off** | EnviousMeet never notices calls. You can still start recordings from the menu bar. |

Noticing calls needs macOS 14.2 or later, and setup on the EnviousMeet page must be finished. It also needs Accessibility: the EnviousMeet page says **Allowed. EnviousMeet can notice when a call starts.** when it is on. If it says **Not allowed**, click **Allow Accessibility**. See [Accessibility permission not working](/help/accessibility-permission-not-working/) if the switch does not stick.

### Which apps and websites it notices

**Apps:** Zoom, Microsoft Teams, FaceTime, Webex, Slack, Dialpad Meetings, Gather, Lark and VooV Meeting. Zoom counts only while its meeting or webinar window is open, and Slack only while a huddle window is open, because both apps also use the microphone outside calls.

**In a browser:** Google Meet, Zoom, Microsoft Teams, Webex, Whereby, Jitsi and Slack huddles, in Chrome, Safari, Arc, Dia, Edge, Brave, Opera, Vivaldi, Zen, Comet and ChatGPT Atlas. The meeting page must be the tab you are on when the call starts.

Firefox, Discord and WhatsApp are not on the list yet.

### Stop being asked about one app

On the **Call Apps** tab, under **Notice calls in**, switch off any app you never want to be asked about. The list shows the call apps installed on your Mac, plus **Meetings in a browser**, which covers every browser at once. The switches are greyed out while **When a call starts** is **Off**.

### What the call panel's buttons do

- **Record this call?** with a line such as "Zoom started using the microphone." Click **Yes** to record or **No** to skip this call. If you do neither, the panel closes after 15 seconds; that is not counted as a No, and you are not asked again about the same call.
- **New call in Zoom. Start a new recording?** (with the app's name) A new call started while a meeting records. **Yes** stops the current recording and starts one for the new call. If EnviousMeet knows before stopping that the new recording cannot start, such as a missing permission, the current recording keeps going and the panel says so. If the new recording fails after the stop, the panel says **EnviousMeet could not start recording**. If the new call cannot be confirmed after the stop, the panel says **Recording stopped** with "The new call could not be confirmed." and offers **Start a new recording**.
- **Meeting ending in 10 seconds** counts down when the call you were recording has ended. Click **Keep recording** to keep going; otherwise the recording stops when the count reaches zero.
- **Recording stopped** means the recording ended with the call. **Start a new recording** stays on the panel for one minute and starts a new, separate meeting. **Close** closes the panel.
- **EnviousMeet needs your attention before it can record** means a permission or the call-sound step must be done first. Click **Open settings**, or **Close**.
- **EnviousMeet could not start recording** comes with "Open EnviousMeet to see why." For example, the disk is almost full. Click **Open settings** to see the reason, or **Close**.

### When a recording stops by itself

Only a recording that EnviousMeet started for a call stops because the call ended. It stops after the countdown, once the call app has stopped using the microphone. A short drop, a reconnect, or a moment the app cannot check does not stop it. The end of a call never stops a recording you started yourself from the menu bar or from History, or one you chose to keep with **Keep recording**. Any recording can still stop if the disk fills up or the recording fails.

For 10 seconds after your Mac wakes from sleep, EnviousMeet does not start or end any call.

### Why do I see a tip after No?

A No lasts for that call: you are not asked again until it ends. After your first No ever, a tip tells you that you can turn off call prompts for some apps. After your third No for one app, a last reminder names it. All meetings in a browser share one count, and the reminder names **Meetings in a browser**. Both tips have **Open settings** and **Close**, and close by themselves after 15 seconds. EnviousMeet never turns an app off by itself.

### What EnviousMeet looks at

To tell a call from other microphone use, EnviousMeet checks which app holds the microphone, the title of its window, and, in a browser, the address of the tab you are on. Window titles and page addresses are checked on your Mac and never stored or sent. EnviousMeet keeps which app a call was in, to name the meeting, and its anonymous usage data includes that app's name and your answer. Your calendar is never used to notice calls; it is only used to name meetings.

### It did not ask to record

- **The app or browser is switched off** under **Notice calls in** on the **Call Apps** tab, or **When a call starts** is **Off**.
- **Accessibility is not allowed.** Without it, EnviousMeet cannot tell a call from other microphone use, so it never asks.
- **The meeting was in a background tab.** A browser does not say which tab uses the microphone, so the meeting page must be the tab you are on when the call starts.
- **You were dictating.** **Record this call?** waits until the dictation ends. A question about switching from a meeting that is already recording can still appear.
- **You said No earlier in the same call.**

You can always start the recording yourself from the menu bar with **Start Meeting Recording**.

### It stopped while I was still in the call

If the call app lets go of the microphone while you are on mute, it can look like the call ended. When **Meeting ending in 10 seconds** appears, click **Keep recording**. The end of the call then no longer stops the recording; you stop it yourself.
