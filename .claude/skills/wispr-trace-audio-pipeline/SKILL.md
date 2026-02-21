---
name: wispr-trace-audio-pipeline
description: "Use when diagnosing end-to-end failures in the dictation pipeline — silent recordings, empty transcripts, missing clipboard pastes, VAD not triggering, or unclear where in the chain audio data is lost."
---

# Trace the Audio Pipeline End-to-End

## Full Data Flow

```
[1] Hotkey / Record button
      ↓
[2] AudioCaptureManager.startCapture()
      AVAudioEngine.inputNode tap installed
      AVAudioConverter: hardware format → 16kHz mono Float32
      AsyncStream<AVAudioPCMBuffer> yielded per tap callback
      capturedSamples: [Float] appended
      ↓
[3] SilenceDetector (if VAD enabled)
      Polled every 100ms from TranscriptionPipeline
      Reads capturedSamples, processes 4096-sample chunks
      Returns speechEnded: Bool → triggers auto-stop
      ↓
[4] stopCapture() — manual or VAD-triggered
      AVAudioEngine tap removed
      AsyncStream continuation finished
      capturedSamples handed to pipeline
      ↓
[5] ASRManager.transcribe(audioSamples:)
      Writes Float32 samples to temp WAV file (16kHz mono)
      Calls activeBackend.transcribe(audioURL:)
      ↓
[6] ParakeetBackend or WhisperKitBackend
      Runs CoreML inference on Apple Silicon
      Returns ASRResult(text:, language:, duration:)
      ↓
[7] TranscriptPolisher (optional)
      OpenAI or Gemini HTTP call
      Input: raw text; Output: polished text
      ↓
[8] TranscriptStore.save(transcript:)
      JSON written to ~/Library/Application Support/EnviousWispr/transcripts/
      ↓
[9] PasteService.paste(text:)
      NSPasteboard write + CGEvent Cmd+V injection
      ↓
[10] UI update via @Observable AppState
       TranscriptionPipeline.state → .complete
       Latest transcript shown in MainWindowView / MenuBarView
```

## Checkpoint Diagnostics

| Stage | What to check | Common failure |
|---|---|---|
| [2] Audio tap | `capturedSamples.count > 0` after stop | Microphone permission denied; wrong input device |
| [2] Format conversion | AVAudioConverter non-nil | Hardware sample rate mismatch |
| [3] VAD polling | VAD timer fires; chunks processed | Timer not started; `speechEnded` never true for short speech |
| [5] WAV file | Temp file written to disk, non-zero size | Disk full; temp dir permission |
| [6] Backend | `isReady == true` before transcribe | `prepare()` not called; model download failed |
| [7] LLM polish | API key non-nil; HTTP 200 | Key not in Keychain; network offline |
| [9] Paste | Accessibility permission granted | `AXIsProcessTrusted()` returns false |

## PipelineState Progression

`.idle` → `.recording` → `.transcribing` → `.polishing` → `.complete`

If stuck in `.transcribing`: backend threw or never returned — check logs for `ASRError`.
If stuck in `.polishing`: LLM call failed silently — add error propagation to `TranscriptionPipeline`.
If `.complete` but no paste: `PasteService` requires Accessibility permission.

## Key File Locations

- Audio capture: `Sources/EnviousWispr/Audio/AudioCaptureManager.swift`
- VAD: `Sources/EnviousWispr/Audio/SilenceDetector.swift`
- Pipeline orchestrator: `Sources/EnviousWispr/Pipeline/TranscriptionPipeline.swift`
- ASR routing: `Sources/EnviousWispr/ASR/ASRManager.swift` (or similar)
- Paste: `Sources/EnviousWispr/Services/PasteService.swift`
