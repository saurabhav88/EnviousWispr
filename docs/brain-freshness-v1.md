# Brain Freshness Controls — V1 Design (Final)

> Based on [brain-synapse-map.md](brain-synapse-map.md).
> Bias: max automation for deterministic artifacts, max detection for judgment-heavy artifacts, minimal human touch for routine hygiene.
> Status: approved for implementation.

---

## 1. trust_state Enum

```
trusted        — source-verified or recently validated, sole clean authority state
review_due     — past validation window, usable but flagged, not equivalent to trusted
stale          — source drift detected or expired, demoted from use
regenerable    — stale + auto-fixable (has regenerate_cmd)
archived       — removed from active use, kept for history
```

### Automated transitions (no human needed)

```
trusted ──[source hash mismatch + has regenerate_cmd]──→ regenerable ──[auto-regen succeeds]──→ trusted
trusted ──[source hash mismatch + no regenerate_cmd]───→ stale
trusted ──[review_interval_days expired]───────────────→ review_due
regenerable ──[auto-regen fails]───────────────────────→ stale (escalate)
```

### Human-required transitions

```
review_due ──[human validates]──→ trusted
review_due ──[human rejects]───→ stale or archived
stale ──[human updates]────────→ trusted
stale ──[human archives]───────→ archived
archived ──[human promotes]────→ trusted (rare)
```

### Authority rules

- `trusted`: **sole clean authority state.** Full confidence, no caveats.
- `review_due`: **usable but flagged.** Agents may use the content but must note it hasn't been validated recently. Session-start notice reminds human to validate. Not equivalent to `trusted` — treat as "probably fine but verify."
- `stale`: warning banner prepended on read, never silently served. Agents should prefer alternative sources.
- `regenerable`: auto-fixed on next `brain-prime.sh` run — zero human touch.
- `archived`: moved to `.claude/archive/`, removed from manifest active list.

---

## 2. Manifest Schema

Single file: `.claude/brain-manifest.json`

```json
{
  "schema_version": 1,
  "last_audit": "2026-03-11T12:00:00Z",
  "artifacts": {
    ".claude/knowledge/file-index.md": {
      "class": "derived",
      "trust_state": "trusted",
      "owner": "brain-refresh.sh",
      "regenerate_cmd": "scripts/brain-refresh.sh",
      "source_glob": "Sources/EnviousWispr/**/*.swift",
      "source_hash": "sha256:abc123...",
      "content_hash": "sha256:xyz789...",
      "last_generated": "2026-03-11T12:00:00Z",
      "last_validated": "2026-03-11T12:00:00Z",
      "expiry_policy": "on_source_change",
      "review_interval_days": null
    },
    ".claude/knowledge/gotchas.md": {
      "class": "canonical",
      "trust_state": "trusted",
      "owner": "human",
      "regenerate_cmd": null,
      "source_glob": null,
      "source_hash": null,
      "content_hash": "sha256:abc456...",
      "last_generated": null,
      "last_validated": "2026-03-11T00:00:00Z",
      "expiry_policy": "manual_review",
      "review_interval_days": 30
    },
    ".claude/knowledge/architecture.md": {
      "class": "canonical",
      "trust_state": "trusted",
      "owner": "human",
      "regenerate_cmd": null,
      "source_glob": null,
      "source_hash": null,
      "content_hash": "sha256:def789...",
      "last_generated": null,
      "last_validated": "2026-03-11T00:00:00Z",
      "expiry_policy": "manual_review",
      "review_interval_days": 30,
      "auto_sections": {
        "settings_sections": {
          "source_file": "Sources/EnviousWispr/Views/Settings/SettingsSection.swift",
          "source_hash": "sha256:def456..."
        },
        "protocol_conformers": {
          "source_glob": "Sources/EnviousWispr/**/*.swift",
          "source_hash": "sha256:ghi789..."
        },
        "pipeline_states": {
          "source_files": [
            "Sources/EnviousWispr/Models/AppSettings.swift",
            "Sources/EnviousWispr/Pipeline/WhisperKitPipeline.swift"
          ],
          "source_hash": "sha256:jkl012..."
        },
        "llm_providers": {
          "source_file": "Sources/EnviousWispr/Models/LLMResult.swift",
          "source_hash": "sha256:mno345..."
        },
        "asr_backend_types": {
          "source_file": "Sources/EnviousWispr/Models/ASRResult.swift",
          "source_hash": "sha256:pqr678..."
        },
        "audio_constants": {
          "source_file": "Sources/EnviousWispr/Utilities/Constants.swift",
          "source_hash": "sha256:stu901..."
        }
      }
    }
  },
  "memories": {
    "paste-system-tiered-cascade-validated-tier-1-ax": {
      "trust_state": "trusted",
      "last_validated": "2026-03-11T00:00:00Z",
      "review_interval_days": 30,
      "referenced_paths": [
        "Sources/EnviousWispr/Services/PasteService.swift"
      ]
    }
  }
}
```

### Source hash computation

```bash
# Glob-based (all swift files): hash the sorted file list + contents
find Sources/EnviousWispr -name '*.swift' -print0 | sort -z | \
  xargs -0 shasum -a 256 | shasum -a 256 | cut -d' ' -f1

# Single file:
shasum -a 256 < path/to/file.swift | cut -d' ' -f1

# Multi-file (explicit list):
cat file1.swift file2.swift | shasum -a 256 | cut -d' ' -f1
```

### Manifest integrity

- If manifest is missing: bootstrap from current state (all `trusted`, timestamps = now), then proceed
- If manifest fails JSON parse: delete + bootstrap, emit WARNING
- Manifest is updated atomically: write to `.brain-manifest.json.tmp`, then `mv`
- `content_hash` per artifact enables detecting manual edits to generated files (someone hand-edited file-index.md)

---

## 3. Structural Guards (first-class automated checks)

These run in `brain-check.sh` and are hard failures (exit 1).

### Guard 1: Source file deletion warning

```bash
# For each artifact with source_glob or source_file(s) in manifest:
# Resolve glob, compare file list against last known set
# If files disappeared → WARNING with specific file names
```

Output: `DELETED: Sources/EnviousWispr/ASR/OldBackend.swift (referenced by type-index.md source_glob)`

Not a hard failure (derived files self-heal on regen), but logged prominently so humans notice architectural changes.

### Guard 2: Missing AUTO markers (hard fail)

```bash
# For each auto_section in manifest:
# Verify both BEGIN and END markers exist in target file
# Missing marker = BROKEN (exit 1), not just WARNING
```

Current behavior: `inject_auto_section` silently no-ops on missing markers.
New behavior: check markers BEFORE injection. Missing = hard fail. Human must restore.

### Guard 3: Manifest corruption fallback

```bash
# At top of brain-check.sh:
if ! python3 -c "import json; json.load(open('$MANIFEST'))" 2>/dev/null; then
    echo "WARNING: Manifest corrupt or missing. Falling back to full-regen diff."
    # Run legacy full-regen-diff check
    # Then bootstrap fresh manifest from results
fi
```

### Guard 4: Post-refresh re-check in brain-prime.sh

Current: refresh runs, assumes success.
New: after refresh, re-run hash comparison for all regenerable artifacts. If still mismatched → hard WARNING (refresh didn't fix the problem).

```bash
# brain-prime.sh
brain-check.sh
if [[ $? -ne 0 ]]; then
    brain-refresh.sh
    # RE-CHECK: verify refresh actually fixed things
    brain-check.sh --hash-only  # fast path: hashes only, no link/annotation checks
    if [[ $? -ne 0 ]]; then
        echo "WARNING: brain-refresh.sh ran but artifacts still stale. Manual investigation needed."
    fi
fi
```

---

## 4. Audit Rules by Artifact Class

### Derived files (T3) — FULLY AUTOMATED

| Check | Action | Human needed? |
|-------|--------|---------------|
| Source hash mismatch | Set `regenerable` → auto-regen → set `trusted` | **No** |
| Missing on disk | Regenerate immediately | **No** |
| Content hash mismatch (manual edit detected) | Overwrite with regenerated version, emit notice | **No** |
| Source file deleted | Regenerate (file disappears from output), emit DELETED notice | **No** |

### Auto-sections in canonical files (T3-in-T1) — FULLY AUTOMATED (content only)

| Check | Action | Human needed? |
|-------|--------|---------------|
| Section source hash mismatch | Re-inject section content | **No** |
| Missing markers | **HARD FAIL** — do not proceed | **Yes** (restore markers) |
| Marker pair incomplete (BEGIN without END) | **HARD FAIL** | **Yes** |

### Canonical prose (T1-T2) — DETECT ONLY

| Check | Action | Human needed? |
|-------|--------|---------------|
| review_interval_days expired | Auto-set `review_due` in manifest | **No** (transition is automated) |
| Broken links | Auto-fix link path if target moved (simple rename detection) | **No** for path fixes. **Yes** for dead targets. |
| Content changed since last validation | Update content_hash, keep trust_state (informational) | **No** |
| Flagged `review_due` | Session-start notice | **Yes** (validate or update) |

### Agent/skill definitions (T4) — DETECT ONLY

| Check | Action | Human needed? |
|-------|--------|---------------|
| Referenced skill SKILL.md missing | WARNING | **Yes** |
| Orphan (unreferenced) agent/skill | WARNING | **Yes** (integrate or delete) |
| review_interval_days (60d) expired | Auto-set `review_due` | **No** (transition automated) |

### Beads memories (T5) — AUTOMATED DETECTION + REVIEW QUEUE

| Check | Detection method | Suggested action |
|-------|-----------------|-----------------|
| Dead file reference | Parse memory content for paths, `[[ -e path ]]` | `stale` — suggest delete or update |
| Duplicate | Jaccard similarity on tokenized content > 0.6 | `superseded` — suggest merge into newer |
| Superseded | Same topic prefix (e.g. `website-*`), newer exists | `superseded` — suggest delete older |
| Review window expired (30d) | `last_validated` + 30 < now | `review_due` — suggest validate |
| References deprecated pattern | Content mentions known-deprecated terms (maintained list) | `stale` — suggest update or delete |

All detections auto-populate a **review queue**. No auto-deletion.

---

## 5. Beads Memory Review Queue

### Queue format (output of `scripts/brain-audit-memories.sh`)

```
=== Memory Review Queue (7 items) ===

DELETE (confirmed stale):
  1. website-astro-migration-website-files-in-docs-website
     Reason: Describes "next step" that shipped. Fully superseded.
     Action: bd forget website-astro-migration-website-files-in-docs-website

  2. website-seo-status-seo-score-97-100-meta
     Reason: Says canonicals point to github.io. Fixed. Superseded by website-seo-status.
     Action: bd forget website-seo-status-seo-score-97-100-meta

DELETE (redundant):
  3. buddies-hygiene-proactively-offer-to-delete-finished-session
     Reason: Subsumed by buddies-rulebook HYGIENE section.
     Action: bd forget buddies-hygiene-proactively-offer-to-delete-finished-session

  4. swiftui-plain-button-hit-testing-buttonstyle-plain-makes
     Reason: Duplicated in .claude/rules/swift-patterns.md.
     Action: bd forget swiftui-plain-button-hit-testing-buttonstyle-plain-makes

MERGE (3 → 1):
  5. website-astro-migration + astro-website-setup-* + website-cloudflare-live
     Reason: Three memories describing the same website setup.
     Action:
       bd remember "website-setup" "Astro 6 website in website/ dir. ..."
       bd forget website-astro-migration
       bd forget astro-website-setup-astro-website-lives-in-website
       bd forget website-cloudflare-live

REVIEW (needs human judgment):
  (none currently)

=== Batch confirm? [y/N/select numbers] ===
```

### Batch-confirm flow

```bash
scripts/brain-audit-memories.sh           # Show queue
scripts/brain-audit-memories.sh --apply   # Execute all suggested actions (with confirmation prompt)
scripts/brain-audit-memories.sh --apply 1,2,3  # Execute only items 1, 2, 3
scripts/brain-audit-memories.sh --dry-run # Show what would happen without executing
```

### Detection implementation

```bash
# Dead file references:
# Extract paths from memory content using regex: /Sources\/[^\s]+|\.claude\/[^\s]+/
# Test each with [[ -e "$PROJECT_ROOT/$path" ]]

# Duplicate detection:
# Tokenize each memory (split on whitespace, lowercase, remove punctuation)
# Pairwise Jaccard: |A ∩ B| / |A ∪ B| > 0.6 → flag as duplicate

# Superseded detection:
# Group memories by topic prefix (first 2 hyphen-delimited segments)
# If group has >1 member, newer (by content clues or creation order) supersedes older

# Deprecated terms (maintained in manifest or inline):
# DEPRECATED_TERMS=("saurabhav88.github.io" "docs/website/" "XCTest" "xcodebuild")
# grep each term across all memory content
```

---

## 6. Implementation Plan

### Phase 1: Manifest + hashing infrastructure

**New files:**
- `.claude/brain-manifest.json` — the manifest
- `scripts/brain-hash.sh` — hash computation utility

**Modified:**
- `scripts/brain-refresh.sh` — after each generation/injection, compute + write hashes to manifest

**brain-hash.sh interface:**
```bash
brain-hash.sh glob "Sources/EnviousWispr/**/*.swift"   # → sha256 of glob contents
brain-hash.sh file "Sources/.../SettingsSection.swift"  # → sha256 of single file
brain-hash.sh files "file1.swift" "file2.swift"         # → sha256 of concatenated
brain-hash.sh manifest                                   # → recompute all hashes, print diff
```

**Bootstrap:** First run of updated `brain-refresh.sh` creates manifest from scratch with all current hashes.

### Phase 2: Fast stale detection + structural guards

**Modified:** `scripts/brain-check.sh`

Replace full-regen-diff with:
1. Read manifest (fallback to legacy diff if corrupt/missing)
2. Hash compare for all derived artifacts + auto-sections
3. Marker existence check for all auto-sections (hard fail if missing)
4. Source file deletion scan (compare glob results against last known)
5. Review interval check for canonical/reference files
6. Update trust_states in manifest
7. Summary: `N trusted, N review_due, N stale, N regenerable`

### Phase 3: Automated prime loop

**Modified:** `scripts/brain-prime.sh`

```
1. bd prime
2. brain-check.sh
3. If regenerable artifacts exist → brain-refresh.sh
4. Post-refresh re-check (hash-only fast path)
5. If still stale after refresh → WARNING (non-blocking)
6. Print session-start notice:
   - Trust summary (N trusted / N review_due / N stale)
   - Review_due items (file + days since validation)
   - Memory review queue count (if > 0)
```

### Phase 4: Memory audit automation

**New:** `scripts/brain-audit-memories.sh`

- Reads all memories from `bd memories`
- Runs detection checks (dead refs, duplicates, superseded, expired)
- Builds review queue with suggested actions
- Supports `--apply` for batch execution with confirmation
- Supports `--dry-run` for preview
- Integrated into session-start notice (count only, not full queue)

### Phase 5: Validation workflow

**New:** `scripts/brain-validate.sh <file|--all-due>`

- `brain-validate.sh .claude/knowledge/gotchas.md` → mark as validated, update manifest
- `brain-validate.sh --all-due` → list all review_due artifacts, validate interactively
- Updates `last_validated` and sets `trust_state: trusted`
- If agent-driven: agent reads file, compares against source code, auto-validates if no drift found

---

## 7. Auto-fix vs Review-only Boundaries

### Auto-fix (zero human touch)

| What | How |
|------|-----|
| Derived file regeneration | Source hash mismatch → regenerate → update manifest |
| Auto-section injection | Section source hash mismatch → re-inject → update manifest |
| Trust state: `trusted → regenerable` | Automated on hash mismatch |
| Trust state: `regenerable → trusted` | Automated on successful regen |
| Trust state: `trusted → review_due` | Automated on interval expiry |
| Manifest bootstrap | Auto-create from current state if missing/corrupt |
| Post-refresh verification | Re-check hashes after refresh |
| Memory review queue generation | Auto-detect stale/dup/superseded, build queue |
| Content hash tracking | Update on any file change detection |

### Review-only (human approves)

| What | How flagged |
|------|-------------|
| Canonical prose changes | Session-start notice when `review_due` |
| Beads memory cleanup | Review queue with suggested actions + batch-confirm |
| Missing AUTO markers | Hard fail — human restores markers |
| Agent/skill content accuracy | `review_due` after 60 days |
| Trust state: `stale → archived` | Human decision only |
| Trust state: `stale → trusted` (for non-regenerable) | Human validates content |

### Hard rules

1. **Never auto-edit canonical prose.** Auto-sections yes. Surrounding prose never.
2. **Never auto-delete beads memories.** Build queue, suggest actions, require confirmation.
3. **Never auto-edit agent/skill docs.** Flag + notice only.
4. **Always auto-regenerate derived files.** No approval needed. They are deterministic.
5. **Missing AUTO markers = hard fail.** Do not silently skip. Do not auto-restore.
6. **Manifest is always auto-maintained.** Hashes, timestamps, trust_states — all objective.
7. **Post-refresh re-check is mandatory.** Never assume refresh succeeded.

---

## 8. Human work reduced to

| Task | Frequency | Effort |
|------|-----------|--------|
| Approve memory cleanup queue | When flagged (est. monthly) | ~5 min (batch confirm) |
| Validate canonical prose | Every 30 days per file (~15 files) | ~2 min per file, staggered |
| Review flagged agent/skill docs | Every 60 days (when flagged) | ~5 min per file |
| Restore missing AUTO markers | Rare (accidental deletion) | ~1 min |

Everything else is automatic.

---

---

> **Note:** One-time beads memory remediation (7 operations, 34 → 27 memories) is tracked separately. See [brain-beads-remediation.md](brain-beads-remediation.md). That cleanup is independent of V1 system rollout and can be executed at any time.
