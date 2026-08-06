---
title: "When the App or Speech Engine Stops"
description: "What happens if the app or the speech engine stops, and what is saved."
category: "troubleshooting"
section: "Recording Issues"
order: 8
keywords: ["crash", "crashes", "quits", "closes by itself", "keeps crashing", "stopped working", "disappeared", "not responding"]
updated: 2026-08-05
---
EnviousWispr is a free dictation app for macOS. The part of it that turns speech into text runs separately from the rest of the app, so the two can stop on their own without taking the other down.

### If the speech engine stops

EnviousWispr keeps running and starts the engine again on your next recording. There is nothing for you to do.

### If the app itself quits

Open it again from your Applications folder. Your History is written to disk as you go, so past dictations are still there.

### The dictation you were in the middle of

While you dictate, EnviousWispr keeps a protected copy of the recording and deletes it once your text is safely saved. If the app quits before that happens, EnviousWispr makes one attempt to recover those words the next time it starts.

### Crash reports

Crashes are reported to Envious Labs automatically so they can be fixed. A report describes what the app was doing, never what you said. No audio and no transcripts are ever included.
