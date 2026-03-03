# EnviousWispr

macOS dictation app — record → transcribe → polish → clipboard/paste. Consumer product heading toward publication and commercialization.

## Quick Start

```bash
swift package resolve               # Fetch dependencies (first time / after Package.swift change)
swift build                         # Command Line Tools only, no Xcode
swift build -c release              # Release build (for .app bundle / distribution)
swift build --build-tests           # Verify test target compiles
swift package clean                 # Clear build cache (fixes stale-cache build errors)
/wispr-rebuild-and-relaunch         # Build + bundle + launch with fresh permissions
/wispr-run-smoke-test               # Fast compile gate (no launch/UAT)
python3 Tests/UITests/uat_runner.py run --files Tests/UITests/generated/<test>.py --verbose   # UAT tests (app running, MUST use run_in_background:true)
```

## Environment

- macOS 14+, Swift 6 language mode (`swift-tools-version: 6.0`), runtime 6.2+ (CLT only — no Xcode, no XCTest, no xcodebuild)
- `swift build`, never `xcodebuild`
- Dependencies: FluidAudio 0.12+, WhisperKit 0.12+, Sparkle 2.6+

## Rules

1. **Read [gotchas](.claude/knowledge/gotchas.md) before any code change.** FluidAudio naming collision and Sparkle rpath will bite you.
2. **Always delegate to an Agent first.** You are a coordinator, not a laborer.
3. **Never do an agent's job.** If a task falls in an agent's domain, that agent handles it.
4. **If no agent or skill exists, create one.** Scaffold in `.claude/agents/` or `.claude/skills/` before doing the work yourself. For trivial one-off tasks (a debug print, a single-line fix), proceed directly and state your reasoning.
5. **Compose, don't improvise.** Chain agents: Audio Pipeline diagnoses → Build fixes → Testing validates.
6. **Read knowledge files before acting.** Consult `.claude/knowledge/` first.
7. **Teams first for multi-agent work.** If 2+ agents are needed and their outputs depend on each other → `TeamCreate`. See [teamwork](.claude/knowledge/teamwork.md) for compositions, lifecycle, and decision matrix. Only use parallel `Task` for independent single-agent lookups.
8. **You are the team lead.** Create teams, spawn teammates, assign tasks via shared task list, monitor progress via auto-delivered messages, shut down when complete. Never implement code yourself — if no teammate can handle it, spawn one.
9. **Smart UAT before done.** Every feature must pass behavioral UAT tests before being marked complete. Use `wispr-run-smart-uat` for scope-driven testing (from completed todos or explicit task). All UAT execution MUST use `run_in_background: true`. See [conventions](.claude/knowledge/conventions.md) Definition of Done.

## Agents

| Agent | Domain | Skills (`.claude/skills/`) |
| ----- | ------ | ------------------------- |
| [audio-pipeline](.claude/agents/audio-pipeline.md) | Audio capture, VAD, ASR, pipeline orchestration | `wispr-resolve-naming-collisions`, `wispr-apply-vad-manager-patterns`, `wispr-infer-asr-types`, `wispr-manage-model-loading`, `wispr-configure-language-settings`, `wispr-optimize-memory-management`, `wispr-switch-asr-backends`, `wispr-trace-audio-pipeline` |
| [build-compile](.claude/agents/build-compile.md) | Build failures, compiler errors, dependency updates | `wispr-auto-fix-compiler-errors`, `wispr-check-dependency-versions`, `wispr-handle-breaking-changes`, `wispr-validate-build-post-update` |
| [macos-platform](.claude/agents/macos-platform.md) | Permissions, hotkeys, menu bar, paste, SwiftUI | `wispr-handle-macos-permissions`, `wispr-review-swiftui-conventions`, `wispr-check-accessibility-labels`, `wispr-validate-menu-bar-patterns` |
| [quality-security](.claude/agents/quality-security.md) | Concurrency, actor isolation, Sendable, secrets | `wispr-audit-actor-isolation`, `wispr-flag-missing-sendable`, `wispr-detect-unsafe-main-actor-dispatches`, `wispr-check-api-key-storage`, `wispr-detect-hardcoded-secrets`, `wispr-validate-keychain-usage`, `wispr-flag-sensitive-logging`, `wispr-swift-format-check` |
| [feature-scaffolding](.claude/agents/feature-scaffolding.md) | New backends, connectors, views, tabs | `wispr-scaffold-asr-backend`, `wispr-scaffold-llm-connector`, `wispr-scaffold-settings-tab`, `wispr-scaffold-swiftui-view` |
| [testing](.claude/agents/testing.md) | Smoke tests, UAT behavioral tests, benchmarks, API contracts | `wispr-run-smoke-test`, `wispr-run-smart-uat`, `wispr-generate-uat-tests`, `wispr-run-benchmarks`, `wispr-validate-api-contracts`, `wispr-ui-ax-inspect`, `wispr-ui-simulate-input`, `wispr-ui-screenshot-verify` |
| [uat-generator](.claude/agents/uat-generator.md) | LLM-driven UAT test generation from project scope | — (invoked by `wispr-run-smart-uat`) |
| [release-maintenance](.claude/agents/release-maintenance.md) | Packaging, signing, changelog, migration, dead code | `wispr-build-release-config`, `wispr-bundle-app`, `wispr-rebuild-and-relaunch`, `wispr-codesign-without-xcode`, `wispr-generate-changelog`, `wispr-migrate-swift-version`, `wispr-find-dead-code`, `wispr-release-checklist` |
| [feature-planning](.claude/agents/feature-planning.md) | Feature request planning, implementation coordination | `wispr-check-feature-tracker`, `wispr-implement-feature-request` |
| [user-management](.claude/agents/user-management.md) | Accounts, licensing, entitlements, trials, payments, analytics | — |
| [frontend-designer](.claude/agents/frontend-designer.md) | Interactive diagrams, dashboards, HTML artifacts, visual design | — (multi-turn, browser-verified) |

## Knowledge

| File | Contents |
| ---- | -------- |
| [swift-patterns](.claude/rules/swift-patterns.md) | **Auto-loaded.** FluidAudio `Module.Type` shadowing workaround, `@preconcurrency` import list |
| [architecture](.claude/knowledge/architecture.md) | App structure, key protocols/actors, pipeline state machine, full data flow diagram |
| [gotchas](.claude/knowledge/gotchas.md) | 20+ non-obvious traps: FluidAudio collision, Swift 6 concurrency, audio format, Keychain, Sparkle rpath |
| [conventions](.claude/knowledge/conventions.md) | Commit message style, DI patterns, SwiftUI view patterns, import order, Definition of Done (UAT) |
| [distribution](.claude/knowledge/distribution.md) | Two-tier build model, Sparkle auto-update, DMG build script, CI/CD workflow, codesigning |
| [roadmap](.claude/knowledge/roadmap.md) | 20 feature requests, tracker, priority tiers, implementation workflow, agent mapping |
| [teamwork](.claude/knowledge/teamwork.md) | Standard team compositions, lifecycle protocol, decision matrix, communication patterns |
| [file-index](.claude/knowledge/file-index.md) | Every Swift source file (64 files, ~10,856 lines) — path, line count, key types, purpose |
| [type-index](.claude/knowledge/type-index.md) | Reverse lookup — every protocol, actor, class, struct, enum → file path + isolation |
| [task-router](.claude/knowledge/task-router.md) | Common task patterns → exact files to change, agent to dispatch, skill to invoke |
| [github-workflow](.claude/knowledge/github-workflow.md) | Branch protection, PR checks, CODEOWNERS, Dependabot, security scanning |
