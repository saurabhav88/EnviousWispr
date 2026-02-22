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

1. Use `rebuild-and-relaunch` skill — chains release build → bundle → kill → TCC reset → relaunch
2. Or use `run-smoke-test` — automatically rebuilds the bundle before launching

**Never test code changes via `swift run` alone** — always rebuild the .app bundle so runtime behavior matches what the user sees.

## App Lifecycle

When killing/rebuilding the app, kill the old process before relaunching:

```bash
pkill -x EnviousWispr 2>/dev/null; sleep 1
```

No Accessibility TCC reset is needed — the app does not use Accessibility permission.

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
- **Sensitive (API keys):** `KeychainManager` (service: `"com.enviouswispr.api-keys"`)

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
4. **UAT behavioral tests pass** (`python3 Tests/UITests/uat_runner.py run --verbose`)
5. Feature-specific UAT suite passes (if one exists)

**UAT is mandatory, not optional.** Smoke tests verify "does it crash?" UAT tests verify "does it work?"

### UAT Workflow for Every Feature

1. After implementing code → run `wispr-generate-uat-tests` to create test scenarios
2. Add tests to `Tests/UITests/uat_runner.py` with `@uat_test` decorator
3. Run `python3 Tests/UITests/uat_runner.py run --verbose`
4. Only commit when ALL tests pass
5. UAT scenario file saved at `Tests/UITests/scenarios/NNN-feature-name.md`

## Feature Request Docs

Feature request specs live in `docs/feature-requests/`. See `.claude/knowledge/roadmap.md` for the full format template.

Key conventions:
- One file per feature, zero-padded ID: `NNN-feature-name.md`
- Status tracked in `TRACKER.md` (source of truth)
- Implementation plans written before any code
- Commit scope matches primary code area: `feat(hotkey):`, `feat(clipboard):`, etc.
