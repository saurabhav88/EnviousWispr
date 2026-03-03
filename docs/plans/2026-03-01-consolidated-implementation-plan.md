# Consolidated Implementation Plan — 2026-03-01

Merges two audit plans into one sequenced, parallelizable execution plan:
- **Code Audit** (`docs/plans/2026-03-01-code-audit-action-plan.md`) — 13 source code fixes across 6 priorities
- **Agent/Skill Infrastructure Review** (`.claude/knowledge/agent-skill-review-action-plan.md`) — 30 infrastructure fixes across P0/P1/P2

---

## Overlap & Conflict Analysis

### Overlaps (same concern, both plans)

| Area | Code Audit Item | Infra Review Item | Resolution |
|------|----------------|-------------------|------------|
| Emergency teardown data loss | 1.1 (partial transcription on disconnect) | — | Code Audit only — pure Swift change |
| Device switch failure surfacing | 1.2 (fail loudly on device switch) | #3 (permissions skill wrong about Accessibility) | Complementary: Code Audit fixes the Swift code, Infra Review fixes the skill doc. No conflict. |
| Error handling strategy | 3.1 (unified error classification) | #25 (error recovery runbooks in agents) | Complementary: Code Audit defines the error classes in Swift, Infra Review documents them in agent files. Code Audit must finish first so agent runbooks reference real error types. |
| LLM error sanitization | 2.3 (sanitize API error strings) | #16 (scaffold-llm-connector hallucinated method) | No conflict: different files entirely. |
| CustomWordStore Sendable | 5.3 (fix Sendable correctness) | #28 (incomplete gotcha checklists) | Complementary: fix the code first, then update gotcha references. |
| Release pipeline | — | #4-8 (distribution/release P0s) | Infra Review only — all doc/skill changes. |
| UAT workflow | — | #9-10 (UAT scope/workflow confusion) | Infra Review only — skill doc changes. |

### Conflicts (changes that could break each other)

| Risk | Files | Mitigation |
|------|-------|------------|
| **TranscriptionPipeline.swift touched by 3 Code Audit items** (4.1, 5.1, 5.2) | `Pipeline/TranscriptionPipeline.swift` | All 3 must be done by the SAME agent in sequence. Never parallel. |
| **AudioCaptureManager.swift touched by 2 Code Audit items** (1.1, 1.2) | `Audio/AudioCaptureManager.swift` | Same agent, sequential. |
| **3 LLM connectors touched by Code Audit 2.2 AND 2.3** | `LLM/OpenAIConnector.swift`, `LLM/GeminiConnector.swift`, `LLM/OllamaConnector.swift` | Same agent for both 2.2 and 2.3 — do retry logic first, then sanitize errors. |
| **LLMNetworkSession.swift touched by Code Audit 2.1** | `LLM/LLMNetworkSession.swift` | Isolated 1-line change, no conflict. |
| **Multiple scaffold skills need @preconcurrency fix** (Infra #18) | 3 scaffold skill prompt.md files | Same agent that fixes #1 (scaffold-asr-backend) handles all 3 scaffolds. |
| **release-checklist.md touched by Infra #5, #7, #8, #22, #23** | `wispr-release-checklist/prompt.md` | All 5 changes to this one file must be done by ONE agent in ONE pass. |
| **release-maintenance.md touched by Infra #8, #12** | `.claude/agents/release-maintenance.md` | Same agent, single pass. |
| **All 10 agents touched by Infra #25, #26, #27, #28** | All 10 agent .md files | These are cross-cutting bulk updates. Must happen AFTER all other agent-specific edits (Infra #12, #24) to avoid merge conflicts. |

### Dependencies (must-happen-before ordering)

```
Code Audit 1.1, 1.2 → before Infra #25 (error recovery runbooks reference real error behavior)
Code Audit 2.2, 2.3 → before Infra #25 (LLM error handling must exist before documenting it)
Code Audit 3.1 → before Infra #25 (error classification system must exist before agent runbooks)
Code Audit 5.3 → before Infra #28 (CustomWordStore fix informs gotcha checklist content)
Infra #1 (scaffold-asr-backend) → before Infra #18 (@preconcurrency in scaffolds)
Infra #4 (notarization verification) → before Infra #5, #7, #8 (release-checklist fixes)
Infra #13 (when-shit-breaks.md) → before Infra #25 (runbooks can reference incident response)
All agent-specific edits → before Infra #25-28 (bulk cross-cutting updates)
```

---

## Execution Batches

### Batch 0: Verification & Prerequisite (serial, coordinator only)

**Purpose**: Resolve the notarization contradiction before any release pipeline work.

| Task | What | Files | Agent | Notes |
|------|------|-------|-------|-------|
| 0.1 | Verify notarization works with CLT-only (no full Xcode) | N/A — test only | `release-maintenance` | Run `xcrun notarytool` on CLT-only machine. Result determines whether to fix the codesign skill or distribution.md |

**Gate**: Result of 0.1 determines the content of Batch 2 item 2.2.

---

### Batch 1: Critical Source Code Fixes (2 agents in parallel)

**Purpose**: Fix data loss, silent failures, and crash risks in Swift source code. These are the highest-impact user-facing bugs.

#### Agent A: `audio-pipeline`

Owns all Audio/ and Pipeline/ Swift files in this batch. Sequential within agent.

| Task | Code Audit Item | Files | Change |
|------|----------------|-------|--------|
| 1A.1 | 1.1 | `Audio/AudioCaptureManager.swift` | Before `emergencyTeardown()` clears `capturedSamples`, snapshot the buffer and hand to pipeline for partial transcription |
| 1A.2 | 1.2 | `Audio/AudioCaptureManager.swift` | Make `setInputDevice()` throw on `AudioUnitSetProperty` failure instead of silent log |
| 1A.3 | 4.1 | `Pipeline/TranscriptionPipeline.swift` | Move VAD monitor loop (line ~616) off `@MainActor` — use background actor or `AsyncStream` to decouple from main thread |
| 1A.4 | 5.2 | `Pipeline/TranscriptionPipeline.swift` | Add `isStopping` flag or `.stopping` state before first await in `stopAndTranscribe()` to prevent concurrent entry |
| 1A.5 | 5.1 | `Pipeline/TranscriptionPipeline.swift` | Replace `group.next()!` with `guard let` + throw `ASRError.streamingTimeout` |
| 1A.6 | 6.1 | `Audio/SilenceDetector.swift` | Add `.verbose` level logging for VAD `processChunk` errors |

**File ownership**: `AudioCaptureManager.swift`, `TranscriptionPipeline.swift`, `SilenceDetector.swift` — all exclusively `audio-pipeline` in this batch.

#### Agent B: `quality-security`

Owns concurrency correctness and error sanitization.

| Task | Code Audit Item | Files | Change |
|------|----------------|-------|--------|
| 1B.1 | 5.3 | `PostProcessing/CustomWordStore.swift` | Change from `Sendable` class to `@MainActor` annotation (or wrap in actor) |
| 1B.2 | 2.3 | `LLM/OpenAIConnector.swift` | Map HTTP error bodies to user-friendly messages; truncate raw body to 200 chars for debug log |
| 1B.3 | 2.3 | `LLM/GeminiConnector.swift` | Same error sanitization pattern |
| 1B.4 | 2.3 | `LLM/OllamaConnector.swift` | Same error sanitization pattern |

**File ownership**: `CustomWordStore.swift`, all 3 LLM connectors — exclusively `quality-security` in this batch.

#### Parallel safety check:
- Agent A touches: `AudioCaptureManager.swift`, `TranscriptionPipeline.swift`, `SilenceDetector.swift`
- Agent B touches: `CustomWordStore.swift`, `OpenAIConnector.swift`, `GeminiConnector.swift`, `OllamaConnector.swift`
- **ZERO overlap. Safe to parallelize.**

---

### Batch 2: LLM Resilience + Release Docs (3 agents in parallel)

**Purpose**: Add LLM retry/timeout (source code), fix release pipeline documentation (skills/knowledge), fix code-breaking skill templates.

**Depends on**: Batch 1 complete (error sanitization patterns from 1B.2-4 inform retry logic).

#### Agent C: `audio-pipeline`

LLM network resilience (these are pipeline-domain changes).

| Task | Code Audit Item | Files | Change |
|------|----------------|-------|--------|
| 2C.1 | 2.1 | `LLM/LLMNetworkSession.swift` | Add `timeoutIntervalForResource = 180` to session config |
| 2C.2 | 2.2 | `LLM/OpenAIConnector.swift` | Add exponential backoff (1-2 retries, 1s/3s) for 429/5xx/network timeout. Don't retry 4xx auth |
| 2C.3 | 2.2 | `LLM/GeminiConnector.swift` | Same retry pattern |
| 2C.4 | 2.2 | `LLM/OllamaConnector.swift` | Same retry pattern |

**Note**: Connectors were already edited by Agent B in Batch 1 for error sanitization. Agent C adds retry logic on top. Sequential dependency: Batch 1 must finish first.

#### Agent D: `release-maintenance`

Fixes all release/distribution skill and knowledge docs.

| Task | Infra Item | Files | Change |
|------|-----------|-------|--------|
| 2D.1 | #4 | `wispr-codesign-without-xcode/prompt.md` AND/OR `.claude/knowledge/distribution.md` | Fix notarization contradiction based on Batch 0 result |
| 2D.2 | #5 | `wispr-release-checklist/prompt.md` | Document `build-dmg.sh` steps OR create `wispr-build-dmg` skill |
| 2D.3 | #7 | `wispr-release-checklist/prompt.md` | Make Sparkle signing explicit: tool path, key, verification step, failure consequences |
| 2D.4 | #8 | `wispr-release-checklist/prompt.md` + `.claude/agents/release-maintenance.md` | Add rollback procedure: pull appcast.xml, have previous DMG, re-tag, notify |
| 2D.5 | #22 | `wispr-release-checklist/prompt.md` | Specify version format: `v1.0.0` for tags, `1.0.0` in Info.plist |
| 2D.6 | #23 | `wispr-release-checklist/prompt.md` | Clarify appcast.xml generation: CI on tag push, manual fallback |
| 2D.7 | #6 | `wispr-build-release-config/prompt.md` + `wispr-check-dependency-versions/prompt.md` | Add arm64-only warning (FluidAudio Float16) |
| 2D.8 | #15 | `wispr-codesign-without-xcode/prompt.md` | Add TCC persistence note linking to signing identity |

**File ownership**: All release-related skill prompts and release-maintenance agent file. Single agent, no conflicts.

#### Agent E: `feature-scaffolding`

Fixes code-breaking scaffold templates.

| Task | Infra Item | Files | Change |
|------|-----------|-------|--------|
| 2E.1 | #1 | `wispr-scaffold-asr-backend/prompt.md` | Rewrite to match actual `ASRBackend` protocol: `supportsStreaming`, `startStreaming()`, `feedAudio()`, `finalizeStreaming()`, `cancelStreaming()`, `transcribe(audioSamples:options:)` |
| 2E.2 | #16 | `wispr-scaffold-llm-connector/prompt.md` | Remove hallucinated `validateCredentials()` or mark optional |
| 2E.3 | #18 | `wispr-scaffold-asr-backend/prompt.md`, `wispr-scaffold-llm-connector/prompt.md`, `wispr-scaffold-settings-tab/prompt.md` | Add `@preconcurrency import` notes per swift-patterns.md |

**File ownership**: All scaffold skill prompts — exclusively `feature-scaffolding`.

#### Parallel safety check:
- Agent C touches: `LLMNetworkSession.swift`, 3 LLM connectors (Swift source)
- Agent D touches: 4 skill prompt.md files, 1 agent .md, 1 knowledge .md
- Agent E touches: 3 scaffold skill prompt.md files
- **ZERO overlap. Safe to parallelize.**

---

### Batch 3: Error Strategy + UI Feedback + Remaining Source Fixes (3 agents in parallel)

**Purpose**: Implement unified error classification, add user-facing feedback, fix remaining source code items.

**Depends on**: Batch 2 complete (retry/error patterns from 2C inform error classification).

#### Agent F: `macos-platform`

Owns UI feedback and error presentation.

| Task | Code Audit Item | Files | Change |
|------|----------------|-------|--------|
| 3F.1 | 3.1 (UI part) | New or existing UI helper file | Implement toast/banner infrastructure for error classes: Transient Network, Device Error, Config Error, Internal |
| 3F.2 | 6.2 | `App/AppState.swift` | Surface CustomWordStore add/remove failures to UI (toast or inline message) instead of `try?` |
| 3F.3 | 1.2 (UI part) | Appropriate view file | Add "Audio Device Disconnected" banner/toast when device switch fails |

**File ownership**: `AppState.swift` (for 3F.2 wiring only), UI view files.

#### Agent G: `quality-security`

Owns error propagation patterns and data consistency.

| Task | Code Audit Item | Files | Change |
|------|----------------|-------|--------|
| 3G.1 | 3.1 (propagation part) | New `Models/ErrorClassification.swift` or similar | Define error classification enum and mapping logic: Transient Network, Device Error, Config Error, Internal |
| 3G.2 | 6.3 | `Storage/TranscriptStore.swift` | Fix `deleteAll()` to collect all errors and only clear in-memory state after full disk success |

**File ownership**: `TranscriptStore.swift`, new error classification file.

#### Agent H: `audio-pipeline`

Fixes language settings skill (requires ASR domain knowledge).

| Task | Infra Item | Files | Change |
|------|-----------|-------|--------|
| 3H.1 | #2 | `wispr-configure-language-settings/prompt.md` | Fix `makeDecodingOptions()` → `makeDecodeOptions()`, add 7 missing quality params from TranscriptionOptions, show `mapResults()` helper |

**File ownership**: Language settings skill prompt — isolated, no conflicts.

#### Parallel safety check:
- Agent F touches: `AppState.swift`, UI view files
- Agent G touches: `TranscriptStore.swift`, new error classification file
- Agent H touches: `wispr-configure-language-settings/prompt.md`
- **Potential risk**: Agent F touches `AppState.swift`. No other agent in this batch touches it. Safe.
- **ZERO overlap. Safe to parallelize.**

---

### Batch 4: Infrastructure Gaps + UAT Fixes (3 agents in parallel)

**Purpose**: Build missing infrastructure (incident response, secrets, user-management skeleton), fix UAT workflow docs, fix permissions skill.

**Depends on**: Batch 3 complete (error classification from 3G.1 informs incident response doc).

#### Agent I: `release-maintenance`

Creates new infrastructure documents and skills.

| Task | Infra Item | Files | Change |
|------|-----------|-------|--------|
| 4I.1 | #13 | `.claude/knowledge/when-shit-breaks.md` (NEW) | Create incident response checklist: build fails, production bug, secret leaked, API down, permission broken |
| 4I.2 | #14 | `.claude/skills/wispr-rotate-secrets/prompt.md` (NEW) | Create secret rotation skill: identify key, generate new, update storage, verify, revoke old |

**File ownership**: New files only — no conflicts.

#### Agent J: `testing`

Fixes UAT workflow documentation.

| Task | Infra Item | Files | Change |
|------|-----------|-------|--------|
| 4J.1 | #9 | `wispr-run-smart-uat/prompt.md` | Define exact TodoWrite format with examples, scope extraction rules, >10 files scope creep warning, promote `run_in_background: true` to FIRM RULE |
| 4J.2 | #10 | `wispr-generate-uat-tests/prompt.md` | Clarify this is optional planning/documentation; `run-smart-uat → uat-generator` is the executable path |
| 4J.3 | #24 | `.claude/agents/testing.md` | Rewrite smoke test vs rebuild-and-relaunch distinction: smoke = compile gate, rebuild = full cycle |

**File ownership**: UAT skill prompts, testing agent file — exclusively `testing`.

#### Agent K: `macos-platform`

Fixes the permissions skill (factual error about Accessibility).

| Task | Infra Item | Files | Change |
|------|-----------|-------|--------|
| 4K.1 | #3 | `wispr-handle-macos-permissions/prompt.md` | Correct: Paste = Accessibility REQUIRED (CGEvent.post on macOS 14+). Add `@preconcurrency import AVFoundation`. Add runtime revocation monitoring. Clarify Carbon hotkey = no Accessibility. |
| 4K.2 | #20 | `wispr-ui-ax-inspect/prompt.md`, `wispr-ui-simulate-input/prompt.md` | Add "Prerequisites: Grant Accessibility" section |

**File ownership**: Permissions and UI testing skill prompts — exclusively `macos-platform`.

#### Parallel safety check:
- Agent I creates: new knowledge file, new skill directory
- Agent J touches: 2 skill prompts, testing agent file
- Agent K touches: 3 skill prompts
- **ZERO overlap. Safe to parallelize.**

---

### Batch 5: User Management Skeleton + Remaining P1 Skills (2 agents in parallel)

**Purpose**: Build out the empty user-management agent, fix remaining P1 skill issues.

**Depends on**: Batch 4 complete (UAT fixes should be in place before creating new skills).

#### Agent L: `user-management` (or `feature-scaffolding` to build out the skeleton)

| Task | Infra Item | Files | Change |
|------|-----------|-------|--------|
| 5L.1 | #11 | `.claude/knowledge/accounts-licensing.md` (NEW) | Create knowledge file: tier matrix, payment provider decision, license format, trial rules |
| 5L.2 | #11 | `.claude/skills/wispr-scaffold-account-system/prompt.md` (NEW) | Create stub skill |
| 5L.3 | #11 | `.claude/skills/wispr-validate-license-key/prompt.md` (NEW) | Create stub skill |
| 5L.4 | #11 | `.claude/skills/wispr-configure-analytics/prompt.md` (NEW) | Create stub skill |
| 5L.5 | #11 | `.claude/agents/user-management.md` | Update agent to reference new knowledge + skills |

**File ownership**: User management agent, new knowledge/skill files.

#### Agent M: `quality-security`

Fixes remaining P1 skill issues in its domain.

| Task | Infra Item | Files | Change |
|------|-----------|-------|--------|
| 5M.1 | #17 | `wispr-swift-format-check/prompt.md` | Remove `disable-model-invocation: true` flag or convert to bash workflow |
| 5M.2 | #19 | `wispr-validate-api-contracts/prompt.md` | Add rate limit handling and API deprecation strategy sections |
| 5M.3 | #21 | `wispr-check-feature-tracker/prompt.md` | Link to TRACKER.md format and Definition of Done |

**File ownership**: Quality/security skill prompts — no conflicts.

#### Parallel safety check:
- Agent L touches: user-management agent, new files
- Agent M touches: 3 quality-security skill prompts
- **ZERO overlap. Safe to parallelize.**

---

### Batch 6: Cross-Cutting Agent Updates (1 agent, serial)

**Purpose**: Apply bulk cross-cutting updates to ALL 10 agent files. Must happen LAST to avoid merge conflicts with earlier agent-specific edits (Batches 2D.4, 4J.3, 5L.5).

**Depends on**: ALL previous batches complete.

#### Agent N: `quality-security` (or `feature-planning` as team lead)

This is a bulk documentation sweep. One agent edits all 10 agent files sequentially.

| Task | Infra Item | Files | Change |
|------|-----------|-------|--------|
| 6N.1 | #12 | `quality-security.md`, `release-maintenance.md`, `testing.md` | Add "Before Acting" sections listing mandatory knowledge files |
| 6N.2 | #25 | All 10 agent .md files | Add "Error Handling" section with common failure modes + recovery per agent |
| 6N.3 | #26 | 5+ agent .md files | Add "Testing Requirements" section linking to Definition of Done |
| 6N.4 | #27 | All 10 agent .md files | Add decision trees for peer blocked, peer disagreement, incomplete deliverable |
| 6N.5 | #28 | All 10 agent .md files | Audit each against gotchas.md; add "Gotchas Relevant to This Agent" checklist |

**CRITICAL**: This agent must have exclusive write access to all 10 agent files. No other agent should touch agent files during Batch 6.

**File ownership**: All 10 `.claude/agents/*.md` files — exclusively this agent.

---

### Batch 7: Cleanup + Data Migration (2 agents in parallel)

**Purpose**: Delete stale artifacts, create forward-looking infrastructure.

**Depends on**: Batch 6 complete.

#### Agent O: `release-maintenance`

| Task | Infra Item | Files | Change |
|------|-----------|-------|--------|
| 7O.1 | #29 | `.claude/skills/mcp-builder/` | Delete entire directory (generic MCP guide, not project-specific) |
| 7O.2 | #30 | `.claude/knowledge/data-migration.md` (NEW) | Create knowledge file covering settings format changes between versions |

#### Agent P: `build-compile`

| Task | Infra Item | Files | Change |
|------|-----------|-------|--------|
| 7P.1 | — | — | Run `swift build -c release` and `swift build --build-tests` as full regression gate after all changes |

#### Parallel safety check:
- Agent O: deletes mcp-builder, creates new knowledge file
- Agent P: read-only build validation
- **ZERO overlap. Safe to parallelize.**

---

### Batch 8: P2 Polish (optional, time-permitting)

**Purpose**: Nice-to-have improvements. Not blocking v1.

| # | Infra P2 Item | Agent | Files |
|---|--------------|-------|-------|
| 8.1 | Code examples in 3-5 agents | `feature-planning` | Agent .md files |
| 8.2 | Domain boundary conflict resolution docs | `feature-planning` | New knowledge file |
| 8.3 | Section naming standardization across agents | `feature-planning` | All 10 agent files |
| 8.4 | Performance baselines in testing agent | `testing` | `testing.md` |
| 8.5 | TSan / thread-safety testing guidance | `quality-security` | `testing.md` or new knowledge |
| 8.6 | Animation gotcha in scaffold skills | `feature-scaffolding` | Scaffold skill prompts |
| 8.7 | Screenshot baseline management for CI/CD | `testing` | Skill prompts |
| 8.8 | wispr-find-dead-code absolute paths | `release-maintenance` | `wispr-find-dead-code/prompt.md` |
| 8.9 | File-index.md links in all agents | `feature-planning` | All 10 agent files |

**WARNING**: Items 8.1, 8.3, 8.9 all touch agent .md files — they MUST NOT run in parallel with each other or with any stragglers from Batch 6.

---

## Complete File Ownership Map

This table shows every file touched across all batches and which single agent owns it at each point.

### Swift Source Files

| File | Batch | Agent | Changes |
|------|-------|-------|---------|
| `Audio/AudioCaptureManager.swift` | 1 | `audio-pipeline` (A) | Partial transcription on teardown, throw on device switch fail |
| `Audio/SilenceDetector.swift` | 1 | `audio-pipeline` (A) | VAD error logging |
| `Pipeline/TranscriptionPipeline.swift` | 1 | `audio-pipeline` (A) | VAD off main actor, isStopping flag, guard group.next() |
| `PostProcessing/CustomWordStore.swift` | 1 | `quality-security` (B) | @MainActor instead of Sendable |
| `LLM/OpenAIConnector.swift` | 1→2 | `quality-security` (B) then `audio-pipeline` (C) | Error sanitization (B1), then retry logic (B2) |
| `LLM/GeminiConnector.swift` | 1→2 | `quality-security` (B) then `audio-pipeline` (C) | Error sanitization (B1), then retry logic (B2) |
| `LLM/OllamaConnector.swift` | 1→2 | `quality-security` (B) then `audio-pipeline` (C) | Error sanitization (B1), then retry logic (B2) |
| `LLM/LLMNetworkSession.swift` | 2 | `audio-pipeline` (C) | timeoutIntervalForResource |
| `App/AppState.swift` | 3 | `macos-platform` (F) | CustomWordStore error surfacing |
| `Storage/TranscriptStore.swift` | 3 | `quality-security` (G) | deleteAll() consistency |
| New: `Models/ErrorClassification.swift` | 3 | `quality-security` (G) | Error classification enum |

### Skill Prompt Files

| File | Batch | Agent | Changes |
|------|-------|-------|---------|
| `wispr-scaffold-asr-backend/prompt.md` | 2 | `feature-scaffolding` (E) | Rewrite to match real ASRBackend protocol + @preconcurrency |
| `wispr-scaffold-llm-connector/prompt.md` | 2 | `feature-scaffolding` (E) | Remove hallucinated method + @preconcurrency |
| `wispr-scaffold-settings-tab/prompt.md` | 2 | `feature-scaffolding` (E) | Add @preconcurrency note |
| `wispr-codesign-without-xcode/prompt.md` | 2 | `release-maintenance` (D) | Fix notarization contradiction + TCC persistence note |
| `wispr-release-checklist/prompt.md` | 2 | `release-maintenance` (D) | build-dmg, Sparkle signing, rollback, version format, appcast |
| `wispr-build-release-config/prompt.md` | 2 | `release-maintenance` (D) | arm64 warning |
| `wispr-check-dependency-versions/prompt.md` | 2 | `release-maintenance` (D) | arm64 warning |
| `wispr-configure-language-settings/prompt.md` | 3 | `audio-pipeline` (H) | Fix function names, add quality params |
| `wispr-run-smart-uat/prompt.md` | 4 | `testing` (J) | Scope resolution, TodoWrite format, FIRM RULE |
| `wispr-generate-uat-tests/prompt.md` | 4 | `testing` (J) | Clarify as optional planning path |
| `wispr-handle-macos-permissions/prompt.md` | 4 | `macos-platform` (K) | Fix Accessibility requirement, add revocation monitoring |
| `wispr-ui-ax-inspect/prompt.md` | 4 | `macos-platform` (K) | Add Accessibility prerequisite |
| `wispr-ui-simulate-input/prompt.md` | 4 | `macos-platform` (K) | Add Accessibility prerequisite |
| `wispr-swift-format-check/prompt.md` | 5 | `quality-security` (M) | Remove disable-model-invocation flag |
| `wispr-validate-api-contracts/prompt.md` | 5 | `quality-security` (M) | Add rate limiting + deprecation |
| `wispr-check-feature-tracker/prompt.md` | 5 | `quality-security` (M) | Link to TRACKER.md format |
| `wispr-rotate-secrets/prompt.md` (NEW) | 4 | `release-maintenance` (I) | Create secret rotation skill |

### Agent Files

| File | Batch | Agent | Changes |
|------|-------|-------|---------|
| `.claude/agents/release-maintenance.md` | 2→6 | `release-maintenance` (D) in B2, `quality-security` (N) in B6 | Rollback section (B2), then bulk updates (B6) |
| `.claude/agents/testing.md` | 4→6 | `testing` (J) in B4, `quality-security` (N) in B6 | Smoke vs rebuild (B4), then bulk updates (B6) |
| `.claude/agents/user-management.md` | 5→6 | `feature-scaffolding` (L) in B5, `quality-security` (N) in B6 | Skills/knowledge refs (B5), then bulk updates (B6) |
| All other 7 agents | 6 | `quality-security` (N) | Bulk: Before Acting, Error Handling, Testing Requirements, team protocols, gotchas |

### Knowledge Files

| File | Batch | Agent | Changes |
|------|-------|-------|---------|
| `.claude/knowledge/distribution.md` | 2 | `release-maintenance` (D) | Fix notarization statement if needed |
| `.claude/knowledge/when-shit-breaks.md` (NEW) | 4 | `release-maintenance` (I) | Incident response checklist |
| `.claude/knowledge/accounts-licensing.md` (NEW) | 5 | `feature-scaffolding` (L) | User management knowledge |
| `.claude/knowledge/data-migration.md` (NEW) | 7 | `release-maintenance` (O) | Settings format migration guide |

### Deleted Files

| File | Batch | Agent |
|------|-------|-------|
| `.claude/skills/mcp-builder/` (entire directory) | 7 | `release-maintenance` (O) |

---

## Risk Register

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|------------|
| **LLM connector triple-edit** (B1 sanitize → B2 retry) | Medium | Build break if merge conflicts | Same file region awareness: B1 sanitizes error strings at the throw/return sites, B2 adds retry wrapper around the HTTP call. Different code locations. |
| **TranscriptionPipeline.swift 3 changes in Batch 1** | Low | Merge conflicts within agent | Single agent (audio-pipeline) does all 3 sequentially. No parallel risk. |
| **Batch 6 bulk agent updates overwrite B2/B4/B5 edits** | Medium | Lost content | Agent N must READ each file before editing. Append new sections, never replace existing content from earlier batches. |
| **New ErrorClassification type breaks build** | Low | Compilation failure | Build validation in Batch 7 catches this. Also, quality-security agent should run `swift build` after creating the type. |
| **Notarization verification (B0) reveals CLT insufficient** | Medium | Blocks release pipeline | If CLT cannot notarize, update distribution.md and codesign skill to require Xcode. Add to `when-shit-breaks.md`. |
| **User-management skeleton skills are too vague** | Low | Useless stubs | Acceptable — these are explicitly stubs. Real implementation comes when accounts/licensing feature work begins. |
| **P2 items touching agent files conflict with Batch 6** | Medium | Merge conflicts | P2 (Batch 8) explicitly gated after Batch 6. No agent file edits in P2 should run concurrently with B6. |

---

## Summary Statistics

| Metric | Count |
|--------|-------|
| Total batches | 8 (+ Batch 0 verification) |
| Swift source files modified | 11 (+ 1 new) |
| Skill prompt files modified | 16 (+ 1 new) |
| Agent files modified | 10 |
| Knowledge files modified | 1 (+ 3 new) |
| Files deleted | 1 directory |
| Unique agent types used | 7 (`audio-pipeline`, `quality-security`, `release-maintenance`, `feature-scaffolding`, `macos-platform`, `testing`, `build-compile`) |
| Max parallel agents per batch | 3 (Batches 2, 3, 4) |
| Estimated total tasks | 52 (P0+P1), 9 more if P2 included |

---

## Handoff Notes for Coordinator B (Team Assignment)

1. **Batch 0 is a prerequisite gate.** Do not start Batch 2D until the notarization question is answered.

2. **LLM connectors have a strict sequential dependency**: Batch 1 (Agent B: error sanitization) MUST complete before Batch 2 (Agent C: retry logic). These touch the same 3 files.

3. **Batch 6 is the most dangerous batch.** One agent edits ALL 10 agent files. It must happen after ALL other batches that touch any agent file (2D.4, 4J.3, 5L.5). The agent must read each file first to avoid overwriting earlier changes.

4. **Build validation (Batch 7, Agent P) is the final gate.** Every Swift source change across all batches must compile clean before any commit.

5. **The deferred items from the Code Audit** (dead code, long functions, duplication, etc.) are explicitly NOT in this plan. They are documented in the Code Audit plan under "Deferred" and should remain deferred.

6. **Team composition recommendation**: Use the `audit-team` pattern from teamwork.md as the base, extended with domain agents as needed per batch. Each batch can be a sub-team with its own task list.

7. **Commit strategy**: One commit per batch after build validation. Commit messages should reference both audit plans: `fix(audit): Batch N — [summary]`.
