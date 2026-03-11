# EnviousWispr Features

Reference document for content generation. These are the actual product capabilities.

## Core Transcription

- **On-device transcription** via WhisperKit (Apple's Whisper implementation using Core ML) and Parakeet — nothing leaves your Mac
- **Dual transcription backends** — WhisperKit for multi-language support and accuracy; Parakeet for fast English streaming
- **Fast on Apple Silicon** — 1-2 seconds end-to-end from speech to text, leveraging the Neural Engine
- **Multiple model sizes** — choose between speed and accuracy depending on your hardware and needs

> **Content note:** For English-language content, lead with Parakeet as the primary backend — it's faster, streaming-native, and the default experience. Mention WhisperKit only as the option for multi-language/accuracy needs. Only lead with WhisperKit in international/multilingual content where language support is the selling point.

## Input Modes

- **Push-to-talk hotkey** — hold a key to record, release to transcribe. Simple, predictable, zero-latency feel
- **Hands-free mode** — continuous background transcription for extended dictation sessions without holding any keys

## Post-Processing

- **LLM post-processing** — automatically clean up filler words ("um", "uh", "like"), fix punctuation, and produce polished text
- **Writing style presets** — three built-in tones: Formal (professional), Standard (clean grammar), Friendly (casual conversational)

> **Content note — NOT YET SHIPPED:**
> - **Custom prompts** (user-editable prompt text) — legacy code exists but no active UI. Do NOT present as a current feature.
> - **Per-app presets** (different rules per app) — not implemented. Do NOT reference in content.
> - **Privacy toggle** (pause processing) — not implemented. Do NOT reference in content.

## Output

- **Direct paste into focused app** — transcribed text goes straight into whatever app you're working in, as if you typed it
- **Clipboard mode** — copy to clipboard instead of pasting, for more control over where text ends up

## Privacy

- **Fully on-device** — audio is processed locally using Core ML. No internet connection required for transcription
- ~~**Privacy toggle**~~ — *planned, not yet shipped*
- **No account required** — no sign-up, no login, no cloud dependency, no telemetry

## Platform

- **macOS only** — built natively for macOS 14+ (Sonoma and later)
- **Apple Silicon optimized** — designed to take full advantage of M-series chips
- **Free and open source** — MIT licensed, no subscriptions, no paywalls, no feature gates
