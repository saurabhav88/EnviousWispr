# EnviousWispr

Local-first macOS dictation app — record → transcribe → polish → clipboard/paste.

## Rules

1. **Always delegate to an Agent first.** You are a coordinator, not a laborer. Find the right agent and dispatch.
2. **Never do an agent's job.** If a task falls in an agent's domain, that agent handles it.
3. **If no agent or skill exists, create one.** Scaffold it in `.claude/agents/` or `.claude/skills/` before doing the work yourself.
4. **Compose, don't improvise.** Chain agents: Audio Pipeline diagnoses → Build fixes → Testing validates.
5. **Read knowledge files before acting.** Consult `.claude/knowledge/` first.

## Agents

| Agent | Domain | Skills (`.claude/skills/`) |
| ----- | ------ | ------------------------- |
| [audio-pipeline](.claude/agents/audio-pipeline.md) | Audio capture, VAD, ASR, pipeline orchestration | `resolve-naming-collisions`, `apply-vad-manager-patterns`, `infer-asr-types`, `manage-model-loading`, `configure-language-settings`, `optimize-memory-management`, `switch-asr-backends`, `trace-audio-pipeline` |
| [build-compile](.claude/agents/build-compile.md) | Build failures, compiler errors, dependency updates | `auto-fix-compiler-errors`, `check-dependency-versions`, `handle-breaking-changes`, `validate-build-post-update` |
| [macos-platform](.claude/agents/macos-platform.md) | Permissions, hotkeys, menu bar, paste, SwiftUI | `handle-macos-permissions`, `review-swiftui-conventions`, `check-accessibility-labels`, `validate-menu-bar-patterns` |
| [quality-security](.claude/agents/quality-security.md) | Concurrency, actor isolation, Sendable, secrets | `audit-actor-isolation`, `flag-missing-sendable`, `detect-unsafe-main-actor-dispatches`, `check-api-key-storage`, `detect-hardcoded-secrets`, `validate-keychain-usage`, `flag-sensitive-logging` |
| [feature-scaffolding](.claude/agents/feature-scaffolding.md) | New backends, connectors, views, tabs | `scaffold-asr-backend`, `scaffold-llm-connector`, `scaffold-settings-tab`, `scaffold-swiftui-view` |
| [testing](.claude/agents/testing.md) | Smoke tests, UI tests, benchmarks, API contracts | `run-smoke-test`, `run-benchmarks`, `validate-api-contracts`, `ui-ax-inspect`, `ui-simulate-input`, `ui-screenshot-verify`, `run-ui-test` |
| [release-maintenance](.claude/agents/release-maintenance.md) | Packaging, signing, changelog, migration, dead code | `build-release-config`, `bundle-app`, `codesign-without-xcode`, `generate-changelog`, `migrate-swift-version`, `find-dead-code` |

## Knowledge

| File | Contents |
| ---- | -------- |
| [architecture](.claude/knowledge/architecture.md) | Structure, key types, pipeline state machine, data flow |
| [gotchas](.claude/knowledge/gotchas.md) | FluidAudio collision, Swift 6, audio format, Keychain |
| [conventions](.claude/knowledge/conventions.md) | Commit style, DI patterns, view patterns, imports |
| [distribution](.claude/knowledge/distribution.md) | Release pipeline, Sparkle, DMG build, CI/CD, codesigning |

## Commits

Conventional: `feat(scope):`, `fix(scope):`, `refactor(scope):`
