---
title: "When the App or Speech Engine Stops"
description: "What happens if the app or the speech engine stops, and what is saved."
category: "troubleshooting"
section: "Recording Issues"
order: 8
keywords: ["crash", "crashes", "quits", "closes by itself", "keeps crashing", "stopped working", "disappeared", "not responding"]
updated: 2026-08-06
---
EnviousWispr keeps its transcription engine separate from the rest of the app, so a failure in one does not take the other down with it.

### If the speech engine stops

The transcription engine runs in its own process. If that process hits an error and stops, the rest of EnviousWispr stays open. EnviousWispr starts the engine again when you press your hotkey for your next recording. There is nothing for you to do.

### If the app itself quits

**Open the app again.** Launch EnviousWispr from your Applications folder. Your past dictations are still there, because your history is written to disk as you go rather than held in memory.

### Recovering an interrupted recording

EnviousWispr keeps a protected copy of your audio while you speak, and deletes that copy once your text has been safely saved. If the app quits before that happens, EnviousWispr makes one attempt to recover those words the next time you open it.

### Crash reports

Crash reports are sent to Envious Labs automatically so the cause can be diagnosed and fixed. A crash report describes what the application code was doing at the moment of failure. It never includes what you said. Audio recordings and text transcripts are never part of a crash report.
