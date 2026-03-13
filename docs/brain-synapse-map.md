# Brain Synapse Map

> Minimum viable map of the brain system for designing freshness/staleness controls.
> Generated 2026-03-11. Do not treat as canonical — this is a snapshot.

---

## 1. Artifact Inventory

### Canonical (17 files, manual, source of truth)

| File | Lines | Notes |
|------|-------|-------|
| `CLAUDE.md` | 65 | Project entry point. References 8 knowledge files + rules. |
| `.claude/rules/swift-patterns.md` | ~50 | Auto-loaded by Claude Code. Swift coding patterns. |
| `knowledge/gotchas.md` | 263 | BRAIN-annotated. Has matching `// BRAIN: gotcha id=X` in source. |
| `knowledge/conventions.md` | 192 | Workflow rules, Definition of Done. |
| `knowledge/pipeline-mechanics.md` | 311 | Runtime behavior reference. Self-contained. |
| `knowledge/architecture.md` | 249 | Manual prose + 6 auto-injected sections. |
| `knowledge/distribution.md` | 101 | Manual prose + 1 auto-injected section. |
| `knowledge/whisperkit-research.md` | 140 | Manual prose + 1 auto-injected section. |
| `knowledge/roadmap.md` | 43 | Points to Beads for live data. |
| `knowledge/brain-manifest.md` | 123 | Authority model for the brain system itself. |
| `knowledge/teamwork.md` | 157 | Agent composition patterns. |
| `knowledge/beads-governance.md` | 67 | Beads usage rules. |
| `knowledge/when-shit-breaks.md` | 337 | Troubleshooting runbook. |
| `knowledge/accounts-licensing.md` | 197 | Design-only (no code yet). |
| `knowledge/completed-work.md` | 70 | Archived beads memories. |

### Generated / Derived (4 full files + 9 auto-sections)

| Artifact | Source | Generator |
|----------|--------|-----------|
| `knowledge/file-index.md` | All `Sources/**/*.swift` | `brain-refresh.sh:generate_file_index()` |
| `knowledge/type-index.md` | All `Sources/**/*.swift` | `brain-refresh.sh:generate_type_index()` |
| `knowledge/task-router.md` (header) | All `Sources/**/*.swift` | `brain-refresh.sh:generate_task_router_generated()` |
| `knowledge/feature-catalog.md` (header) | `SettingsManager.swift` + all `.swift` | `brain-refresh.sh:generate_feature_catalog_generated()` |
| `architecture.md` § settings_sections | `SettingsSection.swift` | auto-inject |
| `architecture.md` § protocol_conformers | All `.swift` (conformance grep) | auto-inject |
| `architecture.md` § pipeline_states | `AppSettings.swift`, `WhisperKitPipeline.swift` | auto-inject |
| `architecture.md` § llm_providers | `LLMResult.swift` | auto-inject |
| `architecture.md` § asr_backend_types | `ASRResult.swift` | auto-inject |
| `architecture.md` § audio_constants | `Constants.swift` | auto-inject |
| `whisperkit-research.md` § whisperkit_defaults | `WhisperKitBackend.swift` | auto-inject |
| `distribution.md` § dependency_versions | `Package.swift` | auto-inject |
| `agents/wispr-eyes.md` § settings_sections | `SettingsSection.swift` | auto-inject |

### Agent Definitions (12 files, manual)

All in `.claude/agents/*.md`. YAML frontmatter (name, model, description). Reference skills by backtick.
`wispr-eyes.md` is unique: has 1 auto-injected section (`settings_sections`).

### Skill Definitions (50 dirs, manual)

All in `.claude/skills/*/SKILL.md`. ~5,300 lines total. Never generated.

### Beads Memories (34 entries)

No expiry metadata. No `last_validated` field. No TTL. Staleness detection is entirely manual.

| Status | Count | Examples |
|--------|-------|---------|
| Healthy canonical | 24 | `paste-system`, `ptt-task-serialization`, `buddies-rulebook` |
| Stale (should delete) | 2 | `website-astro-migration-website-files-in-docs-website` (migration done), `website-seo-status-seo-score-97-100-meta` (superseded) |
| Redundant (subsumed) | 2 | `buddies-hygiene` (in `buddies-rulebook`), `swiftui-plain-button` (in `swift-patterns.md`) |
| Partial dups (consolidate) | 3 | `website-astro-migration` + `astro-website-setup` + `website-cloudflare-live` |

### Audit Scripts (3 files)

| Script | Lines | Role |
|--------|-------|------|
| `scripts/brain-refresh.sh` | 751 | Generates all derived artifacts from source |
| `scripts/brain-check.sh` | 252 | Validates links, freshness, annotations, agent/skill integrity |
| `scripts/brain-prime.sh` | 29 | Session hook: check → auto-refresh if stale |

---

## 2. Authority Map

| Tier | Class | Artifacts | Conflict rule |
|------|-------|-----------|---------------|
| **T1** | Canonical | `CLAUDE.md`, `gotchas.md`, `conventions.md`, `pipeline-mechanics.md`, `architecture.md` (prose), `distribution.md` (prose), `swift-patterns.md` | Always wins. Manual review only. |
| **T2** | Canonical-reference | `teamwork.md`, `beads-governance.md`, `when-shit-breaks.md`, `brain-manifest.md`, `roadmap.md`, `accounts-licensing.md` | Wins over T3/T4. Updated as-needed. |
| **T3** | Derived | `file-index.md`, `type-index.md`, auto-sections in T1 files, generated headers in `task-router.md`/`feature-catalog.md` | Never trusted over T1/T2. Regenerate on source change. |
| **T4** | Agent/Skill definitions | 12 agent `.md`, 50 skill `SKILL.md` | Should align with T1. Flag on contradiction. |
| **T5** | Beads memories | 34 entries in `bd memories` | Lowest authority. Should be validated against T1-T4. |
| **T6** | Disposable | Research scraps, `completed-work.md`, any `/tmp/` outputs | Never authoritative. Archive/delete freely. |

**Conflict resolution:** Higher tier always wins. If T5 (memory) contradicts T1 (canonical), the memory is wrong.

---

## 3. Dependency Map

### What generates what

```
Sources/**/*.swift ──→ brain-refresh.sh ──→ file-index.md
                                        ──→ type-index.md
                                        ──→ task-router.md [header]
                                        ──→ feature-catalog.md [header]

SettingsSection.swift ─────────────────→ architecture.md § settings_sections
                                       → agents/wispr-eyes.md § settings_sections
AppSettings.swift + WhisperKitPipeline.swift → architecture.md § pipeline_states
LLMResult.swift ───────────────────────→ architecture.md § llm_providers
ASRResult.swift ───────────────────────→ architecture.md § asr_backend_types
Constants.swift ───────────────────────→ architecture.md § audio_constants
WhisperKitBackend.swift ───────────────→ whisperkit-research.md § whisperkit_defaults
Package.swift ─────────────────────────→ distribution.md § dependency_versions
Sources/**/*.swift (conformance grep) ─→ architecture.md § protocol_conformers
```

### What references what

| Consumer | References |
|----------|-----------|
| `CLAUDE.md` | `gotchas.md`, `distribution.md`, `file-index.md`, `task-router.md`, `teamwork.md`, `beads-governance.md`, `conventions.md`, `architecture.md`, `pipeline-mechanics.md` |
| `architecture.md` | `file-index.md`, `type-index.md`, `feature-catalog.md`, `pipeline-mechanics.md` |
| `gotchas.md` | `pipeline-mechanics.md`, `github-workflow.md`, `swift-patterns.md` |
| `conventions.md` | `gotchas.md`, `github-workflow.md`, `roadmap.md`, `swift-patterns.md` |
| Agent files | Skill files (by backtick reference) |
| `brain-check.sh` | All `.claude/**/*.md`, `CLAUDE.md`, all `Sources/**/*.swift` |

### Cascade behavior

| Trigger | Currently cascades | Should cascade but doesn't |
|---------|-------------------|---------------------------|
| Any `.swift` file added/deleted/modified | `brain-check.sh` detects stale → `brain-prime.sh` auto-refreshes | Nothing — cascade works |
| `Package.swift` changed | `distribution.md` auto-section updates on refresh | Nothing missing |
| `SettingsSection.swift` changed | `architecture.md` + `wispr-eyes.md` auto-sections update | Nothing missing |
| Canonical doc changed (e.g. `gotchas.md`) | **Nothing.** No cascade to consumers. | Docs referencing it should be flagged for review |
| Agent/skill file changed | **Nothing.** No cascade. | `brain-check.sh` should verify skill refs still valid |
| Beads memory created | **Nothing.** No validation against canonical. | Should check for conflicts with T1 docs |
| Source file deleted | Generated outputs silently shrink. No warning. | Should emit a deletion notice |

---

## 4. Lifecycle Map

### Canonical docs (T1-T2)

| Phase | How |
|-------|-----|
| Created | Manually, by human or agent |
| Updated | Manually. Auto-sections injected by `brain-refresh.sh` but prose is untouched. |
| Becomes stale | When reality drifts from description. No automated detection for manual prose. |
| Validated | `brain-check.sh` catches broken links and stale auto-sections. Manual prose: **never validated automatically.** |
| Archived | Never. Should be: superseded by updated version, old version archived. |

### Generated/derived (T3)

| Phase | How |
|-------|-----|
| Created | `brain-refresh.sh` on first run |
| Updated | `brain-refresh.sh` — full regeneration from source, no incremental |
| Becomes stale | Immediately when any source `.swift` file changes |
| Validated | `brain-check.sh` diffs fresh generation against on-disk |
| Archived | Never archived — simply overwritten. No history. |

### Agent/skill definitions (T4)

| Phase | How |
|-------|-----|
| Created | Manually |
| Updated | Manually |
| Becomes stale | When referenced skills/patterns/protocols change. **No detection.** |
| Validated | `brain-check.sh` checks agent file existence and skill backtick refs. Does NOT validate content accuracy. |
| Archived | Never. Dead skills/agents accumulate. |

### Beads memories (T5)

| Phase | How |
|-------|-----|
| Created | `bd remember "..."` |
| Updated | `bd remember` with same key (overwrites) |
| Becomes stale | Immediately when underlying fact changes. **No detection.** |
| Validated | **Never.** No expiry, no validation date, no staleness check. |
| Archived | Manual `bd forget <key>`. Or bulk archive to `completed-work.md`. |

---

## 5. Gaps / Risks

### Truth ambiguity

| Gap | Risk |
|-----|------|
| **No authority ranking is enforced.** Tiers exist conceptually but nothing prevents a T5 memory from overriding a T1 canonical doc in agent context. | Stale memory wins over accurate doc if agent reads memory first. |
| **Manual prose in canonical docs is never validated.** Only auto-sections and links are checked. | Architecture descriptions, workflow rules, and gotchas can drift silently. |
| **Beads memories have no metadata.** No creation date, no validation date, no expiry, no source link. | Memories quietly gain authority over time. The 34 memories are a growing liability. |
| **`task-router.md` and `feature-catalog.md` have manual sections that reference source code.** | Manual sections can describe files/types that no longer exist. Not caught by checks. |

### Stale knowledge gaining authority

| Vector | Severity |
|--------|----------|
| **Beads memories loaded into every conversation** via system prompt. Stale memories are indistinguishable from fresh ones. | **High.** This is the #1 staleness risk. |
| **Skill docs reference specific APIs, protocols, patterns** that may have changed. `brain-check.sh` only validates file existence, not content accuracy. | **Medium.** Wrong skill guidance → wrong code. |
| **Agent docs reference skill names** but not skill content. An agent can route to a skill whose instructions are outdated. | **Medium.** |
| **`completed-work.md`** is a static archive. Items in it may describe approaches/decisions that were later reversed. | **Low** (rarely consulted). |

### Automation safety boundaries

| Area | Safe to automate? |
|------|-------------------|
| Regenerating T3 derived files | **Yes.** Always safe — deterministic from source. |
| Flagging stale T5 memories | **Yes.** Compare against source code + T1 docs. |
| Auto-deleting T5 memories | **No.** Could delete context that's still valuable but not easily re-derivable. Flag + confirm. |
| Auto-editing T1 canonical prose | **No.** High risk of losing nuance, context, or intentional choices. |
| Auto-archiving T6 disposable | **Yes.** Safe after retention window. |
| Auto-editing T4 skill/agent docs | **No.** These encode human judgment about workflows. Flag for review. |

### Missing capabilities

1. **No source hash tracking.** Freshness requires full regeneration + diff. Adding a manifest with hashes would make drift detection instant.
2. **No cascade from canonical → consumers.** If `gotchas.md` changes, nothing flags docs that reference it.
3. **No memory validation pipeline.** Memories are never compared against canonical docs.
4. **No deletion tracking.** Source file deletions produce silent output changes, no warnings.
5. **No auto-section marker protection.** If `<!-- BEGIN AUTO: X -->` markers are accidentally removed from a canonical file, that section silently stops updating — no error.
6. **`brain-prime.sh` doesn't re-check after refresh.** Assumes refresh succeeded.
7. **No incremental generation.** Every refresh regenerates everything. Fine at current scale (~80 Swift files), won't scale.
