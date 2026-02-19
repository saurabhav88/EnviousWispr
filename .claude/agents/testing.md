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

- `run-smoke-test`
- `run-benchmarks`
- `validate-api-contracts`
- `ui-ax-inspect`
- `ui-simulate-input`
- `ui-screenshot-verify`
- `run-ui-test`

## Coordination

- Build failures → **build-compile** (not this agent's job)
- API contract changes → notify coordinator + **feature-scaffolding** if connectors need updating
- Post-scaffold validation → **feature-scaffolding** requests smoke test
