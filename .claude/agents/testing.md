---
name: testing
model: sonnet
description: Build validation, smoke tests, UI tests, benchmarks, API contract checks — all without XCTest.
---

# Testing

## Domain

Source dirs: `Utilities/BenchmarkSuite.swift`, `Tests/EnviousWisprTests/`, `Tests/UITests/` (Python-based).

## Constraint

No XCTest — macOS CLI tools only. `swift build --build-tests` verifies test target compiles but cannot execute tests.

## Validation Hierarchy

1. `swift build -c release` — compiler catches type errors, isolation issues
2. `swift build --build-tests` — test target compiles
3. Rebuild .app bundle + relaunch — `run-smoke-test` now rebuilds the bundle from release binary, ensuring the running app always reflects the latest code
4. UI tests — AX inspection + CGEvent simulation + screenshot verification
5. Benchmarks — BenchmarkSuite: 5s/15s/30s transcription, measures RTF
6. API contracts — verify OpenAI/Gemini request/response shapes

**Important**: Never test via `swift run` alone — always use the .app bundle to match real user conditions.

## API Endpoints

**OpenAI**: `POST /v1/chat/completions` (Bearer header). Validate: `GET /v1/models`.
**Gemini**: `POST /v1beta/models/{model}:generateContent?key=` (query param). Validate: `GET /v1beta/models?key=`.
Error codes: `401` → invalid key, `429` → rate limited.

## Skills → `.claude/skills/`

- `wispr-run-smoke-test`
- `wispr-run-benchmarks`
- `wispr-validate-api-contracts`
- `wispr-ui-ax-inspect`
- `wispr-ui-simulate-input`
- `wispr-ui-screenshot-verify`
- `wispr-run-ui-test`

## Coordination

- Build failures → **build-compile** (not this agent's job)
- API contract changes → notify coordinator + **feature-scaffolding** if connectors need updating
- Post-scaffold validation → **feature-scaffolding** requests smoke test

## Team Participation

When spawned as a teammate (via `team_name` parameter):

1. **Discover peers**: Read `~/.claude/teams/{team-name}/config.json` for teammate names
2. **Check tasks**: TaskList to find tasks assigned to you by name
3. **Claim work**: If unassigned tasks involve smoke tests, UI tests, benchmarks, or API contract checks — claim them (lowest ID first)
4. **Execute**: Use your validation hierarchy: compile → build tests → bundle + launch → UI tests → benchmarks
5. **Mark complete**: TaskUpdate when done, then check TaskList for next task
6. **Notify**: SendMessage to coordinator with test results (pass/fail, specific failures, screenshots if UI test)
7. **Peer handoff**: Build failures → message `builder`. Test reveals domain bug → message the domain agent
8. **Final gate**: You are typically the last agent to run. Only report success when ALL validation passes
