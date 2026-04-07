EnviousWispr uses a **pre-roll audio buffer** with a 500ms ring buffer (8000 samples at 16kHz) to capture audio before you start speaking. When the audio engine is warm (kept alive between recordings), the ring buffer continuously stores audio. When you press the hotkey, those pre-roll samples are drained and included in the recording, eliminating first-word clipping.

## Warm Engine Policy

The warm engine keeps the audio engine and microphone tap running between recordings. You can configure this in **Settings > Microphone**. Options range from Off (engine shuts down immediately after each recording) to Always (engine stays warm indefinitely). The default is 30 seconds.

With a warm engine, the next recording reuses the already-running audio tap and drains buffered pre-roll audio, so your first word is captured even if you start speaking the instant you press the hotkey.

## Cold Starts

On a cold start (first recording after launch, or after the warm engine times out), the audio engine needs to start up. Measured cold-start latency on Apple Silicon is approximately 100ms, which is fast enough that first-word clipping is rare in practice. However, no pre-roll audio is available on cold starts because the engine was not running.

## If First Words Still Clip

* Increase the warm engine timeout in **Settings > Microphone** (e.g., 60s or Always).
* Use Push-to-Talk mode: pressing and holding the hotkey triggers a pre-warm that starts the engine, giving the ring buffer time to fill before you begin speaking.