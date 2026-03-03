# Beads Cleanup Plan — ew-hi7

Beads adopted (v0.58.0, Dolt server on 3307). 19 stale TRACKER.md references remain across 9 files.

## P0 — Agent/Skill Will Break (fix first)

### `.claude/agents/feature-planning.md` (8 refs)
- Line 31: "Update `docs/feature-requests/TRACKER.md` status"
- Line 68: "Update TRACKER.md status"
- Line 75: "Only update TRACKER.md to complete after validator confirms"
- Line 90: "TRACKER.md updated before UAT passes"
- Line 99: "Ensure Smart UAT passes before updating TRACKER.md"
- Line 100: "Only mark feature complete in TRACKER.md"
- Line 127: "update TRACKER.md"
- Line 151: "update TRACKER.md with incremental status"
- **Action:** Replace all TRACKER.md workflow steps with `bd close <id>` pattern. Feature completion = close Beads issue, not edit a markdown file.

### `.claude/skills/wispr-implement-feature-request/SKILL.md` (3 refs)
- Line 10: prereq "status `[x]` in TRACKER.md"
- Line 81: completion step "edit `docs/feature-requests/TRACKER.md`"
- Line 102: checklist "TRACKER.md updated"
- **Action:** Replace prereq with `bd show <id>`, completion with `bd close <id>`.

### `.claude/knowledge/conventions.md` (1 ref)
- Line 120: "Status tracked in `TRACKER.md` (source of truth)"
- **Action:** Replace with "Status tracked in Beads (`bd ready`, `bd stats`)"

## P1 — Misleading References (fix second)

### `.claude/knowledge/architecture.md` (line 41)
- Shows `TRACKER.md` as "Master status checklist" in directory tree
- **Action:** Update to show `TRACKER-ARCHIVED.md` or remove line

### `.claude/knowledge/task-router.md` (line 191)
- Tracker path: `docs/feature-requests/TRACKER.md`
- **Action:** Update to Beads commands

### `.claude/skills/wispr-release-checklist/SKILL.md` (line 219)
- Post-release: "Update `docs/feature-requests/TRACKER.md` with shipped features"
- **Action:** Replace with `bd close <ids> --reason "shipped in vX.Y.Z"`

### `CLAUDE.md` (line 68)
- Roadmap description mentions "tracker" — now misleading
- **Action:** Update description to mention Beads

## P2 — Historical (defer)

Plan files in `docs/plans/` — 6 refs. These are historical docs, low impact. Leave as-is.

## Additional Fixes

### Wrong command in governance doc
- `.claude/knowledge/beads-governance.md`: `bd admin compact --days 90` is wrong
- **Fix:** Replace with correct compaction command per 0.58.0 docs

### wispr-check-feature-tracker Definition of Done
- Still references `wispr-run-smart-uat` (deprecated)
- **Fix:** Replace with `wispr-eyes`

### Evaluate `bd remember` / `bd memories`
- New in 0.58.0 — persistent agent memory
- Could consolidate some MEMORY.md content into Beads
- **Action:** Research only, defer changes

## Execution

1. Claim: `bd update ew-hi7 --status=in_progress`
2. Fix P0 files (3 files, 12 refs)
3. Fix P1 files (4 files, 4 refs)
4. Fix governance doc command
5. Fix feature-tracker DoD
6. Verify: `grep -r "TRACKER\.md" .claude/ --include="*.md" -l` returns 0 active refs
7. Close: `bd close ew-hi7 --reason "All stale refs updated"`
