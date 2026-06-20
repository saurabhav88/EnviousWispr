Every transcription is saved automatically to a persistent transcript history stored as JSON on disk. You can access your history from the **History** section in the app's settings window.

## What Is Stored

Each transcript entry includes:

* The original ASR text (before any polishing)
* The final polished text (after word correction, filler removal, and LLM polish)
* Execution metrics: a full latency breakdown for each stage of the pipeline (recording duration, ASR time, polish time, total time)
* Timestamp and metadata

## Actions

* **Copy:** Copy any past transcript to your clipboard.
* **Search and filter:** Find specific transcripts using the search bar in the History view.

## Storage

Transcripts are stored as JSON on disk and persist across app restarts, crashes, and updates. History is currently unlimited with no restrictions.

## Troubleshooting

* **History appears empty:** If you just installed the app, you need to complete at least one dictation first. If you previously had transcripts and they disappeared, check that you are running the same build (production vs development builds use separate storage).