---
name: run-benchmarks
description: Use when measuring or verifying ASR transcription performance, checking for regressions after a model or pipeline change, or comparing Parakeet v3 vs WhisperKit throughput. Requires the app to be running and a model to be loaded.
---

# Run Benchmarks Skill

## Context

`BenchmarkSuite` lives in `Sources/EnviousWispr/Utilities/BenchmarkSuite.swift`.
It generates a 440Hz sine wave at 16kHz mono and transcribes it at three durations.

`BenchmarkSuite.Result` fields:
- `label`: `"5s"`, `"15s"`, or `"30s"`
- `audioDuration`: `TimeInterval` (5.0, 15.0, 30.0)
- `processingTime`: wall-clock seconds for the transcription call
- `rtf`: `audioDuration / processingTime` — higher is faster
- `backend`: `ASRBackendType` (`.parakeet` or `.whisperKit`)

## Steps

### 1. Confirm model is loaded
Check `AppState.asrManager.isModelLoaded`. If false, call `asrManager.loadModel()` first.
`BenchmarkSuite.run(using:)` handles this automatically — if the model is not loaded it will
call `loadModel()` internally and update `progress` to `"Loading model..."`.

### 2. Trigger the benchmark
Call `BenchmarkSuite.run(using: appState.asrManager)` from a `@MainActor` context.
The suite sets `isRunning = true`, clears `results`, then iterates durations `[5, 15, 30]`.
Monitor `progress` for status: `"Testing 5s audio..."`, `"Testing 15s audio..."`, etc.
Wait until `progress == "Complete"` and `isRunning == false`.

### 3. Read results
```
results[0]: label="5s",  audioDuration=5.0,  processingTime=?, rtf=?
results[1]: label="15s", audioDuration=15.0, processingTime=?, rtf=?
results[2]: label="30s", audioDuration=30.0, processingTime=?, rtf=?
```

### 4. Compare against baselines

| Backend     | Expected RTF  | Regression threshold (fail if below) |
|-------------|---------------|---------------------------------------|
| Parakeet v3 | ~110x         | 88x  (>20% slower than 110x)          |
| WhisperKit  | ~10–30x       | 8x   (>20% slower than 10x)           |

A regression is flagged when any single result's `rtf` falls below the threshold.

## Expected Output Format

```
[BenchmarkSuite] backend=parakeet
  5s  audio: processingTime=0.045s  rtf=111.1x  PASS
 15s  audio: processingTime=0.138s  rtf=108.7x  PASS
 30s  audio: processingTime=0.272s  rtf=110.3x  PASS
```

Report any result with `rtf < threshold` as: `REGRESSION: 30s rtf=72.0x (threshold 88x)`

## Notes

- Sine-wave audio produces no speech; transcription output will be empty or near-empty — this is expected and does not affect timing validity
- RTF is computed as `audioDuration / processingTime`; a higher number means faster than real-time
- Model load time is excluded from `processingTime` (load happens before the loop)
- Run benchmarks at least twice and use the second run to avoid cold-start skew
