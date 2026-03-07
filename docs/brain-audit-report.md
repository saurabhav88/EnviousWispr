# EnviousWispr Brain Audit Report

**Date:** 2026-03-06
**Scope:** All non-code brain files — CLAUDE.md, knowledge, agents, skills, rules, docs, Beads
**Method:** 6 parallel Opus agents auditing different layers

---

## Executive Summary

| Metric | Value |
|--------|-------|
| Total brain files | 88 (1 root, 1 rule, 15 knowledge, 11 agents, 45 skills, 4 hookify, 24 feature specs) |
| Broken file links | **0** |
| Orphan files | **0** |
| Auto-update protocols | **0** |
| Stale files | **7** (file-index, type-index, task-router, roadmap, feature-catalog, architecture, gotchas) |
| Active data conflicts | **8** (same info, different values across files) |
| Beads issues | 69 (57 closed, 10 open, 2 in-progress) |
| bd memories | 39 entries (some duplicate knowledge files) |

**Headline:** The brain was built with exceptional craft — zero broken links, zero orphans, comprehensive coverage. But it has **zero self-maintenance mechanisms**. No hooks, no Definition of Done steps, no refresh protocols. It has already started to drift, with concrete data conflicts across multiple files.

---

## 1. Root Connectivity (Agent 1)

### All references from CLAUDE.md resolve
- 15 knowledge files: all exist
- 11 agent files: all exist
- 1 rules file: exists, auto-loaded
- 45 skills referenced via agents: all exist

### No orphan files found
Every file in `.claude/` is reachable from CLAUDE.md within 1-2 hops.

### Gaps identified
- **docs/ not directly linked from CLAUDE.md** — reachable only via 2-hop traversal through knowledge files
- **4 hookify files undocumented** in CLAUDE.md (operational hooks, not knowledge — acceptable but not discoverable)
- **Dead-end files** referenced from CLAUDE.md but no agent reads them: `whisperkit-research.md`, `beads-governance.md`, `when-shit-breaks.md`, `teamwork.md`
- **Factual errors in agents**: build-compile claims `build-check` CI is required (it's informational). release-maintenance references `APPCAST_BOT_TOKEN` PAT (doesn't exist — uses `GITHUB_TOKEN`).

---

## 2. Knowledge File Interconnections (Agent 2)

### Two clusters exist

**Core cluster (heavily interlinked):**
architecture ↔ file-index ↔ type-index ↔ task-router ↔ conventions ↔ gotchas ↔ github-workflow

**Isolated files (no knowledge-to-knowledge links):**
accounts-licensing, beads-governance, teamwork, when-shit-breaks, distribution, whisperkit-research, roadmap, feature-catalog

Isolated files connect to the brain only through CLAUDE.md and agent files.

### Staleness by file

| File | Status | Key Issues |
|------|--------|------------|
| file-index.md | **STALE** | Says 68 files / 14,007 lines (actual: 72 / 14,391). Missing 4+ files. AppState 31% line drift. |
| type-index.md | **STALE** | Duplicate enum entries (~15 listed twice). SettingKey says 27 (actual: 34). Missing WhisperKit types. |
| task-router.md | **STALE** | Line counts frozen. AppState 613→771. References non-existent file. |
| roadmap.md | **STALE** | "8 implemented, 14 remaining" — actually 16+ done. Dependency chains not in Beads. |
| architecture.md | **Drifting** | "26 keys" (actual: 34). Missing WhisperKit types from Key Types table. |
| gotchas.md | **Drifting** | SettingKey says 31 (actual: 34). Line references may have shifted. |
| feature-catalog.md | **Drifting** | References future file (WhisperKitStreamingCoordinator). Feature subcounts may be off. |
| conventions.md | Healthy | Keychain claim may be inaccurate. Otherwise solid. |
| github-workflow.md | Healthy | Consistent with distribution.md. |
| distribution.md | Healthy | Appears current. v1.0.0 release date noted. |
| accounts-licensing.md | Design only | Purely forward-looking. No code exists for any of this. |
| whisperkit-research.md | Healthy | Dated 2026-03-06. References 1 non-existent streaming file. |
| beads-governance.md | Healthy | Accurate but silent on knowledge file sync. |
| teamwork.md | Healthy | Agents have inline Team sections — could drift independently. |
| when-shit-breaks.md | Uncertain | References VadManager (may be outdated naming). |

### No auto-update protocol on ANY file
Not a single knowledge file contains guidance for when or how it should be updated.

---

## 3. Agents & Skills (Agent 3)

### All 11 agents are well-connected
- Every agent references `gotchas.md` and `conventions.md`
- Every agent's skills exist on disk
- Every agent is listed in CLAUDE.md

### All 45 skills accounted for
- Zero orphan skills
- Every skill is referenced by at least one agent
- Every skill appears in CLAUDE.md

### Issues found

| Issue | Details |
|-------|---------|
| 2 broken in-text skill references | `wispr-scaffold-asr-backend` and `wispr-scaffold-settings-tab` reference nonexistent `audit-actor-isolation` and `resolve-naming-collisions` skills |
| 3 stub skills | `wispr-scaffold-account-system`, `wispr-validate-license-key`, `wispr-configure-analytics` — all in user-management domain. Expected (pre-commercialization). |
| build-compile factual error | Claims `build-check` CI job is required before merge. It's informational only. |
| release-maintenance stale ref | Mentions `APPCAST_BOT_TOKEN` PAT. Should be `GITHUB_TOKEN`. |
| 8 knowledge files not read by any agent | file-index, type-index, task-router, github-workflow, beads-governance, teamwork, when-shit-breaks, whisperkit-research — only reachable via CLAUDE.md |

---

## 4. Docs & Feature Specs (Agent 4)

### Feature request inventory: 24 files

| Status | Count |
|--------|-------|
| Feature specs with matching bead (done) | 13 |
| Feature specs with matching bead (in-progress) | 1 (020 Settings Refresh) |
| Feature specs with NO bead | 7 (012-018) |
| Duplicate feature number | 1 (#020 used twice) |
| TRACKER entries showing "not started" that are actually done | 6 |

### docs/plans/ — 48-file island
Zero brain file references. Major active planning (whisperkit-highway: 17 files, onboarding-fixes: 12 files) completely disconnected from the brain.

### Other unreferenced docs/ directories
- docs/website/ (11 files)
- docs/mockups/ (7 files)
- docs/designs/ (6 files)
- docs/competitors/ (29 files)
- docs/reviews/ (1 file)

### Strategic content in docs/ that could belong in knowledge/
- `docs/comparison-handy-vs-enviouswispr.md` — competitor analysis
- `docs/email-feedback-report.md` + 4 related files — user feedback analysis
- `docs/2026-03-01-v1-release-and-infra-report.md` — release infrastructure

---

## 5. Update Cascades & Protocols (Agent 5)

### The brain has NO self-maintenance mechanism

- No `.claude/hooks/` directory
- No active git hooks
- No session-end checklist for brain updates
- No Definition of Done step for updating knowledge files
- No cascade documentation mapping code changes to brain file updates
- Beads tracks tasks well but has zero integration with knowledge file freshness

### Definition of Done gap

Current DoD (conventions.md):
1. Build passes
2. Test target compiles
3. App rebuilt + relaunched
4. Wispr Eyes verification
5. CI green

**Missing from DoD:**
6. Update affected knowledge files
7. Update feature-catalog / type-index if new types added
8. Close corresponding bead with reason

### Active data conflicts (same info, different values)

| Data Point | Location 1 | Location 2 | Actual |
|------------|-----------|-----------|--------|
| SettingKey count | architecture.md: **26** | type-index: **27**, file-index: **31** | **34** |
| Swift file count | file-index: **68** | — | **72** |
| Total lines | file-index: **~14,007** | — | **~14,391** |
| AppState.swift lines | task-router: **613** | — | **771** |
| AIPolishSettingsView lines | type-index: **512** | task-router: **668** | **777** |
| Features implemented | roadmap: **8 of 22** | TRACKER: **8 of 22** | **16+ of 22** |
| build-check CI | build-compile agent: **Required** | github-workflow + gotchas: Informational | **Not required** |
| Appcast token | release-maintenance: **APPCAST_BOT_TOKEN** | distribution: GITHUB_TOKEN | **GITHUB_TOKEN** |

---

## 6. Beads Overlay (Agent 6)

### Beads health: 69 total issues
- 57 closed, 10 open, 2 in-progress, 4 blocked
- Dependency chains exist for WhisperKit pipeline phases
- Governance doc is accurate about workflow mechanics

### Beads ↔ Knowledge: Two isolated systems
- Zero knowledge files contain bead IDs (ew-xxx)
- Zero beads reference knowledge files (except 1: ew-b93 → whisperkit-research.md)
- No sync protocol documented anywhere

### Beads ↔ Feature Specs: Weakly connected
- Only 1 of 24 feature specs contains a bead ID (020-settings-ui-refresh → ew-byi)
- 13 feature specs have matching beads by title only
- 7 feature specs have no bead at all
- 12+ active beads have no feature spec

### bd Memories ↔ Knowledge: Overlap and gaps

| Pattern | Examples |
|---------|----------|
| **Duplicated** | Agent routing rules (memory + CLAUDE.md), UAT workflow (memory + conventions.md) |
| **Fragmented** | WhisperKit architecture spread across 7+ memories AND 3+ knowledge files |
| **Gap** | Ops/credentials only in memories, not in knowledge files |
| **Complementary** | Paste system, Sparkle signing, manhwa domain — no conflict |

### No ownership boundaries documented
No document declares which system is authoritative for which topic. Memories, knowledge files, and Beads all contain overlapping architectural facts.

---

## 7. Missing Update Cascades

Every row below represents a pathway that needs to be created:

| Trigger Event | Files That Should Update |
|---------------|------------------------|
| New Swift file added | file-index.md, type-index.md, architecture.md (if structural), feature-catalog.md (if new feature) |
| New type/protocol added | type-index.md, architecture.md (Key Types) |
| New SettingKey case | file-index.md, type-index.md, architecture.md, gotchas.md |
| Feature implemented | feature-catalog.md, roadmap.md, TRACKER, file-index.md, type-index.md |
| Bead closed | roadmap.md (if feature), feature-catalog.md, feature-requests/ status |
| New agent added | CLAUDE.md (Agents table), teamwork.md |
| New skill added | CLAUDE.md (skill column), agent .md file |
| New gotcha discovered | gotchas.md, relevant agent files |
| Dependency updated | gotchas.md, distribution.md, agent files |

---

## 8. Prioritized Recommendations

### Critical (active misinformation)

1. **Fix data conflicts immediately** — SettingKey count, file counts, line numbers are wrong across 5+ files. Any agent reading these gets misinformed.

2. **Add brain maintenance to Definition of Done** — conventions.md DoD needs steps: "Update affected knowledge files" and "Close corresponding bead." Without this, every completed feature increases drift.

3. **Fix factual errors in agent files** — build-compile build-check claim, release-maintenance APPCAST_BOT_TOKEN, two skills referencing nonexistent audit-actor-isolation.

### Important (causing drift)

4. **Decide roadmap.md fate** — Stale, redundant with Beads. Options: delete and migrate, strip counts, or add refresh protocol.

5. **Create a brain refresh skill** — `wispr-refresh-brain-indexes` to regenerate file-index.md, type-index.md, task-router.md from actual source files.

6. **Resolve memories vs knowledge overlap** — 39 bd memories with duplicates. Define ownership boundaries.

7. **Connect docs/plans/ to the brain** — 48 plan files with zero brain references. Active plans should be referenced from relevant knowledge or agent files.

8. **Archive or update TRACKER-ARCHIVED.md** — 6 features show "not started" that are done. Delete or auto-generate from Beads.

### Enhancements (improve efficiency)

9. **Link feature specs to beads** — Add bead IDs to spec headers for bidirectional cross-reference.

10. **Wire isolated knowledge files to agents** — whisperkit-research → audio-pipeline, github-workflow → release-maintenance, when-shit-breaks → relevant agents.

11. **Deduplicate type-index.md enum section** — ~15 entries listed twice.

12. **Add docs/ section to CLAUDE.md** — Zero direct references to docs/ from root. Add a Documentation section.

---

## Appendix: File Inventory

### .claude/knowledge/ (15 files)
architecture.md, conventions.md, gotchas.md, github-workflow.md, file-index.md, type-index.md, task-router.md, feature-catalog.md, roadmap.md, accounts-licensing.md, distribution.md, whisperkit-research.md, beads-governance.md, teamwork.md, when-shit-breaks.md

### .claude/agents/ (11 files)
audio-pipeline.md, build-compile.md, macos-platform.md, quality-security.md, feature-scaffolding.md, testing.md, wispr-eyes.md, release-maintenance.md, feature-planning.md, user-management.md, frontend-designer.md

### .claude/skills/ (45 SKILL.md files)
All listed in CLAUDE.md Agents table. 3 are stubs (user-management domain).

### .claude/rules/ (1 file)
swift-patterns.md (auto-loaded)

### .claude/ hookify (4 files)
block-force-push-main, block-xcodebuild, check-delegation (disabled), warn-fluidaudio-qualifier

### docs/feature-requests/ (24 files)
001 through 022 + duplicate 020 + TRACKER-ARCHIVED.md

### docs/plans/ (48 files)
27 standalone + whisperkit-highway/ (17) + onboarding-fixes/ (12)
