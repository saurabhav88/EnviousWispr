All speech recognition in EnviousWispr runs on your Mac using Apple Silicon's Neural Engine and GPU. No audio data is ever uploaded to a server.

### The pipeline

1. **Audio capture:** Your microphone input is captured at 16kHz mono (Float32 format) through an audio tap that fires approximately every 128ms.
2. **Pre-roll buffer:** A 500ms ring buffer captures audio before you start speaking, eliminating first-word clipping.
3. **Voice Activity Detection (VAD):** Silero neural VAD detects speech segments and filters silence. This ensures only voiced audio reaches the model.
4. **Transcription:** The captured audio is fed to your selected engine (Parakeet or WhisperKit), which runs inference on the Neural Engine.

### Process isolation

Both audio capture and ASR inference run in separate background processes. If the ASR engine crashes, the main app continues running and automatically relaunches the service on the next recording. Your dictation workflow is never interrupted by an engine crash.

### Performance

* Parakeet achieves approximately 110x real-time on Apple Silicon.
* The warm engine policy keeps the audio engine running between recordings (configurable timeout: Off, 10s, 30s, 60s, or Always). This eliminates cold-start latency on consecutive dictations.
* Model pre-loading runs in the background so your first dictation has zero cold-start delay.