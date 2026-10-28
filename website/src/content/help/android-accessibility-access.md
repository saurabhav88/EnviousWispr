---
title: "Accessibility Access on Android"
description: "Why EnviousWispr asks for Android's Accessibility access, how to turn it on, and how to fix auto-paste when it switches off."
category: "android"
section: "Getting Started on Android"
order: 2
keywords: ["android accessibility", "accessibility permission android", "auto-paste switched off", "auto-paste not connected", "accessibility shortcut", "turn on accessibility android", "installed apps", "downloaded apps"]
related: ["android-setup", "android-text-did-not-land", "android-bubble-not-showing"]
updated: 2026-10-28
deflection: "never_intervene"
---
EnviousWispr uses Android's Accessibility access to find the text box you are using, show the floating bubble beside it, and paste your words after you start a dictation. Without it, there is no bubble, and your words go to the clipboard or History instead of straight into the app.

### What the access is used for

With Accessibility access on, EnviousWispr reads the text box's text, the cursor position and which app you are in, so it can put your words in the right place and check that they appeared. Field text and cursor position are processed on your phone, and field contents are not sent to Envious Labs.

Usage reports can include which app you were typing in, whether your text was inserted, and how long that took. EnviousWispr only inserts text after you start a dictation, and it does not operate your phone on its own. It is a general dictation app.

### Turn it on

EnviousWispr shows a consent screen first. Tap **Agree**, then follow the guide it shows.

1. **Open Settings.** Tap **Open Settings** in the guide.
2. **Find EnviousWispr.** On a Samsung phone, tap **Installed apps**, then **EnviousWispr**. On other phones, find EnviousWispr in Accessibility; your phone may list it under **Downloaded apps** or **Installed services**.
3. **Turn on the service.** Switch it on, review the access Android describes, then tap **Allow**.
4. **Leave the shortcut off.** Android also offers an EnviousWispr shortcut. Leave that one off: tapping its floating button switches auto-paste off.
5. **Come back.** Return to EnviousWispr. If it does not reopen, open it from Recents or its app icon.

The permission shows as **Granted** when it worked.

### Auto-paste was switched off

If the **Permissions** page in Settings says **Auto-paste was switched off**, Android turned the EnviousWispr service off. This can happen when the app is stopped, or when the EnviousWispr accessibility shortcut is used. If the shortcut is on, the page says so.

**Turn the shortcut off and the service back on.** Tap **Accessibility settings**, turn off the EnviousWispr shortcut, and switch the EnviousWispr service back on.

### Auto-paste is not connected

If the page says **Auto-paste is not connected**, the service is on but not responding. Tap **Accessibility settings**, turn EnviousWispr off, then turn it on again.

### Turn the access off

You can turn this access off at any time in Android Settings, under Accessibility. EnviousWispr keeps working without it, but your finished words go to the clipboard or History instead of into the app.
