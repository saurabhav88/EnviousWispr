# Conventions

## Build Commands

```bash
swift build                # Debug build
swift build -c release     # Release build (for .app bundle)
swift build --build-tests  # Verify tests compile
```

**CLI tools only** — no Xcode, no XCTest, no `#Preview`, no `xcodebuild`.

## Bundle Workflow: Avoid Stale Binaries

`swift build` compiles to `.build/debug/` (or `.build/release/`), but the **running app** is at `build/EnviousWispr.app`. These are separate binaries.

After ANY code change during feature work:

**MANDATORY: Always invoke `/wispr-rebuild-and-relaunch`** — this is the only path that ensures the running .app matches your source code.

- `/wispr-rebuild-and-relaunch` chains: release build → bundle → kill old process → relaunch → process check
- `/wispr-run-smoke-test` is compile-only (no launch); use it only as a fast pre-check, NOT as a substitute

Never test code changes via `swift build` alone — the binary at `.build/release/` is not what users run. Always rebuild and relaunch the .app bundle.

## App Lifecycle

When killing/rebuilding the app, kill the old process before relaunching:

```bash
pkill -x EnviousWispr 2>/dev/null; sleep 1
```

Accessibility permission is required for paste (`CGEvent.post`). When testing paste after a fresh bundle, ensure Accessibility is granted via System Settings > Privacy & Security > Accessibility.

## Commit Style

Conventional commits: `type(scope): message` (squash-merged on main — each PR becomes one commit)

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
- **Sensitive (API keys):** `KeychainManager` — file-based storage at `~/.enviouswispr-keys/` (dir 0700, files 0600). Never macOS Keychain. See [gotchas.md](gotchas.md) for rationale

## View Patterns

- `Form { ... }.formStyle(.grouped)` for settings
- `NavigationSplitView` with sidebar List for Settings window (SettingsSection enum)
- `NavigationSplitView` for main window
- `.task { }` for async on-appear work

## Release & Versioning

- **Semver tags:** `v1.0.0`, `v1.1.0`, etc. — `v` prefix required (triggers CI for release builds)
- **Local development:** `swift build`, `/wispr-rebuild-and-relaunch`, or `./scripts/build-dmg.sh` (no version arg) produce builds tagged with `-local` in the version string (e.g., `0.0.0-local`)
- **Release builds:** `git tag v1.0.0 && git push origin v1.0.0` (CI) or `./scripts/build-dmg.sh 1.0.0` (explicit). Clean version numbers, distributed via GitHub Releases.
- **Lean workflow:** Direct pushes to `main` or PRs — both work. `build-check` runs on PRs for visibility but isn't required. No required reviews (lean team). See [github-workflow](github-workflow.md).
- CI generates `appcast.xml` on each release; the release workflow pushes it directly to `main` via built-in `GITHUB_TOKEN`
- Changelog: `generate-changelog` skill or `git log --oneline v1.0.0..HEAD`

## Required Imports

See [swift-patterns.md](../rules/swift-patterns.md) for the full list of required `@preconcurrency import` statements.

## Definition of Done — Features

A feature is NOT done until ALL of these pass:

1. `swift build -c release` exits 0
2. `swift build --build-tests` exits 0
3. .app bundle rebuilt + relaunched (`wispr-rebuild-and-relaunch`)
4. **Wispr Eyes verification passes** (`wispr-eyes` — agent-native UI verification of the running app)
5. Only `type_text`/`press_key` need `run_in_background: true` — all other verification works in foreground via AX APIs
6. **CI `build-check` green** (informational — not required for merge, but check for visibility)
7. **Update affected brain files** — if new types/files/settings added, run `scripts/brain-refresh.sh`
8. **Close corresponding bead** — `bd close <id> --reason "..."`

### Verification: Two Modes Only

| Mode       | Invocation                     | Scope source                                          |
| ---------- | ------------------------------ | ----------------------------------------------------- |
| **Smart**  | `/wispr-eyes`                  | Completed todos → conversation context                |
| **Custom** | `/wispr-eyes "verify X"`       | Your explicit instruction                             |

### Verification Workflow for Every Feature

1. After implementing code → invoke `wispr-eyes`
2. Wispr Eyes dispatches a Sonnet agent that connects to the running app, navigates, inspects, and reports in plain English
3. Review results — VERIFIED/ISSUE/BLOCKED per scope item
4. If scope has no UI-observable changes, Wispr Eyes reports SKIPPED — this is valid
5. Only commit when all scope items are VERIFIED (or validly SKIPPED)

### Todo Quality for Verification

When creating todos for code work, include what changed, where, and user-visible result:

Format: `Fix X in Y (user-visible result Z)`

Start a fresh todo list for each project. Wispr Eyes uses completed todos from the active project only.

## Brand & Visual Design

All visual artifacts (HTML mockups, diagrams, landing pages) MUST use the brand design system at `.claude/skills/brand-guide/SKILL.md`. Key tokens:

- **Accent:** `#7c3aed` (purple) — selected states, buttons, links
- **Fonts:** Plus Jakarta Sans (web), system-ui (macOS settings), JetBrains Mono (code)
- **Surfaces:** `#f8f5ff` (bg), `#f0ecf9` (cards) — warm lavender tint
- **Rainbow gradient:** Brand signature for hero elements and premium features
- **macOS settings:** Use system-ui fonts + brand accent purple instead of default blue

## Feature Request Docs

Feature request specs live in `docs/feature-requests/`. See `.claude/knowledge/roadmap.md` for the full format template.

Key conventions:
- One file per feature, zero-padded ID: `NNN-feature-name.md`
- Status tracked in Beads (`bd ready`, `bd stats`)
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
