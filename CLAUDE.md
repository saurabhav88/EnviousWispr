# VibeWhisper

## Project Overview

Local-first macOS dictation app for Apple Silicon. Records speech, transcribes locally using pluggable ASR backends, with optional LLM post-processing for grammar cleanup.

**Primary ASR backend:** Parakeet v3 via FluidAudio (CoreML, ~110x RTF, built-in punctuation)
**Fallback ASR backend:** WhisperKit (broader language support, 99+ languages)
**Deployment target:** macOS 14.0+ (Sonoma)

## Project Structure

```text
EnviousWispr/
├── Package.swift                  # SPM manifest (WhisperKit, FluidAudio, KeyboardShortcuts)
├── Sources/VibeWhisper/
│   ├── App/                       # SwiftUI app entry, AppState, DI
│   ├── Views/                     # All SwiftUI views (MenuBar, Main, Settings, Components)
│   ├── ViewModels/                # View models
│   ├── Audio/                     # AVAudioEngine capture, buffer processing, VAD
│   ├── ASR/                       # ASRBackend protocol + WhisperKit/Parakeet backends
│   ├── LLM/                       # TranscriptPolisher protocol + OpenAI/Gemini connectors
│   ├── Models/                    # Shared data types (Transcript, ASRResult, etc.)
│   ├── Storage/                   # TranscriptStore (JSON persistence)
│   ├── Pipeline/                  # TranscriptionPipeline orchestrator
│   ├── Services/                  # HotkeyService, PasteService, PermissionsService
│   ├── Utilities/                 # Constants, extensions
│   └── Resources/                 # Assets, Info.plist, entitlements
├── Tests/VibeWhisperTests/
├── docs/                          # Architecture docs, benchmarks
├── fixtures/                      # Test audio files
└── CLAUDE.md
```

## Key Protocols

- `ASRBackend` (actor protocol) — `ASR/ASRProtocol.swift`
- `TranscriptPolisher` — `LLM/LLMProtocol.swift`

## Conventions

- All outputs go in their designated folders
- Audio format: 16kHz mono Float32 throughout
- State management: `@Observable` (Observation framework)
- API keys: macOS Keychain via `KeychainManager`
- Transcript storage: JSON files in `~/Library/Application Support/VibeWhisper/transcripts/`
- Only load the active ASR backend (unload before switching)
- Use clear, descriptive filenames

## Build & Run

```bash
swift build
swift run VibeWhisper
swift test
```

## Commit Guidance

Conventional commits:
- `feat(asr): implement Parakeet v3 backend`
- `feat(ui): add transcript history view`
- `fix(audio): correct sample rate conversion`
- `docs(arch): add architecture decision record`

## Current Status

**Milestone 0: Repo + Running Skeleton** — In progress

- [x] Project scaffolded with SPM
- [x] Models, protocols, and stubs created
- [x] SwiftUI app shell with MenuBarExtra
- [ ] Verify build compiles
- [ ] First commit

## When Stuck

- Check `docs/` for architecture decisions
- Check the plan at `.claude/plans/snug-dancing-wall.md`
- Ambiguous requirements → escalate to human
