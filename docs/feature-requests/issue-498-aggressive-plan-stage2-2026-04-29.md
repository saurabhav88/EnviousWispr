# Issue #498 — Aggressive UAT enforcement, Stage 2 — SHELVED 2026-04-29

User Rubric: N/A — workflow archive doc, internal-only (epic #319 Hardening), no user-visible surface.

**Status:** SHELVED. Ready to deploy when Stage 1 fails.
**Trigger conditions:** see §3 below.
**Implementation cost from shelved-state:** ~5 minutes (a `.claude/settings.json` diff plus optionally a session-end hook update). Infrastructure already exists in Stage 1.

---

## 1. Why this exists separately from Stage 1

Stage 1 builds the discipline infrastructure (run directories, lane-aware obligations, `validate-pr.sh`, `check-validation.sh`) but ships them as advisory tools. Author runs them, prints WARN/FAIL, no mechanical block. Trust-based.

The data says I (Claude) have failed UAT discipline ~60 times across this project. Trust-based is wrong-sized for that pattern. Stage 2 is the enforcement layer: same infrastructure, hooks at the local boundaries (push-time, never PR-time per the virtual-PR cycle constraint).

Stage 1 ships first because:
- Founder wants to give the lighter framework one honest try.
- The infrastructure is needed regardless. Stage 2 is "wire enforcement" not "redesign."
- Escalation cost is bounded — 5-minute change, not weeks.

## 2. What Stage 2 adds on top of Stage 1

**One file change.** `.claude/settings.json` adds a PreToolUse hook that intercepts `git push` calls and runs `check-validation.sh`. If the latest run dir for current HEAD SHA is incomplete or missing the lane-required artifacts, deny with a clear message. The hook's existence is the entire change.

**Concrete diff (drop into `.claude/settings.json`'s `hooks.PreToolUse` array):**

```json
{
  "matcher": "Bash",
  "hooks": [
    {
      "type": "command",
      "command": "/Users/m4pro_sv/Developer/EnviousLabs/EnviousWispr/.claude/scripts/uat-pre-push-gate.sh",
      "statusMessage": "Checking Phase 3 validation for current HEAD..."
    }
  ]
}
```

**One new tiny shell script** (~30 lines): `.claude/scripts/uat-pre-push-gate.sh`. Reads the Bash command from stdin; if it's a `git push` (not other Bash commands), calls `scripts/check-validation.sh` with `--strict --head=$(git rev-parse HEAD)`. Strict mode treats WARN as FAIL. If FAIL, the hook denies with the diagnostic.

**Optionally one session-end hook update** (already partly in place via `session-end-check.sh`): warn if any commits in this session have no run dir. Stage 1 will already have this; Stage 2 promotes warn → block at session-end.

That's it. No script rewrites. No plan template changes. No memory churn.

## 3. Trigger conditions for Stage 1 → Stage 2 escalation

Any ONE of:

1. **Bypass: a session pushes a non-trivial PR (any non-Docs lane) without writing a run dir for current HEAD.** Detection: founder grep's `.validation/runs/` or the session-log shows missing entries for shipped PRs.
2. **Smoke-equals-UAT regression: I claim "smoke = UAT" again** — treating a clean release build + clean app launch as evidence of feature correctness. Detection: founder catches it in conversation OR a shipped PR has no `live-uat.json` for a Code-lane change.
3. **Shipped regression catchable by synthetic dictation: another PR ships a build that breaks mic / overlay / paste / polish silently** the way Phase D #497 did. Detection: founder uses the merged build and finds it broken.
4. **Founder calls escalation explicitly:** "switch to Stage 2."

When any of these fire, founder says "escalate" and the implementation is the §2 diff. No relitigation, no re-design, no "let me make it lighter."

## 4. What Stage 2 does NOT do

Per founder's explicit constraint (virtual PRs take 30+ minutes per cycle):

- **No PR-boundary friction.** No PR-body comment writes, no PR creation hook, no `gh pr merge` interception, no required CI status check tied to UAT. The PR cycle stays clean.
- **No founder-gated PR merges.** The eval-harness "private corpus run" obligation stays as "PR description includes structured summary text" (see Stage 1 plan §3.2 for required fields) — visible artifact, not blocking action.

The hook is local-only: `git push`. By the time the PR exists on GitHub, validation has already been forced by the local push gate.

## 5. Scoping note — what's the "lane" Stage 2 enforces?

Stage 2 inherits Stage 1's lane definitions verbatim (see Stage 1 plan §3.2). The `--strict` flag in `check-validation.sh` is fail-closed on a NARROW core only at initial deployment. Per GPT/Codex feedback rounds 2026-04-29: blanket "WARN-as-FAIL" promotion creates bypass pressure if the verifier still has heuristic uncertainty. Better to start narrow + ratchet warnings to errors only after they prove near-zero-noise.

### 5.1 Strict mode fail-closed core (Stage 2 day-one)

These four conditions FAIL the push immediately:

1. **Missing run dir for current HEAD SHA.** `.validation/runs/<id>/run.json` doesn't exist where `run.json.head_sha == git rev-parse HEAD`.
2. **HEAD mismatch.** A run dir exists but `run.json.head_sha != git rev-parse HEAD`. Stale validation against an earlier commit doesn't count.
3. **Missing required lane artifacts.** For the declared lane, any required artifact per Stage 1 plan §3.2 is missing or empty.
4. **Undeclared mixed-lane.** `detected_lanes.length > 1` AND `is_mixed_pr=false` AND the second-lane is not Docs/dev-tooling companion. Mixed PRs that don't declare themselves block.

### 5.2 Stage 2 warnings (NOT fail-closed initially)

These print WARN and let the push through, with promotion to FAIL after warnings prove near-zero-noise (target: 30 days of clean warning corpus):

- Lane mismatch (declared ≠ detected, but neither is undeclared-mixed).
- `live-uat.json.expected_token` mismatch with `observed_transcript` (might be a legitimate intentional change).
- Skip notes present without justification text.

### 5.3 Logged escape hatch — `UAT_BYPASS_REASON`

`UAT_BYPASS_REASON="<one-line reason>" git push <args>` — the pre-push hook detects the env var, appends an event to `.validation/bypass-log.jsonl`:

```json
{"ts": "2026-...", "head_sha": "abc...", "branch": "feat/...", "reason": "<reason>"}
```

Then allows the push. Bypass usage is grep-able in retrospect; not a casual override but a sanctioned break-glass with a paper trail. In a 2-person company, an emergency push WITHOUT a logged trail (i.e., a denied-and-retried-via-discipline-bypass) creates exactly the bypass pressure this whole framework is fighting. The escape hatch is healthier than pretending none is needed.

For Docs/dev-tooling PRs, strict mode still requires a run dir with `codex-prose.txt` + `broken-refs-grep.txt`, plus when shell scripts changed: `shellcheck.txt` + `self-test.txt`.

For Mixed PRs (>1 non-docs lane detected), strict mode blocks unless the plan declares `mixed_pr: true` AND the run dir has artifacts for each detected lane. Otherwise the push is denied with "Mixed PR detected without explicit declaration; split or update plan."

## 6. Cost / benefit

**Implementation cost:** ~5 minutes (one settings.json diff, one ~30-line shell script).

**Behavioral cost:** I lose the ability to silently bypass Phase 3. Every push goes through `check-validation.sh --strict`. If I haven't run `validate-pr.sh`, the push fails with a clear "no run dir for HEAD; run scripts/validate-pr.sh first" message.

**Founder cost:** zero ongoing. The gate is autonomous. Founder only sees the gate when escalation is triggered, which is the whole point.

**Test cost per PR:** synthetic dictation via wispr-eyes is ~30 seconds. The gate's marginal cost over a non-gated push is negligible.

## 7. Provenance

- Round 1 council (GPT) on UAT design: ephemeral, ran 2026-04-29 (this session).
- Round 2 council (GPT, with full lane context): ephemeral, ran 2026-04-29.
- Founder constraint: virtual PRs take 30+ min, no PR-boundary friction.
- Founder framing: 60-time pattern earns hard enforcement at the right boundary; light-version proven insufficient by behavior.
- Stage 1 ships first: PR #498 (this), founder gives lighter framework an honest try.

## 8. Standing instruction to me — decision rule, not mantra

**If I find myself in a future session reasoning that Stage 1 is "too heavy" or that some Phase 3 step is optional for "this special case," I MUST do ONE of the following two things, no third option:**

1. **Write `skip-note.txt` to the current run dir** with one-sentence rationale for the omission, BEFORE pushing. The visible skip note makes the decision auditable in retrospect. Codex grounded review on the next plan can flag a pattern of skip notes accumulating in the same lane as evidence the framework needs adjustment.
2. **Propose Stage 2 escalation to the founder** explicitly, with a one-paragraph rationale and a pointer to which trigger condition (§3) fired.

The mantra "don't relitigate Stage 1 → lighter" is insufficient on its own — mantras can be ignored as easily as `.needs-uat` was. The decision rule above is the load-bearing version: every "this is too heavy for this case" thought MUST produce either a skip note or an escalation. No silent omissions.

Read this archive. Note the trigger conditions. If any trigger has fired in the current session or recent past, propose Stage 2 escalation to the founder. Don't relitigate Stage 1 → lighter.
