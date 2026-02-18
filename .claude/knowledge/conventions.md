# Conventions

## Build Commands

```bash
swift build                # Build
swift run EnviousWispr      # Run
swift build --build-tests  # Verify tests compile
```

**CLI tools only** — no Xcode, no XCTest, no `#Preview`, no `xcodebuild`.

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

Scopes: `asr`, `audio`, `ui`, `llm`, `pipeline`, `settings`, `hotkey`, `vad`, `build`

## DI & State

- `AppState` (`@MainActor @Observable`) is the root DI container
- Subsystems are `let` properties on AppState
- Views inject via `@Environment(AppState.self)`
- `@Bindable var state = appState` for two-way bindings

## Settings Persistence

- **Non-sensitive:** `UserDefaults.standard` with `didSet` pattern
- **Sensitive (API keys):** `KeychainManager` (service: `"com.enviouswispr.api-keys"`)

## View Patterns

- `Form { ... }.formStyle(.grouped)` for settings
- `TabView` with labeled tabs for Settings window
- `NavigationSplitView` for main window
- `.task { }` for async on-appear work

## Required Imports

```swift
@preconcurrency import FluidAudio     // VAD, Parakeet
@preconcurrency import WhisperKit     // WhisperKit backend
@preconcurrency import AVFoundation   // Audio capture
```
