# Conventions

## Build Commands

```bash
swift build                # Debug build
swift build -c release     # Release build (for .app bundle)
swift build --build-tests  # Verify tests compile
```

**CLI tools only** — no Xcode, no XCTest, no `#Preview`, no `xcodebuild`.

## Bundle Workflow: Avoid Stale Binaries

`swift build` compiles to `.build/debug/` (or `.build/release/`), but the **running app** is at `build/EnviousWispr.app`. These are separate binaries. After any code change:

1. Use `rebuild-and-relaunch` skill — chains release build → bundle → kill → relaunch
2. Or use `run-smoke-test` — automatically rebuilds the bundle before launching

**Never test code changes via `swift run` alone** — always rebuild the .app bundle so runtime behavior matches what the user sees.

## App Lifecycle

When killing/rebuilding the app, kill the old process before relaunching:

```bash
pkill -x EnviousWispr 2>/dev/null; sleep 1
```

Accessibility permission is required for paste (`CGEvent.post`). When testing paste after a fresh bundle, ensure Accessibility is granted via System Settings > Privacy & Security > Accessibility.

## Commit Style

Conventional commits: `type(scope): message`

| Type | Use |
|------|-----|
| `feat` | New feature |
| `fix` | Bug fix |
| `refactor` | Code restructuring |
| `docs` | Documentation |
| `chore` | Maintenance |
| `test` | Testing |
| `perf` | Performance |

Scopes: `asr`, `audio`, `ui`, `llm`, `pipeline`, `settings`, `hotkey`, `vad`, `build`, `user`, `release`

## DI & State

- `AppState` (`@MainActor @Observable`) is the root DI container
- Subsystems are `let` properties on AppState
- Views inject via `@Environment(AppState.self)`
- `@Bindable var state = appState` for two-way bindings

## Settings Persistence

- **Non-sensitive:** `UserDefaults.standard` with `didSet` pattern
- **Sensitive (API keys):** `KeychainManager` (service: `"com.enviouswispr.api-keys"`). Uses `#if DEBUG` pattern: file-based storage in debug, real macOS Keychain in release

## View Patterns

- `Form { ... }.formStyle(.grouped)` for settings
- `TabView` with labeled tabs for Settings window
- `NavigationSplitView` for main window
- `.task { }` for async on-appear work

## Release & Versioning

- Semver tags: `v1.0.0`, `v1.1.0`, etc. — `v` prefix required (triggers CI)
- `scripts/build-dmg.sh <version>` for local builds
- CI generates `appcast.xml` on each release (gitignored locally)
- Changelog: `generate-changelog` skill or `git log --oneline v1.0.0..HEAD`

## Required Imports

```swift
@preconcurrency import FluidAudio     // VAD, Parakeet
@preconcurrency import WhisperKit     // WhisperKit backend
@preconcurrency import AVFoundation   // Audio capture
```

## Definition of Done — Features

A feature is NOT done until ALL of these pass:

1. `swift build -c release` exits 0
2. `swift build --build-tests` exits 0
3. .app bundle rebuilt + relaunched (`wispr-rebuild-and-relaunch`)
4. **Smart UAT tests pass** (`wispr-run-smart-uat` — scope-driven, generates targeted tests for the current project)
5. All UAT execution MUST use `run_in_background: true` — foreground fails due to CGEvent/VSCode collision

### UAT: Two Modes Only

| Mode       | Invocation                     | Scope source                                          |
| ---------- | ------------------------------ | ----------------------------------------------------- |
| **Smart**  | `/wispr-run-smart-uat`         | Completed todos → conversation context → diff fallback |
| **Custom** | `/wispr-run-smart-uat "test X"` | Your explicit instruction                             |

There is no separate "static UAT" or "full UAT" mode. Static test functions exist in `uat_runner.py` but are not a distinct workflow tier.

### UAT Workflow for Every Feature

1. After implementing code → invoke `wispr-run-smart-uat`
2. Smart UAT wipes `Tests/UITests/generated/`, builds scope from completed todos (or conversation context), generates targeted tests, runs them in background
3. Review results — generated test failures may indicate real bugs or test generation issues
4. If scope has no UI-observable changes, Smart UAT reports SKIPPED — this is valid
5. Only commit when generated tests pass (or are validly skipped)
6. Generated tests are ephemeral — wiped at the start of every run, never accumulate

### Todo Quality for UAT

When creating todos for code work, include what changed, where, and user-visible result:

Format: `Fix X in Y (user-visible result Z)`

Start a fresh todo list for each project. Smart UAT uses completed todos from the active project only.

## Feature Request Docs

Feature request specs live in `docs/feature-requests/`. See `.claude/knowledge/roadmap.md` for the full format template.

Key conventions:
- One file per feature, zero-padded ID: `NNN-feature-name.md`
- Status tracked in `TRACKER.md` (source of truth)
- Implementation plans written before any code
- Commit scope matches primary code area: `feat(hotkey):`, `feat(clipboard):`, etc.

## LLM Connector Architecture

- Each connector is a `struct` conforming to `TranscriptPolisher: Sendable`
- Takes `KeychainManager` in init only if needing API keys
- Supports batch and streaming via optional `onToken: (@Sendable (String) -> Void)?` callback
- All handle HTTP errors with `LLMError` enum (`invalidAPIKey`, `requestFailed`, `rateLimited`, etc.)
- Truncation detection: check `finish_reason == "length"` and log warnings
- Extended thinking: `LLMProviderConfig` carries `thinkingBudget: Int?` (Gemini 2.5) and `reasoningEffort: String?` (OpenAI o-series). `LLMPolishStep.resolveThinkingConfig()` maps `useExtendedThinking` toggle to provider-specific params.

## Text Processing Pipeline Steps

- `@MainActor protocol TextProcessingStep` — chainable post-ASR processing
- Properties: `name: String`, `isEnabled: Bool`
- Method: `process(_ context: TextProcessingContext) async throws -> TextProcessingContext`
- Implementations: `WordCorrectionStep` (fuzzy matching), `LLMPolishStep` (LLM polish)
- Steps executed in order via `textProcessingSteps` array in `TranscriptionPipeline`
- `isEnabled` gate prevents unnecessary processing

## Logging Convention

- Use `AppLogger.shared` actor — always `await` at call site
- `log(_ message:, level:, category:)` — levels: `.verbose`, `.debug`, `.info`
- Categories: `"Pipeline"`, `"LLM"`, `"Audio"`, `"PipelineTiming"`, etc.
- Dual-sink: OSLog always emitted, file logging only when debug mode enabled
- Never log API keys or secrets

## Pipeline State Management

- `PipelineState` enum: `idle`, `recording`, `transcribing`, `polishing`, `complete`, `error(String)`
- State changes trigger `onStateChange` callback (drives `MenuBarIconAnimator.IconState`)
- Helper computed properties: `isActive`, `statusText`
- `isActive` gate prevents concurrent operations
- `MenuBarIconAnimator` renders 4 icon states (idle/recording/processing/error) via Core Graphics

## Streaming Patterns

- Streaming ASR: `startStreaming()` → `feedAudio(_ buffer:)` → `finalizeStreaming()` (Parakeet only)
- Streaming LLM: `onToken` callback enables SSE for Gemini; `nil` = batch mode
- `LLMNetworkSession.shared` singleton for HTTP/2 connection reuse and TLS pre-warming
- Audio buffer forwarding: `AudioCaptureManager.onBufferCaptured` callback → `ASRManager`

## Model & Configuration Structs

- Model structs conform to `Sendable`; most also conform to `Codable` (`TranscriptionOptions` is Sendable-only)
- Static factory methods for common configs (e.g., `PolishInstructions.default`)
- Key types: `LLMProviderConfig`, `PolishInstructions`, `LLMModelInfo`, `TranscriptionOptions`

## Unified Window Architecture

- Single `NavigationSplitView` with sidebar groups via `SettingsSection` enum
- Detail pane switches via `@ViewBuilder detailContent`
- `@Bindable var state = appState` for two-way bindings in views
- Toolbar actions in primary/status placements
