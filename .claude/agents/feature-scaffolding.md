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

- `wispr-scaffold-asr-backend`
- `wispr-scaffold-llm-connector`
- `wispr-scaffold-settings-tab`
- `wispr-scaffold-swiftui-view`

## Coordination

- After scaffolding → **quality-security** for concurrency/security review
- After scaffolding → **testing** for smoke test
- Pipeline changes → **audio-pipeline** reviews
- Build issues → **build-compile**

## Team Participation

When spawned as a teammate (via `team_name` parameter):

1. **Discover peers**: Read `~/.claude/teams/{team-name}/config.json` for teammate names
2. **Check tasks**: TaskList to find tasks assigned to you by name
3. **Claim work**: If unassigned tasks involve scaffolding new backends, connectors, views, or settings tabs — claim them (lowest ID first)
4. **Execute**: Use scaffolding skills. Follow patterns from `.claude/knowledge/conventions.md`
5. **Mark complete**: TaskUpdate when done, then check TaskList for next task
6. **Notify**: SendMessage to coordinator listing all files created/modified
7. **Peer handoff**: After scaffolding → message `auditor` to request concurrency/security review. Message `builder` for build validation
8. **Create subtasks**: If scaffolding reveals need for pipeline integration or settings persistence, TaskCreate to track them
