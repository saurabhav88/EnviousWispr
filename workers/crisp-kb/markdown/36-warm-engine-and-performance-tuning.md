The warm engine keeps the audio engine and microphone tap running between recordings so the next recording starts instantly. You can configure this in **Settings > Microphone**.

Available policies:

* **Off:** Engine shuts down immediately after each recording. Lowest memory usage, but each recording has a cold start.
* **10 seconds:** Engine stays warm for 10 seconds after recording stops.
* **30 seconds (default):** Good balance between responsiveness and resource usage.
* **60 seconds:** Longer warm window for frequent dictators.
* **Always:** Engine never shuts down. Fastest possible start time, highest idle resource usage.

## Pre-Warm on Push-to-Talk Key-Down

When using Push-to-Talk mode, pressing the hotkey triggers two parallel actions: (1) the audio input is pre-warmed (audio engine started, Bluetooth codec settled), and (2) recording setup begins. By the time you start speaking, the engine is ready and the 500ms pre-roll ring buffer has been draining, capturing those critical first milliseconds of audio.

## Model Unload Policy

The ASR model can be unloaded from memory after a period of inactivity. This is separate from the warm engine (which controls audio hardware). Available policies include: never unload, immediately, 2 minutes, 5 minutes, 10 minutes, 15 minutes, and 60 minutes. Keeping the model loaded means zero cold-start latency on the next dictation but uses more memory.

## Background Model Pre-Loading

On launch, EnviousWispr pre-loads the ASR model in the background so your first dictation has zero cold-start delay. The model download includes progress tracking and SHA-256 checksum verification.