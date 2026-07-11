<p align="center">
  <img src="assets/readme/icon.svg" width="80" alt="EnviousWispr icon" />
</p>

<h1 align="center">EnviousWispr</h1>

<p align="center">
  <strong>Talk naturally. Paste perfectly.</strong><br/>
  Free, on-device AI dictation and speech-to-text for macOS.<br/>
  Powered by Apple Silicon. No cloud, no account, your voice never leaves your Mac.
</p>

<p align="center">
  <a href="https://github.com/saurabhav88/EnviousWispr/releases/latest"><img src="https://img.shields.io/github/v/release/saurabhav88/EnviousWispr?style=flat-square&label=latest&color=7c3aed" alt="Latest Release" /></a>
  <a href="https://enviouswispr.com/download?source=github_readme&utm_source=github&utm_medium=referral&utm_campaign=enviouswispr-evergreen-readme"><img src="https://img.shields.io/badge/download-DMG-black?style=flat-square" alt="Download DMG" /></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-GPLv3-7c3aed?style=flat-square" alt="License GPLv3" /></a>
  <a href="https://enviouswispr.com"><img src="https://img.shields.io/badge/web-enviouswispr.com-7c3aed?style=flat-square" alt="Website" /></a>
  <a href="https://x.com/EnviousLabs"><img src="https://img.shields.io/badge/follow-@EnviousLabs-black?style=flat-square&logo=x" alt="Follow on X" /></a>
</p>

<p align="center">
  <img src="assets/readme/hero.gif" width="720" alt="EnviousWispr hero - Talk naturally, paste perfectly" />
</p>

---

## Demo

https://github.com/user-attachments/assets/2655d632-1ad8-4a00-bac8-d6c3cc2f6aad

## What is this?

EnviousWispr is a free AI dictation app for macOS that runs entirely on-device. It uses Whisper and Parakeet speech-to-text models on Apple Silicon to transcribe your voice locally, polishes the output with an optional LLM, and pastes clean text into whatever app you're working in. Transcription is sub-second; with optional AI polish, the full hotkey-to-paste flow typically lands in around a second and a half.

No cloud. No account required. No subscription. No audio ever leaves your Mac. Works fully offline.

It is open source under the GPLv3, actively maintained, and built to be a tool you can rely on every day.

## Why EnviousWispr?

| | EnviousWispr | Cloud dictation services |
|---|---|---|
| **Privacy** | 100% on-device transcription | Audio uploaded to servers |
| **Speed** | Sub-second transcription, paste-on-stop | Network round-trip latency |
| **Models** | Parakeet v3 (NVIDIA NeMo) + WhisperKit (OpenAI Whisper) | Single vendor model |
| **Polish** | Optional. Fully on-device (EG-1, Apple Intelligence, Ollama) or bring-your-own-key cloud (GPT, Gemini) | Cloud polish, included in subscription |
| **Cost** | Free. No account, no subscription | Monthly subscription |
| **Works offline** | Yes, fully functional without internet | No |

## How it works

```
Press hotkey  -->  Record  -->  Transcribe  -->  Polish (optional)  -->  Paste
    ~0ms          live        ~400-800ms         ~200-500ms            instant
```

1. **Press your hotkey** from any app. Push-to-talk, toggle, or hands-free (double-press to lock for long-form), your choice.
2. **Speak naturally.** Silero VAD detects when you stop talking and ends recording automatically.
3. **On-device transcription.** Choose Parakeet v3 (fastest, 25 European languages) or WhisperKit (99 languages, with automatic language detection).
4. **AI polish** (optional). Clean up grammar, punctuation, and formatting. Runs fully on-device with EG-1 (our own custom model), Apple Intelligence (macOS 26+), or Ollama, or in the cloud via OpenAI or Gemini with your own API key.
5. **Text lands in your clipboard** and optionally auto-pastes into the active app.

> See the full interactive pipeline demo at [enviouswispr.com/how-it-works](https://enviouswispr.com/how-it-works)

## Reliability is a feature

Dictation is only useful if you can trust it mid-sentence, every time. EnviousWispr keeps the critical path (record, transcribe, paste) deliberately separate from every optional enhancement, so a hiccup in a "nice to have" can never swallow your words. When an optional step cannot run, you simply get your raw transcribed text instead of an error.

| What we hardened | What it means for you |
|---|---|
| **Delivery survives non-critical failures** | If saving to your history cannot complete (full disk, permissions), your dictation is still pasted. The save is best-effort and never blocks delivery. |
| **Paste that actually lands** | A multi-step delivery path tries the fastest reliable method first and falls back automatically, so text lands even in apps that resist the usual paste (Word, Excel, Pages, Numbers, and more). |
| **Onboarding that won't leave you half-set-up** | Setup won't let you start until Accessibility is granted, and it re-checks if you later revoke permission. |
| **Clear answers when AI polish has a problem** | If a cloud or local model fails (OpenAI, Gemini, Ollama), you get a specific, plain-language message, and your raw text still arrives. |
| **Deterministic cleanup before AI** | For English, numbers, dates, and money are formatted by a fixed, predictable step, even when AI polish is off or unavailable. |
| **Fast recovery after idle** | After the app sits idle, it re-wakes in a fraction of a second so your next press, and its first word, are not lost. |
| **Privacy-safe diagnostics** | Crash reports carry counts and context, never your transcript or audio, and are redacted before they are sent. |
| **Hardened releases** | Every build is signed, notarized, and Gatekeeper-checked before it ships. |

## Supported Models

| Model | Best for | Languages | Disk space | Runs on |
|---|---|---|---|---|
| **Parakeet TDT v3** | Fastest dictation (default) | 25 European languages | ~460 MB | Apple Neural Engine |
| **WhisperKit** (Whisper Large v3 Turbo) | Broadest language coverage and automatic language detection | 99 languages | ~1.6 GB | Apple GPU |

Both models run entirely on-device on Apple Silicon using CoreML. Parakeet runs on the Apple Neural Engine, which is what makes the default engine near-instant; WhisperKit runs on the GPU for broad-language accuracy. First launch downloads and compiles the model; subsequent launches are instant.

## On-device AI polish

Transcription gets your words down. AI polish cleans them up: it drops filler, fixes grammar and punctuation, and structures rambling speech into readable text. This step is optional, and by default it never leaves your Mac.

| Polish engine | What it is | Runs on | Extra download |
|---|---|---|---|
| **EG-1** (recommended) | Our own model, custom fine-tuned for dictation cleanup | On-device, macOS 14+ | ~2.9 GB (optional) |
| **Apple Intelligence** | Apple's on-device model, no extra download | On-device, macOS 26+ | none |
| **Ollama** | Bring your own local model (3B or larger recommended) | On-device | varies |
| **OpenAI / Gemini** | Bring-your-own-key cloud polish, text only | Cloud (your key) | none |

**EG-1** is our own AI model, fine-tuned specifically for dictation cleanup and optimized for Apple Silicon. It runs entirely on your Mac with no internet required, and it closes the gaps a general on-device model leaves: reliably turning a spoken list into a real list, splitting a wall of speech into clean paragraphs, and keeping only the corrected version when you fix yourself mid-sentence. Because it is our own model rather than Apple's, it works across the full supported range (macOS 14 and later), not just macOS 26. EG-1 is distributed under its own model license, not the GPLv3 that covers the app code (see [License](#license)).

On our own benchmark of 1,890 real dictation-cleanup cases, EG-1 passed 93.7%, ahead of both GPT-5.4-mini (83.8%) and Gemini 3.5 Flash (92.6%) on the same cases with the same judge. This is our own benchmark, not an independent review. The eval harness and the exact prompts are public in [`scripts/eval/`](scripts/eval/) so you can inspect or rerun them; the test cases are personal dictations and stay private.

## Features

- 🎙️ **Dual ASR engines** with [Parakeet v3](https://github.com/FluidInference/FluidAudio) (NVIDIA NeMo) and [WhisperKit](https://github.com/argmaxinc/argmax-oss-swift) (OpenAI Whisper)
- ✨ **AI polish that respects your words**: strips filler words and false starts, fixes grammar and punctuation, formats numbers, dates, and URLs, and honors your custom vocabulary, all in your spoken language (never translated or rewritten)
- 🔒 **Polish that can stay private**: run it fully on-device with EG-1 (our own custom model), Apple Intelligence (macOS 26+), or Ollama, or in the cloud via OpenAI GPT / Google Gemini with your own API key
- 🌍 **Multilingual with automatic language detection**: speak in any supported language and EnviousWispr detects it, then offers to lock it in for faster, more accurate transcription
- 😀 **Speak an emoji**: say the emoji's name followed by "emoji" (like "thumbs up emoji") and the glyph drops right in
- ✋ **Voice Activity Detection** via Silero VAD that stops recording automatically when you stop talking
- 📚 **Custom vocabulary and vocabulary packs** for names, brands, and technical terms the ASR might miss, plus one-tap import of names from your Contacts (which never leave your Mac)
- ⌨️ **Global hotkey** with push-to-talk, toggle, and hands-free modes (double-press to lock for long-form dictation)
- 📋 **Auto-paste** directly into the active app, or just copy to clipboard
- 🕘 **Transcript history** for browsing, searching, and reviewing past dictations
- 🧭 **Menu bar native** with minimal footprint
- 🔄 **Auto-updates** via Sparkle

## Recent improvements

EnviousWispr ships often. A few of the user-facing improvements from recent releases:

- **Pasting lands in more apps.** Text now reliably reaches apps that previously said "Copied" but never pasted (Word, Excel, Pages, Numbers, OneNote, and others). (v2.1.4)
- **Vocabulary packs and Contacts import.** Turn on a pack for brands and jargon, or import the names of people you know in one tap, so hard-to-spell names come out right. Your contacts never leave your Mac. (v2.1.3)
- **No swallowed first word after a break.** After idling, the engine re-wakes in a fraction of a second and captures your words, including the very first one. (v2.1.2 and v2.1.3)
- **Soft and distant speech captured.** Quiet, whispered, or far-from-the-mic speech is now transcribed instead of dropped. (v2.1.2)
- **Automatic update checks.** The app looks for new versions on its own, with a clear "Check for Updates" control in Settings. (v2.1.2)
- **Clearer AI polish errors.** Cloud and local polish failures (OpenAI, Gemini, Ollama) now show a specific, actionable message, and your raw text still arrives.

See the [full release history](https://github.com/saurabhav88/EnviousWispr/releases) for every version.

## Quick Start

Install with [Homebrew](https://brew.sh):

```bash
brew install --cask saurabhav88/tap/enviouswispr
```

Or download manually:

1. Download [EnviousWispr.dmg](https://enviouswispr.com/download?source=github_readme&utm_source=github&utm_medium=referral&utm_campaign=enviouswispr-evergreen-readme) from the latest release
2. Drag to Applications, launch
3. Grant **Microphone**, **Accessibility**, and (on first paste fallback) **Automation** permissions when prompted
4. Set your preferred hotkey in Settings > Shortcuts
5. Start talking

**Optional:** Turn on AI polish in Settings > AI Polish. Keep it fully on-device with Apple Intelligence (macOS 26+) or Ollama, or add an OpenAI or Gemini API key.

## Requirements

- macOS 14 (Sonoma) or later
- Apple Silicon (M1 or newer)

Core dictation works across the full supported range. The built-in Apple Intelligence polish option requires macOS 26 or later; on earlier versions dictation works normally and you can use Ollama or a cloud key for polish instead.

## Building from Source

```bash
git clone https://github.com/saurabhav88/EnviousWispr.git
cd EnviousWispr
swift build            # compiles the Swift packages (dependencies resolve via SPM)
```

The runnable `.app` is assembled by the Xcode build engine via Tuist, not by `swift build`. Use `./scripts/build-dev-app.sh` for a local dev build, or the release path below. First build takes several minutes as ML models compile.

For a distributable `.app` bundle and DMG:

```bash
./scripts/build-release-dmg.sh <version>
```

The release build runs on the Xcode engine via Tuist, so it requires full Xcode (26+) plus mise and Tuist; set `CODESIGN_IDENTITY` to sign. Running the app itself requires macOS 14+.

## Architecture

The app follows a pipeline state machine: **idle --> recording --> transcribing --> polishing --> complete**.

Key design choices:
- **Swift 6 strict concurrency** with full actor isolation
- **Dual pipeline architecture** with deliberately separate Parakeet and WhisperKit backends (isolation is a feature, not tech debt)
- **Heart & Limbs pattern** where the critical path (audio, ASR, paste) never fails, and features (polish, custom words, filler removal) degrade gracefully
- **Local-first** with LLM polish as an opt-in enhancement using your own keys

## Contributing

Contributions are welcome. EnviousWispr is open source under the GPLv3. Please open an issue to discuss significant changes before submitting a PR.

This project uses conventional commits: `feat(scope):`, `fix(scope):`, `refactor(scope):`.

## Privacy

EnviousWispr is built on a simple principle: **your voice is yours.**

- Audio is captured, transcribed, and discarded locally. Nothing is uploaded, stored, or shared.
- LLM polish (if enabled) can run entirely on your Mac with EG-1 (our own model), Apple Intelligence, or a local Ollama model, so the polish step makes no network call. If you pick a cloud provider (OpenAI or Gemini), only text is sent (your transcript plus the polish instructions) using your own API key. Audio is never sent.
- Anonymous product analytics (PostHog) can be disabled in Settings.
- Crash reporting (Sentry) contains no transcript content, audio, or personal data.

## Connect

- **Website:** [enviouswispr.com](https://enviouswispr.com)
- **X:** [@EnviousLabs](https://x.com/EnviousLabs)
- **Email:** hello@enviouswispr.com

Built by [Envious Labs](https://enviouslabs.co)

## License

EnviousWispr is open source under the [GNU General Public License v3](LICENSE) (GPLv3), an OSI-approved license. You can read, build, modify, and redistribute the code under the terms of the GPL, including for commercial purposes; distributed derivative works must also be licensed under the GPLv3 with their source available.

Copyright (C) 2024-2026 Envious Labs LLC.

**The EG-1 model is not open source.** The GPLv3 covers the EnviousWispr application code only. EG-1's model weights are not part of this repository; they download separately and are distributed under the [EG-1 Community Model License](EG-1-MODEL-LICENSE.txt). You are free to download and use EG-1 within EnviousWispr, but you may not redistribute, re-host, mirror, or bundle the model into other products, or use the model, or outputs generated by it at scale, to train, fine-tune, or distill another model intended for commercial distribution. EG-1 is a fine-tuned derivative of Qwen3-4B-Instruct-2507 (Apache-2.0); this license applies to the fine-tuned weights.

The EnviousWispr name and logo are trademarks of Envious Labs and are not covered by the GPL.
