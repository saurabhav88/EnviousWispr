EnviousWispr uses a neural voice activity detection (VAD) system to distinguish speech from silence and background noise. This powers the auto-stop feature that ends recording when you stop speaking.

### Silero VAD

The VAD engine is Silero, a neural network model that produces a speech probability score for each audio chunk. It runs locally on your device as part of the audio processing pipeline.

### EMA Smoothing

Raw VAD probabilities can spike on single frames of noise. EnviousWispr applies Exponential Moving Average (EMA) smoothing to filter these spikes:

```
smoothed = alpha * rawProbability + (1 - alpha) * previousSmoothed
```

The alpha value scales with the sensitivity slider. At the default Normal preset, it balances responsiveness with stability.

### Speech Detection State Machine

The smoothed VAD output feeds a three-phase state machine:

1. **Idle**: No speech detected. Transitions to Speech when the smoothed probability exceeds the onset threshold for a required number of consecutive chunks.
2. **Speech**: Active speech detected. Transitions to Hangover when the probability drops below the offset threshold.
3. **Hangover**: A countdown period that handles natural pauses between sentences. If speech resumes during hangover, the state returns to Speech. If the countdown expires, recording auto-stops.

### Environment Presets

EnviousWispr provides environment presets (Quiet, Normal, Noisy) that adjust the VAD sensitivity via preset cards in the Transcription settings. Each preset maps to internal parameters:

* **Onset threshold**: Lower at high sensitivity to catch quieter speech; higher at low sensitivity to ignore background noise.
* **Offset threshold**: Onset minus 0.15 (minimum 0.1).
* **Hangover duration**: Longer at high sensitivity to tolerate longer pauses.
* **Onset confirmation**: At low sensitivity, requires 2 consecutive chunks above threshold before confirming speech (prevents false triggers).

### Post-Recording Filtering

After recording stops, VAD also filters the captured audio to extract only speech segments (with 100ms padding on each side). Only voiced audio reaches the transcription model. If total voiced content is too short (under 300ms), the full audio is used as a fallback.