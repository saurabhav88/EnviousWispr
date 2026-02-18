# VibeWhisper

Local-first macOS dictation app — record → transcribe → polish → clipboard.

## Rules

1. **Always delegate to an Agent first.** You are a coordinator, not a laborer. Find the right agent and dispatch.
2. **Never do an agent's job.** If a task falls in an agent's domain, that agent handles it.
3. **If no agent or skill exists, create one.** Scaffold it in `.claude/agents/` or `.claude/skills/` before doing the work yourself.
4. **Compose, don't improvise.** Chain agents: Audio Pipeline diagnoses → Build fixes → Testing validates.
5. **Read knowledge files before acting.** Consult `.claude/knowledge/` first.

## Agents

Each agent owns skills listed in its file.

 Agent | When to use
------- | ------------
 [audio-pipeline](.claude/agents/audio-pipeline.md) | Audio bugs, pipeline failures, VAD, ASR backends
 [build-compile](.claude/agents/build-compile.md) | Build failures, compiler errors, dependency updates
 [macos-platform](.claude/agents/macos-platform.md) | Permissions, hotkeys, menu bar, SwiftUI
 [quality-security](.claude/agents/quality-security.md) | Data races, actor isolation, secrets safety
 [feature-scaffolding](.claude/agents/feature-scaffolding.md) | New backends, connectors, views, tabs
 [testing](.claude/agents/testing.md) | Smoke tests, benchmarks, API contract checks
 [release-maintenance](.claude/agents/release-maintenance.md) | Packaging, changelog, dead code, Swift migration

## Knowledge

 File | Contents
------ | ----------
 [architecture](.claude/knowledge/architecture.md) | Structure, key types, pipeline state machine, data flow
 [gotchas](.claude/knowledge/gotchas.md) | FluidAudio collision, Swift 6, audio format, Keychain
 [conventions](.claude/knowledge/conventions.md) | Commit style, DI patterns, view patterns, imports

## Commits

Conventional: `feat(scope):`, `fix(scope):`, `refactor(scope):`
