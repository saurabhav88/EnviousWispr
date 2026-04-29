# Issue #498 — UAT restructure Stage 1: behavioral discipline + infrastructure, no hard hooks — 2026-04-29

GitHub issue: `#498`. Parent / epic: `#319` (Hardening). Tier: MEDIUM (workflow rule + scripts + new artifact convention; no `Sources/` code change in this PR). Status: DRAFT.

## Preface — User Rubric

`User Rubric: N/A — workflow-discipline restructure is internal-only, no user-visible surface.`

## 0. Lane + Live UAT declaration

**Lane:** **Docs/dev-tooling.** Mostly rule-file edits + plan-template additions, BUT this PR also adds two new tracked executable scripts (`scripts/validate-pr.sh`, `scripts/check-validation.sh`) and reworks `scripts/attest.sh`. Per Codex grounded review 2026-04-29, new shell scripts that govern workflow are not pure docs — they require execution smoke + ShellCheck + fixture-based self-tests on day one, not deferred to future PRs.

**Detected lanes from `git diff --name-only` against base:** what actually ships in the PR diff is `.gitignore` + the tracked `scripts/` changes. Per `.gitignore` lines 25 (`.claude/`), 31 (`Tests/UITests/`), 47 (`.validation/`), 135 (`docs/`), the rule edits + plan-template edits + memory entries + this very plan file are all gitignored "local update-in-place" artifacts and do not ship in the PR diff unless force-added. Established convention (see Phase D PR #497, Phase A/B/C plan files, decisions file): plan files stay local; the Bible is the only docs/feature-requests/ file ever force-added.

**Live UAT:** N/A for the macOS app (no `Sources/`, no `Tests/`, no `Package.swift`). For the framework itself, validation IS required and runs day one via:
- `scripts/validate-pr.sh --self-test` — fixture run dirs proving lane detection + Phase 3 sequence.
- `scripts/check-validation.sh --self-test` — fixture run dirs proving PASS/WARN/FAIL semantics.
- ShellCheck on new and reworked scripts (wired into `scripts/test-validation.sh` aggregator).
- Codex prose review on rule + plan-template edits.
- `grep -rn "needs-uat\|.needs-uat" .claude/scripts/ scripts/ .claude/settings.json` returns empty.

**Plan-vs-detection check (manual, since auto-detection lives inside this very PR):** plan declares Docs/dev-tooling; detection returns `.gitignore` + tracked `scripts/` changes (subset of Docs/dev-tooling). Match.

**Probationary Stage 1.** This PR is explicitly framed as a one-try probationary infrastructure ship, NOT a steady-state solution to the 60-time UAT-bypass pattern. Stage 1 builds the artifact contract + verifier + lane vocabulary and ships them as advisory tools. Stage 2 (archived) is the pre-decided escalation that wires the same verifier into a `git push` hook. The triggers for Stage 1 → Stage 2 escalation are non-negotiable and enumerated in §3.1 + the archive doc.

## 1. Problem

I (Claude) have shipped ~60 PRs through a UAT discipline that I keep bypassing. Tonight (PR #497, Phase D) the bypass shipped a build that broke mic + recording overlay for the founder. Two structural failures:

1. **Per-task `.needs-uat` hook fires on every source-file edit.** Most individual edits don't need UAT; only the aggregate PR does. The mismatch trained a bypass muscle: every TaskUpdate that hit the gate got worked around because the work wasn't done at that task boundary.
2. **`scripts/clear-uat.sh` is just `rm -f .needs-uat`.** Zero proof-of-life. I cleared it after smoke + log scan + clean launch, called that UAT, and shipped. The script let me lie to myself.

The deeper truth (founder's words, this session): "This isn't a one-time occurrence. This has happened about sixty times now." Behavioral-only fixes have failed for me at this pattern's scale. Discipline structures need to back behavior with infrastructure that makes the bypass surface visible.

But hard mechanical enforcement at the PR boundary is OUT OF SCOPE for Stage 1 — virtual PRs at this project take 30+ minutes per cycle, and PR-time enforcement would make every commit cycle a 30-min wait. Push-time hooks and PR-comment writes that require CI integration are what Stage 2 covers; Stage 1 is what we can do entirely locally without touching the PR cycle time.

## 2. Goals & non-goals

### 2.1 Goals
- Delete the per-task `.needs-uat` hook + `clear-uat.sh` (lived pain, structural fix).
- Add UAT planning to `docs/feature-requests/TEMPLATE.md` — Phase 1 lane question + Phase 2 Live UAT spec (recipe, sentence, expected token, core acceptance vs feature acceptance, evidence path).
- Restructure Phase 3 in `.claude/rules/workflow-process.md §1` step 9 with explicit 6-step sequence (logic tests → smoke → Live UAT → Codex code-diff → bug fixes → push).
- Define sharp terminology in `workflow-process.md`: Smoke ≠ Live UAT ≠ Merge-ready.
- Add per-lane Phase 3 obligations to `.claude/rules/validation-discipline.md §11` (Code, Content, CI/workflow, Eval-harness, Worker, Docs/dev-tooling).
- Build the run-directory + verifier + single-command runner infrastructure (Stage 1.5 of GPT's design — present as advisory, not enforcing):
  - `.validation/runs/<timestamp>-<shortsha>/` convention with one consolidated `run.json` (`schema_version: 1`, `head_sha`, `branch`, `declared_lane`, `detected_lanes`, `started_at`, `completed_at`, `obligations_satisfied[]`) + lane-specific artifacts.
  - `scripts/validate-pr.sh` (single-command runs Phase 3 in order, writes the run dir; supports `--self-test` mode with fixture run dirs).
  - `scripts/check-validation.sh` (verifier reads latest run dir, prints completeness — advisory in Stage 1, blocks in Stage 2; supports `--self-test` mode and `--strict` flag).
  - `scripts/attest.sh` reworked to write into run dirs, bind to current HEAD SHA + bundle path. Existing `.validation/events.jsonl` low-signal append-only log stays (cross-PR breadcrumb), but run dirs are the canonical primary evidence.
- **Self-tests required day one.** Both new scripts ship with `--self-test` mode following the `scripts/check-xpc-error-hygiene.sh:17` convention. Wired into `scripts/test-validation.sh` (existing ShellCheck + Bats aggregator at `scripts/test-validation.sh:35-60`). ShellCheck must pass on all new and reworked scripts.
- Archive the aggressive Stage 2 design (hard pre-push hooks, mechanical mixed-PR enforcement, lane auto-detect blocking) as `docs/feature-requests/issue-498-aggressive-plan-stage2-2026-04-29.md` SHELVED, with the explicit `.claude/settings.json` diff documented for Stage 1 → Stage 2 escalation. Stage 2 fail-closed core narrowed: missing run dir, HEAD mismatch, missing required lane artifacts, undeclared mixed-lane case ONLY. Weaker heuristics (lane mismatch, etc.) stay as warnings until proven near-zero-noise. Logged escape hatch via `UAT_BYPASS_REASON=<reason> git push` writes to `.validation/bypass-log.jsonl`.
- Memory entries: `feedback_uat_phase3_required.md` (Phase 3 sequence is mandatory), `feedback_aggressive_plan_escalation_trigger.md` (trigger conditions + path to Stage 2 + decision rule: when arguing to skip a Phase 3 step, MUST either write `skip-note.txt` to the run dir explaining why OR trigger Stage 2 escalation).

### 2.2 Non-goals
- **No hard hooks at the `git push` or PR boundaries** in this PR. Stage 2 territory.
- **No PR-body comment writes** (founder ruled out — PR-boundary friction is incompatible with virtual-PR cycle time).
- **No `Sources/` changes** (build-SHA-in-startup-log goes in a separate Code-lane follow-up that becomes the first dogfood of the new framework on a real synthetic UAT).
- **No founder-gated PR merges** for any lane. The eval-harness "private corpus run when semantics change" obligation becomes "PR description must include the harness output summary as text; founder reads but doesn't run" — visible artifact, not blocking action.
- **No relitigation of Stage 1 → lighter design.** If UAT discipline slips again under Stage 1, escalate to Stage 2 per the archived plan; do not propose stripping further.

## 3. Design

### 3.1 Two-stage commitment

**Stage 1 (this PR):**
Behavioral discipline backed by:
- The plan template forces lane + UAT planning before code is written.
- Phase 3 6-step sequence in `workflow-process.md §1` says exactly what runs after build.
- `validate-pr.sh` is a single command that walks Phase 3 — eliminates "remember six things" failure mode.
- Run directory + verifier are the artifact contract — every PR's run dir has lane-specific evidence.
- Per-lane obligations in `validation-discipline.md §11` map lane → required artifacts.
- I'm trusted to invoke `validate-pr.sh` and write to the run dir. The verifier prints warnings if I don't, but doesn't block.

**Stage 2 (archived, ready to deploy):**
Same infrastructure + a `PreToolUse` hook on `git push` that calls `check-validation.sh` and blocks push if the latest run dir for the current HEAD SHA is incomplete or missing for the detected lane. Local-only enforcement (push-time, never PR-time). Archive doc names the exact `.claude/settings.json` lines to add — escalation is a 5-minute change, not a redesign.

**Trigger conditions for Stage 1 → Stage 2 escalation** (documented in `feedback_aggressive_plan_escalation_trigger.md` and archive doc):
- Any session where I bypass `validate-pr.sh` and push without writing a run dir.
- Any PR where I claim "smoke = UAT" again (treating build-launches-clean as evidence of feature correctness).
- Any shipped regression that synthetic-dictation Live UAT would have caught.
- Founder calls escalation explicitly.

### 3.2 Lane definitions (Docs-only Stage 1 doesn't auto-detect mechanically; it relies on declared-lane in plan + advisory check)

| Lane | Path globs | Phase 3 obligations | Artifact in run dir |
|---|---|---|---|
| **Code** | `Sources/**`, `Tests/**`, `Package.swift`, `Package.resolved` | Logic tests + smoke + synthetic dictation Live UAT (or manual-human if flagged) + Codex code-diff | `tests.log`, `smoke.json` (build version + bundle path), `live-uat.json` (recipe, sentence, expected token, observed transcript, exit code, app path), `codex-review.txt` |
| **Content** | `website/src/content/**`, `website/src/components/**`, `website/public/**`, `assets/**`, `content-engine/**`, marketing copy | Astro build pass + broken-link check + visual confirm + optional Codex prose | `astro-build.log`, `link-check.txt`, `preview-url.txt` |
| **CI/workflow** | `.github/workflows/**`, dependabot configs | Workflow evidence-of-execution (must have run on the modified version, accounting for path filters / reusable-workflow / dispatch-only) | `workflow-run-url.txt` with the PR's HEAD SHA |
| **Eval-harness** | `scripts/eval/**`, public corpus files (private corpus is gitignored) | Public corpus run + `acceptance_gate.py` + metric-delta summary. **When harness semantics change (scoring, normalization, acceptance logic, corpus filtering, report shape) — private founder-corpus run REQUIRED**, with structured `private-corpus-summary.txt` written to run dir AND pasted into PR body. **Eval-harness reporting NEVER substitutes for app Live UAT in mixed PRs that also touch product runtime.** | `acceptance-gate.json`, `metric-delta.txt`, **always** `private-corpus-summary.txt` when private corpus triggered (required fields: `corpus_version_or_date`, `total_pass_rate`, `comparison_vs_previous_baseline`, `regression_one_liner`) |
| **Worker** | `workers/**` | Worker test + smoke deploy + endpoint smoke | `worker-test.log`, `deploy-id.txt`, `endpoint-response.json` |
| **Docs/dev-tooling** | `docs/**`, `.claude/**`, `CLAUDE.md`, knowledge files, plan files, `scripts/*.sh` (workflow tooling, NOT product code) | Codex prose review on rule + plan edits + grep for broken refs. **Plus, when new shell scripts are added or reworked: ShellCheck must pass + each new script's `--self-test` mode must exit 0** (per existing convention at `scripts/check-xpc-error-hygiene.sh:17` + aggregator at `scripts/test-validation.sh:35-60`). | `codex-prose.txt`, `broken-refs-grep.txt`, plus when scripts changed: `shellcheck.txt`, `self-test.txt` |

**Mixed PRs:** if two non-docs lanes are touched, the plan must include `mixed_pr: true` + per-lane validation listed + Codex sign-off in grounded review. Stage 1 doesn't mechanically enforce; the rule is "if you're going to mix, you owe each lane its FULL obligation, and the plan reviewer (Codex grounded review) must sign off." Docs/dev-tooling companion to a primary lane is always allowed (the common case of plan-file + code-edit in one PR). Eval-harness reporting NEVER stands in for app Live UAT — if a PR touches both `scripts/eval/` and `Sources/`, both lanes' artifacts must exist.

### 3.3 Run directory model

Path: `.validation/runs/<YYYY-MM-DDTHH-MM-SS>-<shortsha>/` (gitignored — `.validation/` already at `.gitignore:47`).

`run.json` schema (Stage 1, version 1):

```json
{
  "schema_version": 1,
  "head_sha": "abc1234567890...",
  "branch": "feat/issue-XXX-...",
  "declared_lane": "Code | Content | CI/workflow | Eval-harness | Worker | Docs/dev-tooling",
  "detected_lanes": ["Code", "Docs/dev-tooling"],
  "is_mixed_pr": false,
  "started_at": "2026-04-29T16:30:00Z",
  "completed_at": "2026-04-29T16:32:15Z",
  "obligations_satisfied": ["tests", "smoke", "live-uat", "codex-review"],
  "obligations_skipped": [],
  "skip_notes": []
}
```

Adjacent lane-specific artifacts per the table in §3.2.

`scripts/check-validation.sh <PATH> [--strict]` reads a run directory and asserts:
1. `run.json` exists, parses, has `schema_version` ≥ 1, has `head_sha` matching `git rev-parse HEAD`.
2. `declared_lane` matches at least one of `detected_lanes`; if `is_mixed_pr=false` and `detected_lanes.length > 1`, prints WARN (Stage 1) or FAIL (Stage 2 strict).
3. Every required artifact for the declared lane is present and non-empty.
4. If `live-uat.json` is present (Code lane), its `expected_token` field appears in its `observed_transcript` field.
5. If `obligations_skipped` is non-empty, every entry must have a corresponding `skip_notes` entry; if Stage 2 strict, any skip without note FAILS.
6. Prints PASS / WARN / FAIL with details. Exit code reflects (0 / 1 / 2).
7. `--self-test` mode: runs against canned fixture run dirs in `.claude/scripts/check-validation-fixtures/` covering passing case, missing-artifact case, head-mismatch case, undeclared-mixed case. Exits 0 only if all fixtures produce expected verdict.

`scripts/validate-pr.sh [--self-test]` orchestrates:
1. Read declared lane from the most recent `docs/feature-requests/issue-*.md` plan file (Phase 1 lane field) or fall back to detection from `git diff --name-only origin/main` against the path globs in §3.2.
2. Compare declared vs detected; warn on mismatch (Stage 1) or fail (Stage 2 strict).
3. Walk Phase 3 in order: logic tests → smoke → Live UAT (lane-specific, see §3.2) → Codex code-diff. Each step's output writes into the run dir.
4. If a step is skipped, require a `skip-note.txt` in the run dir explaining why before continuing.
5. Call `check-validation.sh` at the end as the final assertion.
6. `--self-test` mode: runs Phase 3 walk against a fixture project (mock `git diff`, mock script outputs) to confirm the orchestrator correctly writes the run dir and fails on missing steps.

### 3.4 Stage 2 escalation contract (full design in archive doc)

When triggered, Stage 2 wires `check-validation.sh --strict` into a `PreToolUse` hook on `git push` via `.claude/settings.json`. Strict mode's fail-closed core (initial deployment) is narrow:
- Missing run dir for current HEAD SHA → FAIL.
- `head_sha` in run.json does not match current HEAD → FAIL.
- Required lane artifacts missing or empty → FAIL.
- Undeclared mixed-lane PR (`detected_lanes.length > 1` AND `is_mixed_pr=false`) → FAIL.
- Lane mismatch (declared ≠ detected) → WARN initially, promoted to FAIL only after warnings prove near-zero-noise.

**Logged escape hatch:** `UAT_BYPASS_REASON="<one-line reason>" git push <args>` — the pre-push hook detects the env var, appends `{ts, head_sha, branch, reason}` to `.validation/bypass-log.jsonl`, and allows the push. Bypass usage is grep-able in retrospect; not a casual override but a sanctioned break-glass with a paper trail.

**Skip-note discipline (Stage 1 + Stage 2):** when arguing to skip any Phase 3 step, MUST either (a) write `skip-note.txt` to the run dir with one-sentence rationale before push, OR (b) trigger Stage 2 escalation. Mantra alone is insufficient — the act of writing the skip note makes the omission visible and auditable.

### 3.4 What the hooks audit looks like

**Files DELETED:**
- `.claude/scripts/mark-uat-and-tier.sh` — the PostToolUse hook on Edit/Write that creates `.needs-uat`.
- `.claude/scripts/uat-todowrite-gate.sh` — the PreToolUse hook on TodoWrite/TaskUpdate that blocks completion.
- `scripts/clear-uat.sh` — the manual marker remover.

**Files EDITED to strip `.needs-uat` references:**
- `.claude/scripts/command-safety.sh` — Branch 4 deletion (manual `.needs-uat` removal block goes away with the marker concept).
- `.claude/scripts/protected-files-hook.sh` — line 14 regex strips `.needs-uat`.
- `.claude/scripts/session-end-check.sh` — lines 65-66 stale-marker warning removed (replaced with: warn if `.validation/runs/` is empty for current HEAD).
- `.claude/settings.json` — hook entries at lines 57+133 removed (PostToolUse mark-uat + PreToolUse uat-gate).

**Files EDITED to add new framework:**
- `.claude/rules/workflow-process.md §1` step 9 — Phase 3 6-step sequence + sharp terminology defs.
- `.claude/rules/validation-discipline.md §11` — replace tier-cumulative-checks with per-lane obligations table.
- `docs/feature-requests/TEMPLATE.md` — Preface lane question + §11 Live UAT subsection with the GPT-recommended fields (subsystem touched, driver, input sentence, preconditions, core acceptance, feature acceptance, evidence path).

**Files NEW:**
- `scripts/validate-pr.sh` — single-command runner.
- `scripts/check-validation.sh` — verifier (advisory in Stage 1).
- `docs/feature-requests/issue-498-aggressive-plan-stage2-2026-04-29.md` — archived Stage 2 design.

**Files REWORKED (kept, but logic changed):**
- `scripts/attest.sh` — writes into `.validation/runs/<shortsha>/<step>.json` instead of the bare append-only events log. Binds to current HEAD SHA. The events.jsonl can stay as a low-signal append-only history if desired, but the run dirs are the real evidence.

**Memory NEW:**
- `feedback_uat_phase3_required.md` — Phase 3 sequence is mandatory, not optional. References this PR.
- `feedback_aggressive_plan_escalation_trigger.md` — trigger conditions + pointer to Stage 2 archive.

## 4. **MANDATORY** Contract deltas

| Type | Delta | Semantics | Invariants |
|---|---|---|---|
| `.needs-uat` marker concept | REMOVED | No more per-edit gating. The marker file convention disappears entirely. | No PR going forward should reference `.needs-uat`; new sessions inherit the new framework. |
| `.validation/runs/<id>/` directory convention | NEW | Per-PR evidence directory, tied to current HEAD SHA. | Each run dir has `run.json` with SHA matching `git rev-parse HEAD` at write time. |
| Lane-aware Phase 3 obligations | NEW | Each lane has a defined obligations matrix in `validation-discipline.md §11`. | Plan declaration must match detected lane; mismatch is a discipline failure but Stage 1 doesn't block — Codex grounded review catches it as part of plan fact-check. |
| Smoke vs Live UAT vs Merge-ready terminology | NEW | Three distinct concepts with sharp definitions. | Future plans use these terms precisely; conflating smoke with UAT is an explicit anti-pattern called out. |
| `validate-pr.sh` | NEW script | Single command runs Phase 3 + writes run dir. | Replaces ad-hoc "remember six things" mental checklist. |
| `check-validation.sh` | NEW script | Reads run dir, asserts completeness for declared lane. | Advisory in Stage 1 (prints + exit code). Stage 2 wires it into a PreToolUse `git push` hook. |
| `attest.sh` | REWORKED | Writes into `.validation/runs/<id>/<step>.json` instead of bare events log. | Each attest event includes HEAD SHA + bundle path + lane. |

**Legacy data compatibility.** No persisted state. The `.needs-uat` marker file is a working-tree artifact; deleting the convention has no migration cost. The `.validation/events.jsonl` log can stay as low-signal history; nothing reads it after Stage 1. The new run dirs are forward-only.

## 5. **MANDATORY** E2E state & lifecycle audit

| Path | Behavior under this change |
|---|---|
| Live / new code change | Author writes plan with lane + UAT spec → reviews via council/grounded → builds → runs `validate-pr.sh` → run dir written with lane-specific artifacts → push (gate is informational in Stage 1). |
| Existing in-flight worktree (other concurrent session) | Stale `.needs-uat` markers in old worktrees are harmless — the hook that consumed them is gone. Cleanup is `rm -f .needs-uat` per worktree, no urgency. |
| Mid-session lane change | Author edits more files; `validate-pr.sh` re-detects lanes from `git diff` and validates against the latest plan. Mismatch → warning, not block. |
| Stage 2 escalation | Founder says "escalate." Single change to `.claude/settings.json` adds the PreToolUse hook on `git push` calling `check-validation.sh`. ~5 min, no infrastructure rework. |
| Tooling-script edits | `validate-pr.sh` and `check-validation.sh` themselves count as Docs-only (dev tooling, not shipped product). Future edits go through the framework's own Docs lane. |

**Upstream sources.** Only one: a future PR's author (me) running `validate-pr.sh` before push.

**UI side effects.** None — Stage 1 is dev-side only.

**Persistence.** `.validation/runs/` is gitignored (will add to `.gitignore`); each session writes its own run dirs. Cleanup is manual or driven by a periodic prune script (out of scope here).

**App-kill scenario.** N/A — no app changes in this PR.

**Concurrency guard.** None needed; one author per worktree, run dirs are timestamp-named.

## 6. **MANDATORY** Downstream consumer matrix

| Contract delta | Consumer | Current behavior | Required behavior | Code change? | Verified by |
|---|---|---|---|---|---|
| `.needs-uat` removed | Sessions / hook system | Hooks fire, markers exist | Hooks gone, markers don't exist | Yes (delete) | Grep `.needs-uat` returns empty in `.claude/scripts/`, `scripts/`, `.claude/settings.json` |
| Plan template lane question | Future plan authors (me) | TEMPLATE.md has no lane field | Preface includes lane question + §11 has Live UAT spec | Yes | Visual + Codex prose review |
| `validate-pr.sh` | Phase 3 author (me) | No single-command path | Phase 3 = `bash scripts/validate-pr.sh` | Yes (new) | Script runs end-to-end on this PR itself (Docs lane) and produces run dir |
| `check-validation.sh` | `validate-pr.sh` + future Stage 2 hook | n/a (didn't exist) | Reads run dir, exits with status | Yes (new) | Run on this PR's own run dir, exits 0 |
| `attest.sh` reworked | Phase 3 author + `validate-pr.sh` orchestrator | Wrote to bare events log | Writes into run dir | Yes (edit) | New attest events appear under `.validation/runs/...` not bare `.validation/events.jsonl` |
| Per-lane obligations table | Future plan authors | `validation-discipline.md §11` has tier-cumulative-checks | Has per-lane obligations | Yes | Visual + Codex prose |
| `workflow-process.md §1` step 9 | Future plan authors | Vague "Codex code-diff multiple rounds" | Explicit Phase 3 6-step sequence | Yes | Visual + Codex prose |
| Memory: `feedback_uat_phase3_required.md` | Future sessions (auto-load) | n/a | Auto-loads in MEMORY.md | Yes | New entry in MEMORY.md index |
| Memory: `feedback_aggressive_plan_escalation_trigger.md` | Future sessions (auto-load) | n/a | Auto-loads | Yes | New entry in MEMORY.md index |

**Discovery method.** Grep commands run 2026-04-29 in main tree:

```
grep -rln "needs-uat\|.needs-uat" .claude/scripts/ scripts/ .claude/settings.json
grep -nE "uat|UAT" .claude/settings.json
ls -la .claude/scripts/*uat* scripts/*uat*
```

The matrix above lists every result. No other surfaces touch `.needs-uat`.

## 7. **MANDATORY** Failure-mode × caller table

| Failure mode | Origin | Caller | Expected UX | Expected persisted state | Expected metadata stamp | Expected retry |
|---|---|---|---|---|---|---|
| `validate-pr.sh` skipped entirely | Author bypasses script | n/a | No run dir for current HEAD; check-validation.sh would warn if run; Stage 2 would block | None | None | Author runs `validate-pr.sh` and pushes |
| Run dir exists but artifacts missing | `validate-pr.sh` early-exit on a Phase 3 step failure | `check-validation.sh` | Prints FAIL + missing artifact list; advisory in Stage 1, blocks in Stage 2 | None | None | Author re-runs `validate-pr.sh` to completion |
| `live-uat.json` `expected_token` not in `observed_transcript` | Real Live UAT failure (wispr-eyes recipe ran but feature broke) | `check-validation.sh` | Prints FAIL with the mismatch | run.json shows the failure | None | Author fixes the bug, re-runs |
| Lane mismatch — plan says X, detected says Y | Mid-PR drift; plan didn't update | `validate-pr.sh` (or grounded review) | Prints WARN + advises updating plan | None | None | Author updates plan and re-runs |
| Mixed-PR not flagged in plan | Author missed splitting | Codex grounded review | Caught in plan fact-check; verdict PROCEED-WITH-REVISIONS or PIVOT | None | None | Plan is updated to declare mixed + per-lane obligations or split into multiple PRs |
| `.validation/runs/` not cleaned up | Author accumulates stale runs | n/a (cosmetic) | Disk usage grows | None | None | Periodic prune script (out of scope; manual `rm -rf` works) |

No failure mode introduces a user-visible error in the EnviousWispr app. All failures are dev-side surface only.

## 8. **MANDATORY** Caller-visible signals audit

Touched fields:

- `.validation/runs/<id>/run.json` (NEW): timestamp + SHA + lane + obligations satisfied. Read by `check-validation.sh`. NOT read by app, NOT persisted past session.
- `.validation/runs/<id>/<step>.json` per step (NEW): step-specific evidence. Same scope.
- `docs/feature-requests/TEMPLATE.md` Preface lane field (NEW): read by future plan authors + grounded-review reviewer. Not read by app or anything else.
- Workflow-process / validation-discipline rule edits: read by future sessions auto-loading the rules.

**Verification.** Grep for read sites of newly added artifacts:

```
grep -rn "validation/runs\|run.json" Sources/ Tests/
```

Pre-Stage-1: empty. Post-Stage-1: empty (no app code touches it).

No implicit signals introduced.

## 9. **MANDATORY** Fallback source-of-truth audit

No fallback branches in this change.

- `validate-pr.sh` either runs to completion or exits early with an explicit failure step. No fallback path that masks a failure.
- `check-validation.sh` either passes or fails — no "soft pass" that pretends success.
- The Stage 1 advisory mode is documented behavior, not a fallback. The verifier still emits PASS / WARN / FAIL clearly; "I ignored the WARN" is a discipline failure that Stage 2 escalation closes.

## 10. File-by-file changes

Split into THREE buckets per the actual `.gitignore` reality:

### 10.A Tracked — ships in the PR diff

| File | One-sentence change |
|---|---|
| `scripts/clear-uat.sh` (DELETE) | Manual marker remover removed. Currently allowlisted at `.gitignore:113`; allowlist line also removed. |
| `scripts/validate-pr.sh` (NEW) | Single-command Phase 3 runner. Reads declared lane from plan or detects from `git diff`. Walks 6-step sequence. Writes run dir. Supports `--self-test`. |
| `scripts/check-validation.sh` (NEW) | Reads `.validation/runs/<id>/`, asserts schema + SHA + lane-required artifacts. Prints PASS/WARN/FAIL. Advisory in Stage 1; supports `--self-test` and `--strict`. |
| `scripts/attest.sh` (REWORK) | Writes into `.validation/runs/<id>/<step>.json` instead of bare events log. Binds to current HEAD SHA + bundle path. Existing `.validation/events.jsonl` retained as cross-PR breadcrumb (low signal). |
| `scripts/test-validation.sh` (EDIT) | Add `validate-pr.sh` and `check-validation.sh` to ShellCheck targets at `:39` and add `--self-test` invocations to the Bats/script-test list. |
| `.gitignore` (EDIT) | Lines 112-115 area: drop `!scripts/clear-uat.sh`; add `!scripts/validate-pr.sh` and `!scripts/check-validation.sh`. `.validation/` stays ignored at line 47 — no addition needed. |

**Tracked total: 6 file changes.** This is the entire PR diff visible on GitHub.

### 10.B Local update-in-place — gitignored, edited in main tree only

| File | One-sentence change |
|---|---|
| `.claude/scripts/mark-uat-and-tier.sh` (DELETE) | PostToolUse Edit/Write hook removed. `.needs-uat` marker no longer created. |
| `.claude/scripts/uat-todowrite-gate.sh` (DELETE) | PreToolUse TodoWrite/TaskUpdate gate removed. |
| `.claude/scripts/command-safety.sh` (EDIT) | Branch 4 (`.needs-uat` manual-removal block) deleted. |
| `.claude/scripts/protected-files-hook.sh` (EDIT) | Line 14 regex strips `.needs-uat`. |
| `.claude/scripts/session-end-check.sh` (EDIT) | Lines 65-66 stale-marker warning replaced with: warn if `.validation/runs/` has no entry for current HEAD SHA. |
| `.claude/settings.json` (EDIT) | Remove hook entries at lines 57 (mark-uat-and-tier) + 133 (uat-todowrite-gate). |
| `.claude/rules/workflow-process.md` (EDIT, §1 step 9) | Replace vague "Codex code-diff multiple rounds" with explicit 6-step Phase 3 sequence + sharp terminology defs (Smoke / Live UAT / Merge-ready). |
| `.claude/rules/validation-discipline.md` (EDIT, §11) | Replace tier-cumulative-checks with per-lane obligations table from §3.2. |
| `docs/feature-requests/TEMPLATE.md` (EDIT) | Preface gets lane question + Live UAT Y/N + plain-English UAT description. §11 Testing gets Live UAT subsection with: subsystem, driver, input sentence, expected token, preconditions, core acceptance, feature acceptance, evidence path. |
| `~/.claude/projects/.../memory/feedback_uat_phase3_required.md` (NEW) | Phase 3 sequence is mandatory; references this PR. |
| `~/.claude/projects/.../memory/feedback_aggressive_plan_escalation_trigger.md` (NEW) | Trigger conditions + decision rule (skip-note OR escalate) + pointer to archive. |
| `~/.claude/projects/.../memory/MEMORY.md` (EDIT) | Index entries for both new memories. |

**Local-only total: 12 changes.** All update-in-place, none ship in the PR diff. Established convention from Phase D PR #497 + earlier phases.

### 10.C Force-added (force-tracked despite gitignore)

| File | One-sentence change | Why force-add |
|---|---|---|
| `docs/feature-requests/issue-498-2026-04-29-uat-restructure-stage1.md` (NEW) | This plan file. | Force-add so the GitHub PR description can link to it for reviewers; consistent with the Bible (`docs/feature-requests/issue-319-...md`) being force-tracked. |
| `docs/feature-requests/issue-498-aggressive-plan-stage2-2026-04-29.md` (NEW) | Archived Stage 2 design. | Force-add so future-me reading this PR's history finds the escalation path immediately. |

**Force-added total: 2 files.** Use `git add -f docs/feature-requests/issue-498-*.md` per the Phase D pattern.

### Grand total
- Tracked (PR diff): 6 file changes
- Local-only: 12 changes
- Force-added: 2 files
- Total surfaces touched: 20

## 11. Testing

### 11.1 Codex prose review (Docs-only lane obligation)

Codex grounded review reads the plan + the actual rule edits + the new scripts; verifies:
- Rule files compile (no syntax errors in Markdown / shell).
- Cross-references between `workflow-process.md` and `validation-discipline.md` are consistent.
- The lane definitions match the file globs Phase 3 obligations reference.
- Memory files are well-formed (frontmatter + body) and MEMORY.md index entries match.

### 11.2 Grep-for-broken-refs (Docs-only lane obligation)

After all edits land:
- `grep -rn "needs-uat\|.needs-uat" .claude/scripts/ scripts/ .claude/settings.json` returns empty.
- `grep -rn "validate-pr.sh\|check-validation.sh" .claude/rules/` confirms script names appear correctly.
- `grep -nE "Live UAT|Merge-ready|Smoke" .claude/rules/workflow-process.md` confirms terminology defs are present.

### 11.3 Run dir produced for this PR's own validation

This PR is the first dogfood of the new framework. After all edits land:
1. Run `bash scripts/validate-pr.sh` against this branch.
2. Confirm `.validation/runs/<timestamp>-<shortsha>/run.json` exists with SHA matching `git rev-parse HEAD`.
3. Confirm Docs-only lane artifacts present: `codex-prose.txt` (the Codex grounded review output) + `broken-refs-grep.txt` (the grep checks above).
4. Run `bash scripts/check-validation.sh .validation/runs/<id>/` — must exit 0 with PASS.

### 11.4 No Live UAT (Docs-only)

Per §0 declaration: this PR is Docs-only, no app surface, Live UAT N/A.

### 11.5 No Code-lane changes — no Sources/, no synthetic dictation

Confirmed by `git diff --name-only origin/main` returning zero `Sources/`, `Tests/`, `Package.swift` paths.

## 12. Blast radius & rollback

**Touched modules:** `.claude/`, `docs/`, `scripts/`. Zero `Sources/`, `Tests/`, `Package.swift`, `website/`, `workers/`, `.github/`.

**NOT touched:** All product code. All app behavior. All website behavior. All worker behavior. All eval-harness Python.

**Rollback.** Single-commit revert restores `.needs-uat` hooks + script + bare events log. Memory entries reverse via `git revert`. Plan template + rule edits reverse cleanly. New scripts deletable. `.validation/runs/` directories are local-only, no impact.

If Stage 2 is later deployed and proves wrong, revert path is the same: `git revert` of the Stage 2 commit, with Stage 1 unchanged underneath.

## 13. Ship criteria

- [ ] All `.needs-uat` references removed from `.claude/scripts/`, `scripts/`, `.claude/settings.json` (verified via `grep -rn "needs-uat\|.needs-uat"` returns empty across those paths).
- [ ] `scripts/validate-pr.sh` and `scripts/check-validation.sh` exist, are executable, and pass `--self-test` mode (exit 0).
- [ ] ShellCheck passes on `validate-pr.sh`, `check-validation.sh`, and reworked `attest.sh` — verified via `scripts/test-validation.sh` (existing aggregator, updated to include new scripts).
- [ ] `attest.sh` writes into `.validation/runs/<id>/<step>.json` instead of bare events log; binds to current HEAD SHA + bundle path (verified by reading the script + running once).
- [ ] `.claude/rules/workflow-process.md §1` step 9 has the 6-step Phase 3 sequence + sharp terminology defs.
- [ ] `.claude/rules/validation-discipline.md §11` has the per-lane obligations table.
- [ ] `docs/feature-requests/TEMPLATE.md` has lane question + UAT Y/N + plain-English description in Preface, and Live UAT subsection in §11 with all required fields (subsystem, driver, input sentence, expected token, preconditions, core acceptance, feature acceptance, evidence path).
- [ ] Stage 2 archive doc exists with the explicit `.claude/settings.json` escalation diff + the narrowed fail-closed core + the `UAT_BYPASS_REASON` escape hatch + the skip-note decision rule.
- [ ] Two memory files saved + MEMORY.md index updated.
- [ ] Codex grounded review on plan + Codex code-diff review on the actual edits both clean.
- [ ] `.validation/runs/<this-PR-shortsha>/` populated with Docs/dev-tooling artifacts: `codex-prose.txt`, `broken-refs-grep.txt`, `shellcheck.txt`, `self-test.txt`.
- [ ] `run.json` validates against the schema in §3.3 (schema_version: 1, head_sha matches `git rev-parse HEAD`, declared_lane="Docs/dev-tooling", detected_lanes matches, started_at + completed_at populated).
- [ ] Zero em-dashes / en-dashes in new code or human-facing rules.
- [ ] Push hook accepts the push (build-freshness check applies; no Sources/ here so nothing to rebuild).
- [ ] PR description **names the run dir path** + the Stage 1 / Stage 2 commitment language + the probationary framing.

## 14. Open questions

For council:

1. **Is the Stage 1 / Stage 2 split structurally sound?** GPT round 2 argued for full enforcement; founder said hard hooks at PR boundary are out (virtual PR cycle time); this plan splits enforcement infrastructure (now) from enforcement gates (later). Is the split clean, or am I building infrastructure that won't get used?

2. **Is `validate-pr.sh` walking Phase 3 the right unit of execution, or should it be N smaller scripts (`smoke.sh`, `live-uat.sh`, etc.) with `validate-pr.sh` as the orchestrator?** The orchestrator pattern is more composable; the single-script pattern is harder to forget pieces of. My lean: single script that calls into smaller named functions internally. Composable for future, single entry point for me.

3. **The `.validation/events.jsonl` low-signal append-only log — keep it as a session-history breadcrumb, or delete entirely once run dirs are the canonical evidence?** My lean: keep it for cross-PR trend visibility (e.g., "how many PRs this month skipped Live UAT") but stop writing to it as the primary attest target. Future PRs append summary events to it FROM the run dir.

4. **The "lane auto-detection" logic in `validate-pr.sh` — Stage 1 has it but uses it advisory only. Does Stage 1's auto-detection logic belong in the same script as Stage 2's blocking version, or separate?** My lean: same script, with a `--strict` flag that Stage 2 turns on. Stage 1 runs without `--strict`.

5. **Aggressive Stage 2 archive doc — should it live in `docs/feature-requests/` (where it can be grep'd by future sessions) or in `docs/audits/` (where archived research goes)?** My lean: `docs/feature-requests/` so it's findable by issue-number lookup; the SHELVED status is in the file's status header.

## 15. Related

- Bible: `docs/feature-requests/issue-319-2026-04-18-q2-hardening-epic.md` (parent epic).
- Decisions: workflow-process.md §1 (the 10-step shape codified during Phase D).
- Predecessor: PR #497 (Phase D shipped — exposed the 60-time UAT-bypass pattern).
- Memory: `feedback_uat_gate_is_load_bearing.md` (created earlier this session, summarizes the bypass pattern).
- Memory: `feedback_real_pain_gate.md` (don't fix theoretical problems — but the 60-time pattern earns this).
- Memory: `feedback_codex_cli_hygiene.md` (default `codex exec` to `</dev/null`).
- Memory: `feedback_communication_style.md` (subagent → main verbatim; main → user plain English digest).
- Council outputs (verbatim, ephemeral): GPT round 1 + round 2 saved to `/tmp/uat-restructure-498/{r1,r2}.md` for grounded review. Not committed.

---

## Checklist for the plan author

- [x] Sections 4-9 are filled, not blank.
- [x] Every new error case has a row in the failure-mode table.
- [x] Every new artifact has a row in the signals audit.
- [x] Every fallback branch has a defined source-of-truth (zero fallback branches).
- [x] File-by-file changes reference actual file paths verified in worktree 2026-04-29.
- [x] Testing section names actual run-dir artifacts and grep commands.
- [x] Lane declared (Docs-only) and matches detected paths.
- [x] Live UAT N/A justified explicitly.
- [x] Stage 1 / Stage 2 commitment language present.
- [x] Stage 2 escalation path documented (5-min `.claude/settings.json` change).
