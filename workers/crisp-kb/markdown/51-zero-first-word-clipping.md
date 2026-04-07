A common problem with voice-to-text apps is missing the first word or syllable of your dictation. EnviousWispr solves this with a pre-roll ring buffer and warm engine policy.

### 500ms Pre-Roll Ring Buffer

The pre-roll forwarder maintains a ring buffer that continuously captures the last 500ms of audio (8,000 samples at 16kHz). When you start recording, this buffer is drained first, so audio from just before you pressed the hotkey is included in the recording. This catches the beginning of your speech even if you start talking slightly before the key press registers.

### Two-Phase Recording Start

Recording starts in two phases:

1. **Engine phase**: The audio engine starts, audio flows into the ring buffer immediately.
2. **Capture phase**: The ring buffer is drained (pre-roll samples are fed through callbacks in ~40ms chunks), then live audio capture begins.

This split ensures the pre-roll buffer has audio to drain when capture begins.

### Warm Engine Policy

After a recording ends, the audio engine stays running in pre-roll mode rather than shutting down. The engine continues buffering the last 500ms of audio. When you start your next recording, the pre-roll buffer already has fresh audio and there is zero startup latency.

The warm engine timeout is configurable in **Settings > Microphone**:

* **Off**: Engine stops immediately after recording. Cold start on next recording (~100ms on Apple Silicon, no pre-roll available).
* **10s / 30s / 60s**: Engine stays warm for this duration. Default is 30 seconds.
* **Always**: Engine never stops. Instant start with pre-roll at all times.

### Cold Start Performance

Even on a cold start (after the warm engine has timed out), startup latency on Apple Silicon is approximately 100ms, which is fast enough that first-word clipping is not an issue in practice. However, pre-roll audio is not available on cold starts since the engine was not running.