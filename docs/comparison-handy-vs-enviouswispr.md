# EnviousWispr vs Handy — Technical Comparison

**Date:** 2026-02-18
**Handy version analyzed:** v0.7.6 (2026-02-17)
**Handy repo:** https://github.com/cjpais/Handy

## At a Glance

| Dimension | EnviousWispr | Handy |
|---|---|---|
| **Language** | Swift 6 (strict concurrency) | Rust + TypeScript/React |
| **UI Framework** | SwiftUI (native macOS) | Tauri v2 (WebView + React + Tailwind) |
| **Platform** | macOS only (Apple Silicon, macOS 14+) | macOS, Windows, Linux (x64 + ARM64) |
| **License** | Proprietary | MIT |
| **Latest version** | Pre-release (blocked on Apple Developer enrollment) | v0.7.6 (2026-02-17) |

---

## 1. ASR Engines

| | EnviousWispr | Handy |
|---|---|---|
| **Primary** | Parakeet v3 via FluidAudio (CoreML/Neural Engine) | Whisper via transcribe-rs (whisper.cpp/GGML) |
| **Secondary** | WhisperKit (CoreML Whisper) | Parakeet V2/V3 (CPU-only, int8 quantized) |
| **Additional** | — | Moonshine (streaming), SenseVoice |
| **Engine count** | 2 | 4 |
| **Model formats** | CoreML (.mlmodelc) | GGML .bin (Whisper), .tar.gz dirs (Parakeet) |
| **GPU accel** | Neural Engine + GPU via CoreML | Metal (macOS), CUDA/ROCm (Win/Linux) |
| **Whisper variants** | base, small, large-v3 (via WhisperKit) | Small, Medium, Turbo, Large, Breeze ASR + custom GGML |
| **Custom models** | No | Yes — any .bin in models dir auto-discovered |

**Takeaway:** Handy has broader engine support and lets users bring custom Whisper GGML models. EnviousWispr is more focused — Parakeet v3 on CoreML is extremely fast (~110x real-time) but Apple Silicon only. Handy's Parakeet runs on CPU (~5x real-time), much slower.

---

## 2. Audio Pipeline

| | EnviousWispr | Handy |
|---|---|---|
| **Capture** | AVAudioEngine tap (Apple-native) | cpal 0.16 (cross-platform) |
| **Target format** | 16kHz mono Float32 | 16kHz mono Float32 |
| **Resampling** | AVAudioConverter | rubato FFT (FftFixedIn) |
| **Tap buffer** | 4096 frames | 1024 frames |
| **Mic modes** | On-demand only | On-demand + Always-on (with OS mute) |
| **Audio feedback** | None | Start/stop beep sounds (2 themes + custom) |
| **Visualizer** | Waveform (16 bars, amplitude-based) | 16-bucket FFT spectrum (400Hz-4kHz) |

**Takeaway:** Very similar pipelines. Handy adds an always-on mic mode (stays open, OS-level mute when idle) and audio feedback sounds. EnviousWispr's visualizer is amplitude-based; Handy's is frequency-based (FFT).

---

## 3. VAD (Voice Activity Detection)

| | EnviousWispr | Handy |
|---|---|---|
| **Model** | Silero VAD v6 via FluidAudio VadManager (CoreML) | Silero VAD via vad-rs (ONNX) |
| **Frame size** | 4096 samples (256ms) | 480 samples (30ms) |
| **Threshold** | Configurable via sensitivity slider (maps to onset/offset) | Configurable |
| **Smoothing** | SmoothedVAD: EMA probability smoothing + onset confirmation + 512ms prebuffer + 768ms hangover | SmoothedVad: onset confirmation + ~200ms prefill + hangover |
| **Auto-stop** | Yes (configurable 0.5-3.0s silence timeout) | Yes |
| **Silence filtering** | Real-time speech-only accumulation (voicedSamples) with post-hoc fallback | Real-time — only speech frames appended to buffer |
| **Energy pre-gate** | RMS check before neural VAD (skips Silero for silence, saves CPU) | None |
| **Prebuffer** | 512ms circular ring buffer (captures word onsets before VAD fires) | ~200ms prefill buffer |
| **Hysteresis** | Asymmetric thresholds (onset=0.5, offset=0.35 default, EMA-smoothed) | Onset/hangover parameters |
| **VAD resolution** | Polling every 100ms | Every 30ms frame |

**Takeaway:** Both use Silero VAD with smoothing wrappers. Handy has finer frame resolution (30ms vs 256ms). EnviousWispr compensates with a more sophisticated smoothing layer: EMA probability smoothing (vs binary frame counting), a larger 512ms circular prebuffer (vs ~200ms prefill) for better word onset capture, 768ms hangover bridging natural pauses, an energy pre-gate that saves CPU during silence, and a dual-fallback system (real-time voicedSamples + post-hoc filterSamples safety net). EnviousWispr exposes a single sensitivity slider that maps to a coherent set of parameters (onset, offset, hangover, confirmation) — better UX than raw threshold configuration.

---

## 4. LLM / AI Polish

| | EnviousWispr | Handy |
|---|---|---|
| **Providers** | OpenAI, Google Gemini | OpenAI-compatible, Anthropic, Ollama, OpenRouter, Apple Intelligence |
| **Trigger** | Always (if configured) | Separate hotkey (`transcribe_with_post_process`) |
| **Prompt** | Hardcoded system prompt | User-editable templates with `${output}` placeholder |
| **Structured output** | No | Yes (JSON schema mode where supported) |
| **Offline LLM** | No | Yes — Ollama (local) + Apple Intelligence (macOS 26+) |
| **Key storage** | macOS Keychain (`SecItemAdd`) | Tauri plugin-store (file-based, per-provider) |
| **Model discovery** | Parallel probing + filtering | `/models` endpoint query |
| **Word correction** | No | Levenshtein + Soundex + n-gram matching |
| **Chinese conversion** | No | OpenCC (Traditional <-> Simplified) |

**Takeaway:** Handy is more flexible — separate hotkey for polish vs plain transcription, user-editable prompts, and offline LLM options (Ollama, Apple Intelligence). EnviousWispr has stronger key security (Keychain vs file) and more sophisticated model discovery (parallel availability probing). Handy's word correction feature is unique — phonetic + edit-distance matching against a custom word list.

---

## 5. Paste / Clipboard

| | EnviousWispr | Handy |
|---|---|---|
| **Primary method** | NSPasteboard + CGEvent Cmd+V | Multi-strategy (CtrlV, CtrlShiftV, ShiftInsert, Direct, None) |
| **Target app tracking** | Yes — captures frontmost app at recording start, re-activates it | No explicit tracking |
| **Clipboard restore** | No | Yes — saves/restores prior clipboard contents |
| **Direct typing** | No | Yes — `enigo.text()` bypasses clipboard entirely |
| **Linux tools** | N/A | wtype, xdotool, dotool, ydotool auto-detection |
| **Auto-submit** | No | Yes — optional Enter/Ctrl+Enter/Cmd+Enter after paste |
| **Trailing space** | No | Configurable trailing space after paste |

**Takeaway:** Handy's paste system is more mature. Clipboard save/restore is a nice touch (doesn't clobber user's clipboard). Direct typing mode and auto-submit are power-user features. EnviousWispr's target app tracking (re-activating the app that was focused when recording started) is a good UX detail that Handy lacks.

---

## 6. UI / UX

| | EnviousWispr | Handy |
|---|---|---|
| **UI tech** | Native SwiftUI | React + Tailwind in WebView |
| **Menu bar / Tray** | NSStatusItem with animated icon (pulsing alpha) | Tauri system tray with state icons (Idle/Recording/Transcribing) |
| **Main window** | NavigationSplitView (sidebar + detail) | Settings-only window (sidebar routing) |
| **Recording overlay** | NSPanel floating HUD (dot + waveform + timer) | NSPanel (macOS) / gtk-layer-shell (Linux), 172x36px |
| **Transcript history** | Full UI: searchable list, detail view, copy/paste/enhance actions | SQLite log with save/delete, WAV playback |
| **Settings tabs** | 4 (General, Shortcuts, AI Polish, Permissions) | 7 sections (General, Models, Post-Processing, History, Advanced, Debug, About) |
| **Onboarding** | 4-step wizard (Welcome, Mic, Accessibility, Ready) | Permission checks + model download prompt |
| **i18n** | English only | 17 languages with RTL support |
| **Dock presence** | Hidden (LSUIElement) | Hidden (system tray only) |

**Takeaway:** EnviousWispr has a richer transcript browsing experience (searchable history, detail views, enhance actions). Handy has more settings depth and 17-language UI localization. Both use floating overlays during recording. EnviousWispr's animated menu bar icon is a nice polish detail.

---

## 7. Hotkeys / Input Modes

| | EnviousWispr | Handy |
|---|---|---|
| **Toggle mode** | Control+Space (NSEvent keyDown monitor) | Configurable (handy-keys or tauri-plugin-global-shortcut) |
| **Push-to-talk** | Option hold (NSEvent flagsChanged monitor) | Configurable modifier hold |
| **Cancel** | No | Yes — dynamically registered cancel hotkey during recording |
| **Post-process hotkey** | N/A (always polishes if configured) | Separate binding for transcribe-with-LLM |
| **CLI control** | No | `handy --toggle-transcription` / `--cancel` |
| **Unix signals** | No | SIGUSR1/SIGUSR2 for shell/WM integration |
| **Debug toggle** | No | Cmd/Ctrl+Shift+D |

**Takeaway:** Handy is more configurable. The cancel hotkey, CLI remote control, and Unix signal support are power-user features. The separate transcribe-with-post-process hotkey is a good UX pattern — lets users choose per-transcription whether to polish.

---

## 8. Distribution

| | EnviousWispr | Handy |
|---|---|---|
| **Packaging** | DMG (hdiutil, no third-party tools) | DMG, .app.tar.gz, .exe, .msi, .deb, .AppImage, .rpm |
| **Signing** | Developer ID + Hardened Runtime + Notarization | Ad-hoc (macOS), Azure Trusted Signing (Windows) |
| **Auto-update** | Sparkle (EdDSA, GitHub-hosted appcast.xml) | Tauri updater (minisign, GitHub releases) |
| **Install method** | DMG drag-install | DMG, Homebrew cask, installer packages |
| **CI** | GitHub Actions (macos-14, tag-triggered) | GitHub Actions (matrix build, manual dispatch) |
| **Model hosting** | FluidAudio/WhisperKit built-in download | CDN at blob.handy.computer |

**Takeaway:** Handy's cross-platform CI matrix is much more complex but delivers to 7+ artifact formats across 3 OSes. EnviousWispr's distribution is macOS-only but with proper notarization (when Apple Developer enrollment completes). Handy has Homebrew, which is a nice install path.

---

## 9. Architecture & Code Quality

| | EnviousWispr | Handy |
|---|---|---|
| **Concurrency model** | Swift 6 strict — `@MainActor`, actors, `@Sendable` | Rust `Arc<Mutex<>>`, channels, `AtomicBool` |
| **State management** | `@Observable` AppState (single source of truth) | Zustand stores (frontend) + Rust manager structs |
| **Type bridge** | N/A (native) | tauri-specta auto-generates TS bindings from Rust |
| **Error handling** | Swift `throws` + typed enums | `anyhow::Result` + Tauri event error emission |
| **Persistence** | UserDefaults + JSON files + Keychain | tauri-plugin-store (JSON) + SQLite + files |
| **Pipeline state** | Enum state machine (idle->recording->transcribing->polishing->complete) | TranscriptionCoordinator (channel-based: Idle/Recording/Processing) |
| **Panic safety** | Swift actor isolation prevents data races | Engine extracted from Mutex before inference to prevent poisoning |

---

## 10. Feature Gap Analysis

### Features Handy has that EnviousWispr lacks

1. **Cross-platform support** (Windows, Linux)
2. **Cancel hotkey** during recording
3. **Separate hotkey for transcribe-with-LLM** vs plain transcription
4. **CLI remote control** (`--toggle-transcription`, `--cancel`)
5. **Unix signal integration** (SIGUSR1/SIGUSR2)
6. **Clipboard save/restore** (doesn't clobber user's clipboard)
7. **Direct typing mode** (bypass clipboard entirely)
8. **Auto-submit** (Enter after paste)
9. **Custom word correction** (phonetic + edit-distance)
10. **Offline LLM** (Ollama, Apple Intelligence)
11. **User-editable LLM prompts**
12. **Model unload timeout** (reclaim VRAM/RAM after idle)
13. **Audio start/stop feedback sounds**
14. **Custom GGML model support**
15. **17-language UI + RTL**
16. **Chinese Traditional/Simplified conversion**
17. **Always-on microphone mode**
18. **Homebrew cask distribution**
19. **Debug mode toggle**
20. **WAV recording history** (playback past recordings)

### Features EnviousWispr has that Handy lacks

1. **Target app tracking** — re-activates the app that was focused at recording start
2. **Parakeet v3 on CoreML/Neural Engine** (~110x real-time vs ~5x CPU)
3. **Animated menu bar icon** (pulsing alpha during processing)
4. **Rich transcript history UI** (searchable list + detail view + enhance actions)
5. **Transcript search** (full-text across history)
6. **Keychain-secured API keys** (vs file-based storage)
7. **Parallel LLM model availability probing** (tests each model, shows lock icon for unavailable)
8. **Benchmark suite** (measures real-time factor for different audio lengths)
9. **Per-transcript "Enhance" action** (polish an existing transcript after the fact)
10. **macOS notarization pipeline** (proper Gatekeeper compliance)

---

## Summary

**Handy** is a mature, cross-platform, power-user tool with deep configurability — 4 ASR engines, 5 paste strategies, CLI control, custom word correction, offline LLM, and 17 UI languages. It trades native feel for reach (WebView UI).

**EnviousWispr** is a focused macOS-native app that trades breadth for depth on Apple Silicon — Parakeet v3 on CoreML is dramatically faster than any of Handy's engines on Mac hardware. The transcript history UX and Keychain security are stronger. The architecture is clean and modern (Swift 6 strict concurrency, actors, @Observable).

### Priority gaps to consider closing

1. **Cancel hotkey** — dynamically register a cancel binding during recording
2. **Clipboard save/restore** — save prior clipboard before paste, restore after
3. **Model unload timeout** — reclaim memory after configurable idle period
4. **User-editable LLM prompts** — let users customize the polish system prompt
5. **Separate hotkey for transcribe-with-LLM** — choose per-transcription whether to polish

---

## Update — 2026-02-19

### Gaps closed since original analysis

The following items from Section 10 have been implemented in EnviousWispr:

| #  | Feature                    | Status  | Notes                                                             |
|----|----------------------------|---------|-------------------------------------------------------------------|
| 1  | Cancel hotkey              | Done    | Escape key cancels active recording                               |
| 5  | Clipboard save/restore     | Done    | Prior clipboard saved before paste, restored after                |
| 6  | ~~Direct typing mode~~     | Skipped | macOS-only, CGEvent paste is reliable enough                      |
| 10 | Offline LLM                | Done    | Ollama (local) + Apple Intelligence (macOS 26+, FoundationModels) |
| 11 | User-editable LLM prompts  | Done    | Custom prompt editor + 3 presets (Clean Up, Formal, Casual)       |
| 12 | Model unload timeout       | Done    | Configurable idle timeout to reclaim memory                       |

### Apple Intelligence connector fixes

- **Prompt separation**: System prompt now passed via `LanguageModelSession(instructions:)` instead of being combined with transcript in a single `Prompt`
- **On-device prompt**: Simplified default prompt optimized for Apple's small model (numbered rules, concise). Falls back to user's custom prompt when non-default
- **Settings UI**: Added status indicator with refresh button (Available / Error / Checking) matching the Ollama section pattern
- **Limitation**: Cannot use `@Generable` structured output (requires Xcode macro plugin; we build with command line tools only). Handy uses this to constrain the model's output schema

### Remaining gaps (not yet implemented)

3. Separate hotkey for transcribe-with-LLM
4. CLI remote control
5. Unix signal integration
7. Auto-submit after paste
8. Custom word correction
9. Audio start/stop feedback sounds
13. Custom GGML model support
14. 17-language UI
15. Chinese Traditional/Simplified conversion
16. Always-on microphone mode
17. Homebrew cask distribution
18. Debug mode toggle
19. WAV recording history with playback
