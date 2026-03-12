# Apple SpeechAnalyzer — Research (2026-03-11)

## Verdict: SKIP for custom words. Not viable for vocabulary biasing.

## Why
- New high-quality `SpeechTranscriber` does NOT support `contextualStrings`
- Only fallback `DictationTranscriber` supports it — uses old iOS 10 model (8% WER vs WhisperKit 1% WER)
- `contextualStrings` cannot be applied to WhisperKit or Parakeet — it's internal to Apple's ASR decoder
- Developer reports say contextualStrings is unreliable even when available

## SpeechAnalyzer as ASR Backend (separate consideration)
Could be added as a third backend option alongside WhisperKit/Parakeet:
- **Pro**: 70x real-time speed, zero model management, system-managed
- **Con**: 14% WER vs WhisperKit 12.8%, no vocabulary biasing, macOS 26+ only
- **Con**: Less accurate in focused tests (8% WER vs 1% WER)
- Not a priority. Parakeet (speed) + WhisperKit (accuracy) cover our needs.

## API Shape (for reference)
```swift
let transcriber = SpeechTranscriber(locale: .current, preset: .offlineTranscription)
let analyzer = SpeechAnalyzer(modules: [transcriber])
try await analyzer.start(inputSequence: audioStream)
for try await result in transcriber.results {
    let text = String(result.text.characters)
}
```

## contextualStrings (DictationTranscriber only)
```swift
// Only works with the inferior fallback model
let context = AnalysisContext()
context.contextualStrings = ["EnviousWispr", "FluidAudio"]
analyzer.context = context
```
