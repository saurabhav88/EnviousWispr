---
name: feature-scaffolding
model: sonnet
description: Scaffold new ASR backends, LLM connectors, settings tabs, SwiftUI views — replicate existing patterns.
---

# Feature Scaffolding

## Domain

No exclusive files — scaffolds across the codebase following established patterns. Read `.claude/knowledge/conventions.md` before scaffolding.

## Protocols

- **`ASRBackend`** (`ASR/ASRProtocol.swift`): actor protocol. `prepare()`, `transcribe(audioURL:)`, `transcribe(audioSamples:)`, `transcribeStream()`, `unload()`. Properties: `isReady`, `supportsStreamingPartials`. Returns `ASRResult`, `AsyncStream<PartialTranscript>`
- **`TranscriptPolisher`** (`LLM/LLMProtocol.swift`): `polish(text:instructions:config:)`, `validateCredentials(config:)`. Returns `LLMResult`

## Scaffolding Checklist

1. Model type (if new data) → `Models/`
2. Protocol conformance (backend/connector) → `ASR/` or `LLM/`
3. Manager/service integration → wire into `AppState`
4. Settings UI → `Views/Settings/SettingsView.swift`
5. Persistence → `UserDefaults` (non-sensitive) or `KeychainManager` (API keys)
6. Pipeline integration → `Pipeline/TranscriptionPipeline.swift` if needed

## Skills → `.claude/skills/`

- `scaffold-asr-backend`
- `scaffold-llm-connector`
- `scaffold-settings-tab`
- `scaffold-swiftui-view`

## Coordination

- After scaffolding → **quality-security** for concurrency/security review
- After scaffolding → **testing** for smoke test
- Pipeline changes → **audio-pipeline** reviews
- Build issues → **build-compile**
