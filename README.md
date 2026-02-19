# EnviousWispr

Local-first macOS dictation — record, transcribe, polish, paste. All processing happens on your Mac.

## Features

- **On-device transcription** — choose between [Parakeet v3](https://github.com/FluidInference/FluidAudio) (NVIDIA NeMo) or [WhisperKit](https://github.com/argmaxinc/WhisperKit) (OpenAI Whisper). No audio ever leaves your machine.
- **Voice Activity Detection** — Silero VAD automatically detects speech boundaries and silence, so you can stop recording hands-free.
- **LLM polish** — optionally clean up transcripts with OpenAI GPT or Google Gemini (requires your own API key).
- **Global hotkey** — trigger dictation from anywhere with a configurable keyboard shortcut. Supports both toggle and push-to-talk modes.
- **Clipboard integration** — transcribed text is copied to your clipboard and optionally pasted into the active app automatically.
- **Transcript history** — browse, search, and review past transcriptions.
- **Menu bar app** — lives in your menu bar, out of the way until you need it.
- **Auto-updates** — built-in Sparkle updater keeps you current.

## Requirements

- macOS 14 (Sonoma) or later
- Apple Silicon (M1 or newer)

## Installation

Download the latest `.dmg` from [Releases](https://github.com/saurabhav88/EnviousWispr/releases), open it, and drag EnviousWispr to your Applications folder.

On first launch you'll be prompted to grant **Microphone** and **Accessibility** permissions.

## Usage

1. **Set your hotkey** — open Settings (click the menu bar icon > Settings) and configure your preferred shortcut under the Shortcuts tab.
2. **Start dictating** — press your hotkey to start recording. Speak naturally.
3. **Stop recording** — press the hotkey again (toggle mode) or release the key (push-to-talk mode). VAD auto-stop will also end recording after a silence threshold.
4. **Text is ready** — the transcription appears in your clipboard. If auto-paste is enabled, it's typed into the active app automatically.

### Optional: LLM Polish

Under Settings > AI Polish, add your OpenAI or Gemini API key and enable polishing. The raw transcript will be sent to the LLM for cleanup (grammar, punctuation, formatting) before being placed on the clipboard.

## Building from Source

```bash
git clone https://github.com/saurabhav88/EnviousWispr.git
cd EnviousWispr
swift build
```

Dependencies (WhisperKit, FluidAudio, Sparkle) resolve automatically via Swift Package Manager. First build will take several minutes as ML models compile.

To create a distributable `.app` bundle and DMG:

```bash
./scripts/build-dmg.sh
```

### Requirements for building

- macOS 14+, Apple Silicon
- Swift 6.0+ toolchain (Xcode Command Line Tools or full Xcode)

## Architecture

```
Hotkey → AudioCaptureManager → AVAudioEngine (16kHz mono)
  → SilenceDetector (Silero VAD)
  → ASRManager → Parakeet v3 or WhisperKit
  → TranscriptPolisher (OpenAI / Gemini)
  → Clipboard + optional auto-paste
```

The app follows a pipeline state machine: **idle → recording → transcribing → polishing → complete**.

Key design choices:
- **Swift 6 strict concurrency** — full actor isolation, `@MainActor` UI state, actor-based ASR backends
- **Protocol-based backends** — `ASRBackend` and `TranscriptPolisher` protocols make it straightforward to add new engines
- **Local-first** — audio never leaves the device; LLM polish is opt-in and uses your own keys

See [architecture docs](.claude/knowledge/architecture.md) for the full breakdown.

## Contributing

Contributions are welcome. Please open an issue to discuss significant changes before submitting a PR.

This project uses conventional commits: `feat(scope):`, `fix(scope):`, `refactor(scope):`.

## License

EnviousWispr is licensed under the [GNU General Public License v3.0](LICENSE). Derivative works must remain free and open source under the same terms.
