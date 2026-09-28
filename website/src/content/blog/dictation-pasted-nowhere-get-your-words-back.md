---
title: "Dictated With No Text Box Selected? How to Get Your Words Back on a Mac"
description: "Where a dictation goes when no text box was selected, and the two shortcuts that bring it back without saying it all again."
topic: tips-troubleshooting
pubDate: 2026-09-28
tags: ["dictation", "macos", "troubleshooting", "productivity"]
draft: false
author: "Saurabh Vaish"
keywords:
  - "dictation text disappeared mac"
  - "paste last dictation"
  - "dictation pasted in wrong window"
  - "mac dictation not typing"
  - "get dictation back mac"
faqs:
  - question: "Where did my dictation go if nothing appeared on screen?"
    answer: "In EnviousWispr, a free dictation app for Mac, a dictation that could not be delivered is left on your clipboard, and a notice reading Copied. Press ⌘V to paste appears. Click into a text box and press Command V. Every dictation is also kept in History on your Mac, so it is never lost."
  - question: "How do I paste my last dictation again?"
    answer: "Click where the text belongs and press Control Command V, or choose Paste Last Dictation from the EnviousWispr menu bar menu. Your newest dictation is pasted where your cursor is now. Control Command C copies it to the clipboard instead."
  - question: "Why did my dictation paste into a different window than the one I was looking at?"
    answer: "EnviousWispr sends your words to the window that was in front when you started recording, because AI polish can take a few seconds and you may click elsewhere while it works. If that window has closed, it does not paste into another one; it leaves the words on your clipboard."
  - question: "Does Paste Last Dictation need any permission?"
    answer: "Pasting into another app needs macOS Accessibility permission. Without it, the menu item opens the permission settings for you and the paste keys do nothing. Copy Last Dictation works either way."
---

You talk for a full minute, release the key, and nothing happens. The cursor was sitting on a sidebar, or the chat box had lost focus, or you had clicked away to check something while the words were being cleaned up. The thought was good, and now you are about to say it all again.

You do not have to. This post explains where a dictation goes when there was nowhere to put it, and how to bring it back with one shortcut. It uses EnviousWispr, a free dictation app for Mac, because that is what the shortcuts below belong to.

## The short answer

Click into the text box where the words belong, then press **Control Command V**. EnviousWispr pastes your most recent dictation right there. If you would rather paste it yourself, press **Control Command C** to copy it, then Command V wherever you like.

Both shortcuts can be changed in **Settings, Keybinds**, and the same paste is in the menu bar menu as **Paste Last Dictation**, with the start of the text shown underneath so you can check it is the right one before clicking.

## Why a dictation sometimes lands nowhere

When you start recording, EnviousWispr notes which app, window and text field are in front. It does this at the start, not the end, because cleaning up the text with AI polish can take a few seconds and you might click into something else while you wait. Your words go back to the place you started talking.

That covers most cases, but a few still leave the text with nowhere to go:

- **No text box was selected.** You pressed the key while looking at a web page or a file list, so there was nothing to type into.
- **The window closed.** You started in a chat window and closed it before the text was ready. EnviousWispr does not guess and paste into a different window instead.
- **The app refused the text.** Some apps block typed input. EnviousWispr tries three ways to deliver: writing into the text box directly, a normal paste, and the app's own Edit, Paste menu.

In each of those cases your words are put on the clipboard and a notice appears: **Copied. Press ⌘V to paste.** Nothing has been thrown away.

## Three ways to get the words back

**1. Paste Last Dictation.** Click where the text belongs and press Control Command V. This is the fastest route, and it works even if you have copied something else since.

**2. Paste from the clipboard.** If you saw the Copied notice and have not copied anything since, Command V works too.

**3. Open History.** EnviousWispr saves every dictation on your Mac in History. Click the EnviousWispr icon in your menu bar, choose **Settings**, go to **History**, find the dictation, and copy or paste it from there. History is also where a cancelled recording can be kept, which is covered in the [History feature page](/features/history/).

## Saying it once, using it twice

Paste Last Dictation is not only a rescue tool. If you dictated a status update into Slack and want the same words in an email, click into the email and press Control Command V. The newest dictation in History is pasted again.

A few details worth knowing:

- **Only real dictations count.** Imported file transcripts, deleted items and a cancelled dictation still counting down in History are skipped. When there is nothing to reuse, the menu item is greyed out.
- **Your clipboard is respected.** If **Restore clipboard after paste** is on, whatever you had copied before comes back after the paste.
- **Terminal has its own meaning for the keys.** In Terminal, Control Command V is normally Paste Escaped Text, and some apps, such as Final Cut Pro, use Control Command C. If you rely on those, pick other keys in Settings, Keybinds.

## If nothing pastes at all

Pasting into another app needs one macOS permission: **Accessibility**. Without it, EnviousWispr cannot type into other apps, the Paste Last Dictation menu item opens the permission settings for you, and the paste keys do nothing. Copying still works.

Open **System Settings, Privacy & Security, Accessibility**, find EnviousWispr, and make sure it is switched on. If it already looks on and nothing is typed, remove it with the minus button and add it again. The full checklist is in the help article [When your dictation does not paste](/help/paste-not-working/), and Apple explains the system side of dictation in its [guide to dictation on Mac](https://support.apple.com/guide/mac-help/use-dictation-mh40584/mac).

## The takeaway

A dictation that lands nowhere is not lost. It is on your clipboard, in your History, and one shortcut away. Click where it belongs and press Control Command V.

If you want to see the feature on its own page, the [Paste Last Dictation page](/features/paste-last-dictation/) shows both shortcuts, and [How Text Gets Pasted Into Your App](/help/how-text-gets-pasted-into-your-app/) explains where every dictation is delivered and why.
