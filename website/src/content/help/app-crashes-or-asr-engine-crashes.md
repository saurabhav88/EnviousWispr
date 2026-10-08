---
title: "When the App or Speech Engine Stops"
description: "What to do if EnviousWispr quits or stops transcribing, and whether the words you were saying are saved."
category: "troubleshooting"
section: "Recording Issues"
order: 8
keywords: ["crash", "crashes", "quits", "closes by itself", "keeps crashing", "stopped working", "disappeared", "not responding", "quit unexpectedly", "dictation stopped", "lost my dictation", "recover recording", "crash reports"]
updated: 2026-09-29
deflection: "show_but_always_send"
---
If EnviousWispr quits, open it again from your Applications folder. Your past dictations are still in History. If it only stops transcribing, press your keybind again. This page covers both cases, and what happens to the words you were saying.

### EnviousWispr quit on its own

**Open the app again.** Launch EnviousWispr from your Applications folder. Your past dictations are still there, because your history is saved to disk as you go rather than held in memory.

### Dictation stopped but the app is still open

Press your keybind and dictate again. For most transcription errors, EnviousWispr tries once more on the same recording. A stuck speech engine is not retried. If the retry fails, you need to say it again.

Speech recognition runs inside the EnviousWispr app itself. In rare cases a serious speech engine failure can close the whole app, and then the steps for a quit app apply.

### Will I get back what I was saying when it quit?

Sometimes. While you speak, EnviousWispr keeps a protected copy of your audio. When a recording finishes or fails while the app is still running, EnviousWispr deletes that copy.

If the app quits, crashes, is force quit, or your Mac loses power in the middle of a recording, the copy stays. The next time you open EnviousWispr, it makes one attempt to turn that audio into text. If that works, the text is added to your History. It does not paste the text for you, so open History to copy it.

### Turn crash reports on or off

EnviousWispr sends crash reports to Envious Labs so we can find and fix the cause. To change this, go to **App Settings** > **Privacy** and switch **Send crash reports** on or off. The change applies after EnviousWispr restarts.

A crash report describes what the app's code was doing when it failed. It never includes what you said. Audio recordings and text transcripts are never part of a crash report.
