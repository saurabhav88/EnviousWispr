---
title: "Privacy on Android"
description: "What stays on your phone with EnviousWispr for Android, what goes to a cloud provider if you choose one, and what usage and crash reports contain."
category: "android"
section: "Using EnviousWispr on Android"
order: 9
keywords: ["android privacy", "does my voice leave my phone", "audio uploaded android", "android usage reports", "android crash reports", "cloud polish privacy android", "feedback android"]
related: ["android-ai-polish", "android-accessibility-access"]
updated: 2026-10-28
deflection: "never_intervene"
---
Your voice stays on your phone. EnviousWispr for Android transcribes your speech on the phone, and audio never leaves it. You can read the same explanation in the app under Settings, then **Privacy**.

### What stays on your phone

Your audio, your dictated words and your History stay on the phone. With AI polish set to **Off** or **This phone**, the polish step happens on the phone too.

### What goes to a cloud provider

If you choose **Cloud** polish with your own key, the selected text and your custom words go directly to that provider (OpenAI, Gemini or Claude). They do not pass through Envious Labs. Your audio still stays on the phone.

### What usage and crash reports contain

EnviousWispr sends limited usage and crash reports to PostHog (usage) and Sentry (crashes) so problems can be found and fixed. They include whether a dictation finished, how long each step took, which settings are on and which app the words went to.

They never include audio, your dictated words, names you enter, file contents or API keys. A random ID tells one install from another; it is not an account. PostHog may work out an approximate city or region from the connection, but EnviousWispr never reads your phone's location.

### Feedback you choose to send

**Send feedback** (the bug icon at the top of the app) sends only the message you write and an optional reply email to Envious Labs through Sentry. You can include technical diagnostics and preview them first. No audio or dictated words are attached.

Read the full [privacy policy](/privacy-policy/).
