# VibeWhisper

## Project Overview

Local-first macOS dictation app for Apple Silicon. Records speech, transcribes locally using pluggable ASR backends, with optional LLM post-processing for grammar cleanup.

**Primary ASR backend:** Parakeet v3 via FluidAudio (CoreML, ~110x RTF, built-in punctuation)
**Fallback ASR backend:** WhisperKit (broader language support, 99+ languages)
**LLM polish:** OpenAI (Chat Completions) + Google Gemini (generateContent)
**Deployment target:** macOS 14.0+ (Sonoma)

## Project Structure

```text
EnviousWispr/
├── Package.swift                  # SPM manifest (WhisperKit, FluidAudio)
├── Sources/VibeWhisper/
│   ├── App/                       # SwiftUI app entry, AppState, DI
│   ├── Views/                     # All SwiftUI views (MenuBar, Main, Settings)
│   ├── Audio/                     # AVAudioEngine capture, buffer processing
│   ├── ASR/                       # ASRBackend protocol + WhisperKit/Parakeet backends
│   ├── LLM/                       # TranscriptPolisher protocol + OpenAI/Gemini connectors
│   ├── Models/                    # Shared data types (Transcript, ASRResult, etc.)
│   ├── Storage/                   # TranscriptStore (JSON persistence)
│   ├── Pipeline/                  # TranscriptionPipeline orchestrator
│   ├── Services/                  # PasteService, PermissionsService
│   ├── Utilities/                 # Constants
│   └── Resources/                 # (excluded from build, placeholder)
├── Tests/VibeWhisperTests/
├── docs/                          # Architecture docs
├── fixtures/                      # Test audio files
└── CLAUDE.md
```

## Key Architecture

### Protocols

- `ASRBackend` (actor protocol) — `ASR/ASRProtocol.swift`
- `TranscriptPolisher` — `LLM/LLMProtocol.swift`

### Data Flow

```text
Record button → AudioCaptureManager (AVAudioEngine, 16kHz mono)
  → ASRManager → ParakeetBackend / WhisperKitBackend
  → [optional] LLM Polish (OpenAI / Gemini)
  → TranscriptStore → UI + Clipboard
```

### State Management

- `@Observable AppState` as root (Observation framework, macOS 14+)
- `TranscriptionPipeline` orchestrates the full flow
- `PipelineState` enum: `.idle` → `.recording` → `.transcribing` → `.polishing` → `.complete`
- Settings: `UserDefaults` (non-sensitive) + `KeychainManager` (API keys)

## Conventions

- Audio format: 16kHz mono Float32 throughout
- API keys: macOS Keychain via `KeychainManager`
- Transcript storage: JSON files in `~/Library/Application Support/VibeWhisper/transcripts/`
- Only load the active ASR backend (unload before switching)
- Use `@preconcurrency import` for FluidAudio/WhisperKit (Swift 6 concurrency)
- FluidAudio module has a struct named `FluidAudio` — never use `FluidAudio.X` prefix for FluidAudio types; use unqualified names and let type inference resolve conflicts

## Build & Run

```bash
swift build           # Build the app
swift run VibeWhisper # Run the app
swift build --build-tests  # Verify tests compile (XCTest unavailable without Xcode)
```

**Note:** Only macOS Command Line Tools are installed (not full Xcode). This means:

- No `xcodebuild`, no `.xcodeproj`
- No `XCTest` or `Testing` frameworks
- No `#Preview` macros (KeyboardShortcuts deferred)

## Commit Guidance

Conventional commits:

- `feat(asr): implement Parakeet v3 backend`
- `feat(ui): add transcript history view`
- `fix(audio): correct sample rate conversion`

## Current Status

**Milestones 0-3 complete.** Core dictation pipeline working end-to-end:

- Record → Transcribe (Parakeet v3 / WhisperKit) → Display → Copy/Paste
- LLM polish (OpenAI / Gemini) with API key management
- Full settings with persistence
- Transcript history with search and delete

**Remaining (M4 — Polish + Performance):**

- Global hotkey (needs full Xcode for KeyboardShortcuts)
- VAD auto-stop (silence detection)
- UI animations, dark mode polish
- Onboarding flow
- Benchmark suite

## When Stuck

- Check `docs/` for architecture decisions
- Check the plan at `.claude/plans/snug-dancing-wall.md`
- Ambiguous requirements → escalate to human
