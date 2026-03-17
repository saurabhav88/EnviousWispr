# Skill Consolidation Plan

**Date**: 2026-03-02
**Status**: Draft
**Goal**: 51 skills → ~35 skills. Zero knowledge lost, sharper routing, less token overhead.

## Principles

1. **Keep standalone if procedural** — multi-step workflows with ordering, error handling, and tool chaining earn their keep
2. **Consolidate if overlapping** — skills covering the same concern with different grep patterns → merge
3. **Delete if triply redundant** — content already in auto-loaded rules + knowledge files doesn't need a skill
4. **Don't demote to agent defs** — skills have discoverability (slash commands) and composability (skill→skill chaining) that agent definitions lack
5. **Meta-skills with raw args** — Claude Code passes args as a raw string; SKILL.md prose tells the LLM which section to run

## Final Skill Inventory

### KEEP AS-IS (28 skills)

**Scaffolding (4):**
- `wispr-scaffold-llm-connector` (164 lines)
- `wispr-scaffold-asr-backend` (204)
- `wispr-scaffold-settings-tab` (114)
- `wispr-scaffold-swiftui-view` (111)

**Pipelines (5):**
- `wispr-run-smart-uat` (238)
- `wispr-rebuild-and-relaunch` (126)
- `wispr-release-checklist` (219)
- `wispr-implement-feature-request` (106)
- `wispr-bundle-app` (122)

**Fix Recipes (2):**
- `wispr-auto-fix-compiler-errors` (75)
- `wispr-handle-breaking-changes` (80)

**Domain Procedures (8):**
- `wispr-configure-language-settings` (147)
- `wispr-apply-vad-manager-patterns` (87)
- `wispr-trace-audio-pipeline` (78)
- `wispr-validate-build-post-update` (118)
- `wispr-handle-macos-permissions` (117)
- `wispr-validate-api-contracts` (96)
- `wispr-optimize-memory-management` (80)
- `wispr-rotate-secrets` (99)

**Release/Build (5):**
- `wispr-codesign-without-xcode` (99)
- `wispr-generate-changelog` (84)
- `wispr-build-release-config` (65)
- `wispr-migrate-swift-version` (77)
- `wispr-find-dead-code` (80)

**Testing (2):**
- `wispr-generate-uat-tests` (192)
- `wispr-run-benchmarks` (66)

**Building Blocks (2):**
- `wispr-run-smoke-test` (40) — thin but referenced by rebuild-and-relaunch, run-smart-uat, validate-build-post-update
- `wispr-check-feature-tracker` (75) — 4-step procedure, not just "cat a file"

### NEW CONSOLIDATED SKILLS (5 new, replacing 16 old)

#### 1. `wispr-audit-secrets` (replaces 4 skills)

**Absorbs:**
- `wispr-detect-hardcoded-secrets` (63) → Section: Hardcoded Secrets Scan
- `wispr-check-api-key-storage` (63) → Section: API Key Storage Audit
- `wispr-validate-keychain-usage` (80) → Section: KeychainManager Exclusivity
- `wispr-flag-sensitive-logging` (85) → Section: Sensitive Logging Check

**Trigger description:** "Use when auditing secrets safety — hardcoded keys, API key storage, Keychain usage, or sensitive logging. Pass an optional focus: `secrets`, `keychain`, `logging`, or omit for full audit."

**Structure:**
```
# Audit Secrets Safety
## Usage
- `/wispr-audit-secrets` → runs ALL sections
- `/wispr-audit-secrets keychain` → runs KeychainManager section only
- `/wispr-audit-secrets logging` → runs sensitive logging section only

## Section 1: Hardcoded Secrets Scan
(content from detect-hardcoded-secrets)

## Section 2: API Key Storage Audit
(content from check-api-key-storage)

## Section 3: KeychainManager Exclusivity
(content from validate-keychain-usage)

## Section 4: Sensitive Logging Check
(content from flag-sensitive-logging)

## Pass Criteria
(unified pass/fail across all sections)
```

#### 2. `wispr-audit-concurrency` (replaces 3 skills)

**Absorbs:**
- `wispr-audit-actor-isolation` (37) → Section: Actor Isolation
- `wispr-flag-missing-sendable` (53) → Section: Sendable Conformance
- `wispr-detect-unsafe-main-actor-dispatches` (82) → Section: Unsafe Dispatches

**Trigger description:** "Use when auditing Swift 6 concurrency correctness — actor isolation, Sendable conformance, or unsafe MainActor dispatches. Pass optional focus: `isolation`, `sendable`, `dispatches`, or omit for full audit."

#### 3. `wispr-review-platform` (replaces 3 skills)

**Absorbs:**
- `wispr-check-accessibility-labels` (91) → Section: Accessibility / VoiceOver
- `wispr-review-swiftui-conventions` (105) → Section: SwiftUI Conventions
- `wispr-validate-menu-bar-patterns` (83) → Section: MenuBarExtra Patterns

**Trigger description:** "Use when reviewing macOS platform patterns — accessibility labels, SwiftUI conventions, or menu bar behavior. Pass optional focus: `accessibility`, `swiftui`, `menubar`, or omit for full review."

#### 4. `wispr-ui-testing-tools` (replaces 3 skills)

**Absorbs:**
- `wispr-ui-ax-inspect` (69) → Section: AX Tree Inspection
- `wispr-ui-simulate-input` (76) → Section: CGEvent Input Simulation
- `wispr-ui-screenshot-verify` (56) → Section: Screenshot Comparison

**Trigger description:** "Use when working with UAT testing tools — AX tree inspection, CGEvent input simulation, or screenshot verification. Pass tool name: `ax-inspect`, `simulate-input`, `screenshot`, or omit for full reference."

#### 5. `wispr-manage-model-lifecycle` (replaces 3 skills)

**Absorbs:**
- `wispr-manage-model-loading` (93) → Section: Prepare / Unload Lifecycle
- `wispr-switch-asr-backends` (91) → Section: Backend Switching
- `wispr-optimize-memory-management` (80) → Section: Memory Management

Wait — `optimize-memory-management` is already in the KEEP list. Let me reconsider.

Actually, `optimize-memory-management` covers capturedSamples growth + single-backend invariant. `manage-model-loading` covers prepare/transcribe/unload. `switch-asr-backends` covers the unload-reassign-prepare flow. These three overlap significantly on the model lifecycle topic.

**Revised:** Move `optimize-memory-management` from KEEP into this consolidation.

**Trigger description:** "Use when implementing or debugging ASR model lifecycle — prepare/unload, backend switching, or memory management during transcription."

### DELETE OUTRIGHT (3 skills)

| Skill | Lines | Reason |
|-------|-------|--------|
| `wispr-resolve-naming-collisions` | 61 | Content is in `swift-patterns.md` (auto-loaded every message) AND `gotchas.md`. Triple redundancy. |
| `wispr-infer-asr-types` | 74 | Same FluidAudio naming issue, same coverage in auto-loaded files. |
| `wispr-swift-format-check` | 23 | One bash command. Description alone is sufficient. |

### KEEP AS STUBS (3 skills — future features)

- `wispr-configure-analytics` (118) — design decisions for opt-in analytics, TBD implementation
- `wispr-scaffold-account-system` (63) — account system skeleton, TBD implementation
- `wispr-validate-license-key` (81) — license key format + validation flow, TBD implementation

These encode forward-looking design decisions even though implementation is pending.

## Scorecard

| Metric | Before | After | Delta |
|--------|--------|-------|-------|
| Total skills | 51 | 35 | -16 |
| Skill descriptions in system prompt | 51 | 35 | -16 |
| Skills deleted | — | 3 | |
| Skills absorbed into consolidated | — | 16 | |
| New consolidated skills | — | 5 | |
| Knowledge lost | — | 0 | |

## Execution Plan

### Phase 1: Create consolidated skills (parallel — 5 independent agents)

Each agent reads the source skills, merges content into the new SKILL.md with sections, and writes it. These are independent — no cross-dependencies.

| Agent | Task | Input skills | Output |
|-------|------|-------------|--------|
| Agent A | Build `wispr-audit-secrets` | 4 source skills | New SKILL.md |
| Agent B | Build `wispr-audit-concurrency` | 3 source skills | New SKILL.md |
| Agent C | Build `wispr-review-platform` | 3 source skills | New SKILL.md |
| Agent D | Build `wispr-ui-testing-tools` | 3 source skills | New SKILL.md |
| Agent E | Build `wispr-manage-model-lifecycle` | 3 source skills | New SKILL.md |

### Phase 2: Delete old skills (sequential — one agent)

Remove the 19 skill directories (16 absorbed + 3 deleted outright):
```
rm -rf .claude/skills/wispr-detect-hardcoded-secrets
rm -rf .claude/skills/wispr-check-api-key-storage
rm -rf .claude/skills/wispr-validate-keychain-usage
rm -rf .claude/skills/wispr-flag-sensitive-logging
rm -rf .claude/skills/wispr-audit-actor-isolation
rm -rf .claude/skills/wispr-flag-missing-sendable
rm -rf .claude/skills/wispr-detect-unsafe-main-actor-dispatches
rm -rf .claude/skills/wispr-check-accessibility-labels
rm -rf .claude/skills/wispr-review-swiftui-conventions
rm -rf .claude/skills/wispr-validate-menu-bar-patterns
rm -rf .claude/skills/wispr-ui-ax-inspect
rm -rf .claude/skills/wispr-ui-simulate-input
rm -rf .claude/skills/wispr-ui-screenshot-verify
rm -rf .claude/skills/wispr-manage-model-loading
rm -rf .claude/skills/wispr-switch-asr-backends
rm -rf .claude/skills/wispr-optimize-memory-management
rm -rf .claude/skills/wispr-resolve-naming-collisions
rm -rf .claude/skills/wispr-infer-asr-types
rm -rf .claude/skills/wispr-swift-format-check
```

### Phase 3: Update references (sequential — one agent)

1. **CLAUDE.md** — Update the Agents table to reference new consolidated skill names
2. **Agent definitions** — Update skill lists in:
   - `.claude/agents/quality-security.md` (secrets + concurrency clusters)
   - `.claude/agents/macos-platform.md` (platform review cluster)
   - `.claude/agents/testing.md` (ui testing tools cluster)
   - `.claude/agents/audio-pipeline.md` (model lifecycle cluster)
3. **Knowledge files** — Update any references in:
   - `.claude/knowledge/task-router.md`
   - `.claude/knowledge/roadmap.md`

### Phase 4: Verify (one agent)

1. Count skills: `ls .claude/skills/ | wc -l` → expect 35
2. Grep for dangling references: `grep -r "wispr-detect-hardcoded\|wispr-check-api-key-storage\|wispr-validate-keychain\|wispr-flag-sensitive\|wispr-audit-actor\|wispr-flag-missing-sendable\|wispr-detect-unsafe-main\|wispr-check-accessibility\|wispr-review-swiftui\|wispr-validate-menu-bar\|wispr-ui-ax-inspect\|wispr-ui-simulate\|wispr-ui-screenshot\|wispr-manage-model-loading\|wispr-switch-asr\|wispr-optimize-memory\|wispr-resolve-naming\|wispr-infer-asr\|wispr-swift-format-check" .claude/`
3. Any dangling references → fix them

## Execution Strategy Decision

**Parallel agents (not teams)** — the consolidation clusters are independent single-agent tasks with no cross-dependencies. Teams add coordination overhead that isn't needed here. Each agent reads source skills, writes one new SKILL.md, done.

Phase 2-4 run sequentially after Phase 1 completes (depends on Phase 1 output).
