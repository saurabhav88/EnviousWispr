# Conventions

## Build Commands

```bash
swift build                # Build
swift run EnviousWispr      # Run
swift build --build-tests  # Verify tests compile
```

**CLI tools only** — no Xcode, no XCTest, no `#Preview`, no `xcodebuild`.

## App Lifecycle: Always Reset Accessibility

Whenever the app is killed, deleted, or rebuilt before relaunch, **always** reset the Accessibility TCC entry:

```bash
pkill -x EnviousWispr 2>/dev/null; tccutil reset Accessibility com.enviouswispr.app
```

This removes the stale Accessibility permission so the user doesn't have to manually remove it from System Settings. The app will re-prompt on next launch.

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

## Release & Versioning

- Semver tags: `v1.0.0`, `v1.1.0`, etc. — `v` prefix required (triggers CI)
- `scripts/build-dmg.sh <version>` for local builds
- CI auto-updates `appcast.xml` on main after each release
- Changelog: `generate-changelog` skill or `git log --oneline v1.0.0..HEAD`

## Required Imports

```swift
@preconcurrency import FluidAudio     // VAD, Parakeet
@preconcurrency import WhisperKit     // WhisperKit backend
@preconcurrency import AVFoundation   // Audio capture
```
