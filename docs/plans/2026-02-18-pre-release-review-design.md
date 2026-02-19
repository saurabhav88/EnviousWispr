# Pre-v1.0 Comprehensive Code Review & Cleanup

## Goal

Audit and clean up the EnviousWispr codebase before tagging v1.0. Ship-ready code with no security issues, dead code, or consistency problems.

## Approach

Parallel Agent Swarm: dispatch 4 domain agents simultaneously, triage findings, fix by priority, verify.

## Phases

### Phase 1 — Parallel Audit

| Agent | Scope | Checks |
|-------|-------|--------|
| quality-security | All 35 source files | API key leaks, Sendable violations, actor isolation bugs, sensitive logging, Keychain misuse |
| build-compile | Package.swift, build config | Build health, dependency versions, compiler warnings, unused deps |
| release-maintenance | Entire tree | Dead code, unused imports, stale artifacts, bundle readiness |
| code-reviewer (superpowers) | All source + untracked files | Logic bugs, code quality, consistency, error handling, naming |

Each agent produces findings with severity: critical / high / medium / low.

### Phase 2 — Triage

- Merge all findings, deduplicate
- Present prioritized list to user for approval before making changes

### Phase 3 — Fix

- Execute fixes in priority order (critical → high → medium → low)
- Group related fixes into logical commits (conventional commit style)
- Include untracked file decisions (PromptTemplates.swift, MenuBar/ directory)

### Phase 4 — Verify

- `swift build` to confirm compilation
- Smoke test to confirm app launches
- Final `git status` review

## In Scope

- Security: secrets, logging, Keychain usage
- Concurrency: actor isolation, Sendable, MainActor dispatches
- Code quality: dead code, unused imports, naming consistency
- Untracked files: review and decide inclusion
- Build health: warnings, dependency freshness
- Release readiness: bundle config, Info.plist, entitlements

## Out of Scope

- New features
- UI redesign
- Performance optimization (unless clear bug)
