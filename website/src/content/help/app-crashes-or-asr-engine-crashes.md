---
title: "When the App or Speech Engine Stops"
description: "What happens if the app or the speech engine stops, and what is saved."
category: "troubleshooting"
section: "Recording Issues"
order: 8
keywords: ["crash", "crashes", "quits", "closes by itself", "keeps crashing", "stopped working", "disappeared", "not responding"]
updated: 2026-08-05
---
Speech recognition runs separately from the app. If it fails, EnviousWispr keeps running and starts it again on your next recording. There is nothing for you to do.

### If the app itself quits

Open it again from Applications. Your History is saved to disk, so past dictations are still there.

### The dictation you were in the middle of

While you dictate, the app keeps a protected copy of the recording, and deletes it once your text is safely saved. If the app quits before that, EnviousWispr makes one attempt to recover those words the next time it starts.

### Crash reports

Crashes are reported automatically so we can fix them. Reports describe what the app was doing, never what you said. No audio and no transcripts are ever included.
