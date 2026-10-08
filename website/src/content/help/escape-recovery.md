---
title: "Escape Recovery"
description: "Get back a recording you cancelled by mistake: Escape Recovery keeps it for 24 hours instead of throwing it away."
category: "recording-and-keybinds"
section: "Recording"
order: 6
keywords: ["escape recovery", "cancelled by mistake", "i cancelled by accident", "get my dictation back", "undo cancel", "recover a cancelled recording", "keep a cancelled recording", "pressed escape by mistake", "lost what i said", "accidental cancel", "dictation cancelled", "undo button", "deleted in 23h", "cancelled recording disappeared"]
related: ["canceling-a-recording", "transcript-history"]
updated: 2026-10-04
deflection: "can_resolve"
---
Escape Recovery keeps a recording when you cancel it with your cancel keybind, instead of throwing it away. It is on from the start. If you cancelled by mistake, press **Undo** on the **Dictation cancelled** notice, or find the text in your History.

### I cancelled by mistake. How do I get my dictation back?

EnviousWispr shows a small **Dictation cancelled** notice with an **Undo** button. Press **Undo** and EnviousWispr tries to put your text back in the box you were dictating into.

If EnviousWispr cannot reach that box, you see **Copied. Press ⌘V to paste**: click where you want the text and press ⌘V. Undo cannot switch back to a browser tab you have left, so go back to that tab yourself, click the box and press ⌘V.

If you miss the notice, the text is waiting in **Settings** > **History** for 24 hours. Open the entry and press **Paste** to put it into the app you are in now.

### What happens when I cancel a recording

Your cancel keybind, Escape by default, still stops the recording. Instead of discarding it, EnviousWispr transcribes and polishes it the way it would any dictation, then holds the text rather than pasting it.

- **A new recording cannot start until it finishes**, the same as after any dictation. How long that takes depends on how much you said, which speech engine you use, and which AI polish you chose. No recording length is refused.
- **AI polish runs as usual.** If you picked a cloud provider and added your own key, that polish uses your key and counts towards your usage with that company, exactly as it does for a normal dictation.

In Push to Talk, three quick presses of your recording keybind cancel a hands-free recording. Escape Recovery treats that as your cancel keybind and keeps the recording too.

### Turn Escape Recovery on or off

1. Click the EnviousWispr icon in your menu bar and choose **Open EnviousWispr**.
2. Open **Keybinds**.
3. Find the **Escape Recovery** row, below **Cancel recording**, and switch it on or off.

With it off, your cancel keybind discards the recording the moment you press it.

A recording follows the setting as it stood when that recording started. Changing the switch applies from the next recording you begin, never to one already running. Anything already in History stays there until its countdown ends or you press **Keep**.

### Throw a recording away for good

Click **Cancel** in the main EnviousWispr window, next to **Stop** under the recording timer. The recording is discarded at once, whether or not Escape Recovery is on. The floating recording bar has no Cancel button. Only the cancel keybind keeps a recording.

### Change my mind while it is still working

Press your cancel keybind again **while the recording is still being transcribed** and the result is discarded when it arrives. Once the text moves on to AI polish, the keybind no longer discards it and the dictation is kept. Either way, a kept dictation is in History for 24 hours, and you can delete it there.

Pressing again never makes the work finish sooner. The recording still has to be processed before you can start a new one. A third press does nothing.

### How long a cancelled recording is kept

A kept dictation appears in **History** with a countdown badge that reads something like **Deleted in 23h**. It stays available for 24 hours. After that, EnviousWispr removes it while the app is running, or the next time you open the app. Nothing is deleted while EnviousWispr is closed, so an entry whose 24 hours ended while the app was closed is removed at the next launch.

While the countdown is going you have two choices in History.

- **Keep** makes the dictation permanent and stops the clock. The badge changes to **Kept**, and the entry then behaves like any other History entry.
- **Paste** puts the text into whatever app you are in now, which may not be the one you were dictating into.

Cancelled dictations are left out of search and out of your dictation counts until you press **Keep**.

### Where the audio and text go

The audio is deleted once the text is saved, exactly as it is after a normal dictation, and it never leaves your Mac. If you use a cloud provider for AI polish, the text is sent to that provider under your own key in the usual way. Envious Labs receives neither.
