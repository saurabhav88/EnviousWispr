---
title: "Escape Recovery"
description: "Keep a recording you cancelled by mistake instead of losing it."
category: "recording-and-keybinds"
section: "Recording"
order: 6
keywords: ["escape recovery", "cancelled by mistake", "i cancelled by accident", "get my dictation back", "undo cancel", "recover a cancelled recording", "keep a cancelled recording", "pressed escape by mistake", "lost what i said", "accidental cancel"]
related: ["canceling-a-recording", "transcript-history"]
updated: 2026-08-18
---
Cancelling a recording normally throws it away. If you have ever pressed your cancel keybind and wished a second later that you had not, Escape Recovery is the setting that changes that. It is off until you turn it on, and turning it off puts everything back exactly as it was.

A recording follows the setting as it stood when that recording started. Changing the toggle applies from the next recording you begin, never to one already running.

### Turning it on

1. **Open settings.** Click the EnviousWispr icon in your menu bar, choose **Settings**, and go to **Keybinds**.
2. **Find Cancel Recording.** It is the section below your recording keybind.
3. **Switch on Escape Recovery.**

### What changes when it is on

Your cancel keybind, Escape by default, still stops the recording. Instead of discarding it, EnviousWispr transcribes and polishes it the same way it would any dictation, then holds the text rather than pasting it.

A small **Transcript cancelled** notice appears with an **Undo** button. Press it and the text goes into the app you were dictating into. If you miss the notice, nothing is lost: the dictation is waiting in your History.

Two things follow from the recording being processed rather than thrown away.

- **A new recording cannot start until it finishes**, the same as after any dictation. How long that takes depends on how much you said, which speech engine you use, and which AI polish you chose. No recording length is refused.
- **AI polish runs as usual.** If you picked a cloud provider and added your own key, that polish uses your key and counts towards your usage with that company, exactly as it does for a normal dictation.

The triple press of your recording keybind, which cancels a hands-free session, counts as your cancel keybind here. It keeps the recording in the same way.

### The Cancel button still discards

Clicking **Cancel** in the recording bar throws the recording away immediately, whether or not Escape Recovery is on. Only the keybinds keep things. A button labelled Cancel should mean one thing, and your cancel key is also how people dismiss menus and back out of fields, which is the reason it is the one that recovers.

### Changing your mind while it is working

Press your cancel keybind again **while it is still being transcribed** and the result is discarded when it arrives. Once it moves on to AI polish the keybind stands down and the dictation is kept, so this is a window rather than something available for the whole wait. Nothing is lost either way: a kept dictation is in History for 24 hours, and you can delete it there.

Pressing again never makes the work finish sooner. The recording still has to be processed before you can start a new one. A third press does nothing, because you have already asked for the only thing there is to ask for.

### How long a kept dictation lasts

A kept dictation appears in History with a **Kept** badge and a countdown reading something like **Deleted in 23h**. It stays available for 24 hours. Once that window ends it stops being offered, and EnviousWispr removes it while the app is running, or the next time you launch it. Nothing is deleted while EnviousWispr is not running, so a dictation whose window ended while the app was closed is removed at the next launch rather than at the moment the clock ran out.

While the countdown is going you have two choices in History.

- **Keep** makes the dictation permanent and stops the clock. The Kept badge stays so you can still tell where it came from, but in every other way it behaves like any other History entry.
- **Paste** puts the text into whatever app you are in now, which may not be the one you were dictating into.

Kept dictations are left out of search and out of your dictation counts until you press Keep, so a recording you cancelled does not quietly become part of your record.

### Your audio and your text

The audio is deleted once the text is saved, exactly as it is after a normal dictation, and it never leaves your Mac. If you use a cloud provider for AI polish, the text is sent to that provider under your own key in the usual way. Envious Labs receives neither.

### Turning it off

Switch the toggle off in **Keybinds**. Recordings you start after that go straight back to being discarded the moment you press your cancel keybind. A recording already running keeps the rules it started with, and anything already sitting in History stays there until its countdown runs out, or until you press Keep.
