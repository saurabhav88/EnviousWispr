Live transcription is a Parakeet-exclusive feature that runs speech recognition in parallel with recording. Instead of waiting until you stop speaking, the engine processes audio buffers as they arrive.

### Enabling Live transcription

Open the settings window, go to the **Transcription** tab, and enable **Live transcription**. This setting only appears when Parakeet is selected. It is off by default.

### How it works

* While you record, audio buffers are streamed to the Parakeet engine as they arrive.
* The engine runs inference on overlapping 11-second chunks with 2-second left and right context for accuracy.
* When you release the hotkey, a finalization step flushes any remaining audio and assembles the final transcript.
* If streaming produces an empty or low-quality result and the VAD detected speech, the system automatically falls back to a full batch transcription (streaming rescue).

### Trade-offs

* **Speed:** Results appear faster after you stop recording because most of the transcription already happened during recording.
* **Quality:** Batch mode (Live transcription off) can produce slightly cleaner raw output because the engine sees all the audio at once. This is why batch is the default.

### Note

WhisperKit does not support streaming ASR. It uses a separate incremental worker that polls captured audio every 3 seconds during recording to provide progressive results, but final transcription is always a batch operation.