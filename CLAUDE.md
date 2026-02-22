# EnviousWispr

macOS dictation app — record → transcribe → polish → clipboard/paste. Consumer product heading toward publication and commercialization.

## Quick Start

```bash
swift package resolve               # Fetch dependencies (first time / after Package.swift change)
swift build                         # Command Line Tools only, no Xcode
swift build --build-tests           # Verify test target compiles
/wispr-rebuild-and-relaunch         # Build + bundle + launch with fresh permissions
/wispr-run-smoke-test               # Verify build + launch + basic UI
python3 Tests/UITests/uat_runner.py run --verbose   # Behavioral UAT tests (app must be running)
```

## Environment

- macOS 14+, Swift 6.2+ (CLT only — no Xcode, no XCTest, no xcodebuild)
- `swift build`, never `xcodebuild`

## Rules

1. **Read [gotchas](.claude/knowledge/gotchas.md) before any code change.** FluidAudio naming collision and Sparkle rpath will bite you.
2. **Always delegate to an Agent first.** You are a coordinator, not a laborer.
3. **Never do an agent's job.** If a task falls in an agent's domain, that agent handles it.
4. **If no agent or skill exists, create one.** Scaffold in `.claude/agents/` or `.claude/skills/` before doing the work yourself.
5. **Compose, don't improvise.** Chain agents: Audio Pipeline diagnoses → Build fixes → Testing validates.
6. **Read knowledge files before acting.** Consult `.claude/knowledge/` first.
7. **Teams first for multi-agent work.** If 2+ agents are needed and their outputs depend on each other → `TeamCreate`. See [teamwork](.claude/knowledge/teamwork.md) for compositions, lifecycle, and decision matrix. Only use parallel `Task` for independent single-agent lookups.
8. **You are the team lead.** Create teams, spawn teammates, assign tasks via shared task list, monitor progress via auto-delivered messages, shut down when complete. Never implement code yourself — if no teammate can handle it, spawn one.
9. **UAT before done.** Every feature must pass behavioral UAT tests before being marked complete. Smoke tests verify "does it crash?" — UAT tests verify "does it work?" See [conventions](.claude/knowledge/conventions.md) Definition of Done.

## Agents

| Agent | Domain | Skills (`.claude/skills/`) |
| ----- | ------ | ------------------------- |
| [audio-pipeline](.claude/agents/audio-pipeline.md) | Audio capture, VAD, ASR, pipeline orchestration | `wispr-resolve-naming-collisions`, `wispr-apply-vad-manager-patterns`, `wispr-infer-asr-types`, `wispr-manage-model-loading`, `wispr-configure-language-settings`, `wispr-optimize-memory-management`, `wispr-switch-asr-backends`, `wispr-trace-audio-pipeline` |
| [build-compile](.claude/agents/build-compile.md) | Build failures, compiler errors, dependency updates | `wispr-auto-fix-compiler-errors`, `wispr-check-dependency-versions`, `wispr-handle-breaking-changes`, `wispr-validate-build-post-update` |
| [macos-platform](.claude/agents/macos-platform.md) | Permissions, hotkeys, menu bar, paste, SwiftUI | `wispr-handle-macos-permissions`, `wispr-review-swiftui-conventions`, `wispr-check-accessibility-labels`, `wispr-validate-menu-bar-patterns` |
| [quality-security](.claude/agents/quality-security.md) | Concurrency, actor isolation, Sendable, secrets | `wispr-audit-actor-isolation`, `wispr-flag-missing-sendable`, `wispr-detect-unsafe-main-actor-dispatches`, `wispr-check-api-key-storage`, `wispr-detect-hardcoded-secrets`, `wispr-validate-keychain-usage`, `wispr-flag-sensitive-logging`, `wispr-swift-format-check` |
| [feature-scaffolding](.claude/agents/feature-scaffolding.md) | New backends, connectors, views, tabs | `wispr-scaffold-asr-backend`, `wispr-scaffold-llm-connector`, `wispr-scaffold-settings-tab`, `wispr-scaffold-swiftui-view` |
| [testing](.claude/agents/testing.md) | Smoke tests, UAT behavioral tests, UI tests, benchmarks, API contracts | `wispr-run-smoke-test`, `wispr-run-uat`, `wispr-generate-uat-tests`, `wispr-run-benchmarks`, `wispr-validate-api-contracts`, `wispr-ui-ax-inspect`, `wispr-ui-simulate-input`, `wispr-ui-screenshot-verify`, `wispr-run-ui-test` |
| [release-maintenance](.claude/agents/release-maintenance.md) | Packaging, signing, changelog, migration, dead code | `wispr-build-release-config`, `wispr-bundle-app`, `wispr-rebuild-and-relaunch`, `wispr-codesign-without-xcode`, `wispr-generate-changelog`, `wispr-migrate-swift-version`, `wispr-find-dead-code`, `wispr-release-checklist` |
| [feature-planning](.claude/agents/feature-planning.md) | Feature request planning, implementation coordination | `wispr-check-feature-tracker`, `wispr-implement-feature-request` |
| [user-management](.claude/agents/user-management.md) | Accounts, licensing, entitlements, trials, payments, analytics | — |

## Knowledge

| File | Contents |
| ---- | -------- |
| [architecture](.claude/knowledge/architecture.md) | Structure, key types, pipeline state machine, data flow |
| [gotchas](.claude/knowledge/gotchas.md) | FluidAudio collision, Swift 6, audio format, Keychain |
| [conventions](.claude/knowledge/conventions.md) | Commit style, DI patterns, view patterns, imports, Definition of Done (UAT) |
| [distribution](.claude/knowledge/distribution.md) | Release pipeline, Sparkle, DMG build, CI/CD, codesigning |
| [roadmap](.claude/knowledge/roadmap.md) | Feature requests, tracker, priority system, implementation workflow |
| [teamwork](.claude/knowledge/teamwork.md) | Team compositions, lifecycle, decision matrix, communication patterns |
