# Cloud model routine, Stage 2 (#4353 PR 5)

Stage 1 is `.github/workflows/cloud-models-sweep.yml`. Each week it tests new OpenAI, Claude and Gemini models through the shipped app connectors and opens one list-only PR, from the routine's GitHub App, with the rows that passed. Stage 2 is a separate Claude Code cloud routine (Sonnet 5.5). It checks that PR against the run's own evidence, merges it when every gate passes and keeps one durable record per Stage 1 run. This is not a Worker; nothing here is deployed with `wrangler`.

| Piece | Where |
|---|---|
| Stage 2 instructions (reference copy) | `routine-prompt.md` |
| Stage 1 workflow | `.github/workflows/cloud-models-sweep.yml` |
| Run, evidence and PR checks | `scripts/cloud-models/workflow.py` (`check-pr`) |
| The only owner of permitted list changes | `scripts/cloud-models/propose.py` |
| List validator | `scripts/cloud-models/validate-list.py` |
| Trust boundaries, artifacts, App identity | `scripts/cloud-models/README.md` |

The routine only adds rows for new models. It never hides, un-hides or edits a row (founder decision 14): each user's menu comes from their own key, so a retired model leaves it by itself.

## Status: ACTIVATION IN PROGRESS

The activation values below are set. The routine is enabled only after every item in "Activation checklist" passes with read-back evidence. The evidence and the current state live in the operations note `.claude/knowledge/cloud-model-routine.md` (main checkout), not in this file.

- **Verified in the repository:** the Stage 1 workflow, `workflow.py` (including `verify-run`), `propose.py` and their offline tests (`workflow.py --self-test`, `propose.py --self-test`).
- **Proven by the live activation runs:** the environment, the read, write and merge routes and the commit message ("Write, read and merge routes").
- **Not yet proven live:** the rehearsal, the scheduled routine and serialization ("Activation checklist" items 5 to 7).

## Activation values

| Name | Value |
|---|---|
| `RUN_LOG_ISSUE` | `4384` |
| `WRITER_LOGIN` | `saurabhav88` (the cloud session's own GitHub access acts as this account) |
| `APP_BOT` (`CLOUD_MODEL_ROUTINE_APP_BOT`) | `envious-cloud-model-routine[bot]` (Stage 1 publisher App, App ID `5620010`) |
| `ACTIVATION_DAY` | `2026-11-05` |

The publisher App opens routine PRs from Stage 1 and never merges. Stage 2 acts as the founder's account, the same way the TIK/TOK and Ollama routines do. That does not widen what it may merge: only a PR authored by `APP_BOT` that passes every gate.

## Merge authorization (narrow)

Founder decision 6 (2026-11-04): a Claude session merges these PRs ("A. Claude merges"). This authorizes this one separate Stage 2 session to merge one kind of PR: an automated, list-only PR opened by the routine's App that passes every gate in `routine-prompt.md`. It is not a general merge permission for cloud sessions. The cloud preamble's default ("leave the merge for a Mac session") still governs every other PR, including the founder's engineering PRs.

Founder decision 2026-11-05 (#4353 plan, "Stage 2 redesign"): routine PRs need no Codex review and no Mac clearance, like the Ollama routine's feed PRs (#2778). The gate is the authenticated evidence (`verify-run`), the permitted exact list bytes (`check-pr`), the validator and `build-check`, all on the current head. A separate Stage 2 App, an isolated identity and footer-free comments were tried and dropped: a Claude cloud session always carries the founder's GitHub tools and token (activation proof, 2026-11-05).

## Environment

The routine runs in the claude.ai cloud environment `cloud model stage2`. Do not use `enviouswispr general` (`.claude/knowledge/cloud-environment.md`): its service account reads every secret in the business vault.
- No provider keys, no GCP credentials, no `get-key` access and no setup script.
- Network access is limited to `api.github.com`, `github.com` and `*.blob.core.windows.net` (artifact downloads).
- Its GitHub access is the cloud session's own (the founder's account): the GitHub tools for writes, and `gh api` with the session's token for reads, as "Write, read and merge routes" records.
- It runs on Ubuntu, with no Xcode and no local Codex CLI. Stage 2 never uses `gh pr` or `gh issue`.

## Durable records (one run-log issue, one comment per run)

**The issue:** a dedicated issue, `Cloud model routine run log`, created at activation. Its number is an activation value, recorded here as `RUN_LOG_ISSUE`. A cloud VM file or the conversation is never the record.

**Identity:** the logical identity of a record is the repository plus the Stage 1 workflow run ID. A record holds every attempt of that run; a rerun never creates a second record. Each attempt keeps its own evidence summary, and a newer attempt is evaluated on its own. Newer evidence is never applied to an older attempt's PR; the PR branch names its attempt.

**The comment:** each run has exactly one comment on the issue, written as `WRITER_LOGIN`. Only that account's comments count, and only a comment with the run's state block is its record. Lookups read every page. The comment body has exactly these two parts, plus the GitHub tool's footer (`---` then `_Generated by [Claude Code](https://claude.ai/code)_`) once below them, which the digest accepts:

1. The digest's receipt line (D7, exact fields and enumerations):

   ```text
   cloud-routine-run date=2026-11-09 run=101 providers=3 candidates=2 added=1 failed=1 outcome=partial result=merged
   cloud-routine-run date=2026-11-16 run=102 providers=3 candidates=0 added=0 failed=0 outcome=failure result=none
   ```

2. One hidden state block, `<!-- cloud-routine-record {...} -->`, holding the JSON record. Example (a real record has real values):

   ```json
   {"schema": 1, "repository": "saurabhav88/EnviousWispr", "runID": "101", "runDate": "2026-11-09", "runLogCommentID": 3400000001, "state": "merged", "attempts": [{"attempt": "1", "artifact": "cloud-model-routine-evidence-101-1", "sourceSHA": "0123456789abcdef0123456789abcdef01234567", "receiptSHA256": "9f2c0d1e4b5a69788796a5b4c3d2e1f00112233445566778899aabbccddeeff0", "completedAt": "2026-11-09T07:44:10Z", "firstPendingAt": "2026-11-09T07:50:12Z", "runOutcome": "partial", "evidenceOutcome": "partial", "candidates": 2, "added": 1, "failed": 1}], "pr": {"attempt": "1", "number": 4400, "url": "https://github.com/saurabhav88/EnviousWispr/pull/4400", "head": "89abcdef0123456789abcdef0123456789abcdef"}, "merge": {"state": "merging", "head": "89abcdef0123456789abcdef0123456789abcdef", "base": "76543210fedcba9876543210fedcba9876543210"}, "mergedSHA": "fedcba9876543210fedcba9876543210fedcba98"}
   ```

**Field meanings:**
- `date` and `runDate`: the UTC day of the Stage 1 run's own `created_at`. It is never the day Stage 2 processed or edited the record. GitHub keeps the comment's own `created_at` when the comment is edited, so updates in place do not refresh the digest's freshness clock.
- `providers`: the three configured providers, always `3`, including runs that failed before a receipt (D7's line format).
- `candidates`: new models the authenticated receipt tested, counted across providers. `0` when no usable receipt exists.
- `added`: rows the evidenced proposal adds. This is a proposal fact. It does not mean the rows are on main. `0` without usable evidence.
- `failed`: candidates whose outcome is `fail` or `notTried`. `0` without usable evidence.
- `outcome`: the run's own outcome, `verify-run`'s `runOutcome` (`success`, `partial`, `failure`, `nochange`). It is the evidence outcome from `result.json` when the run and its publish job succeeded. It is `failure` when any of these happened, even if the measurement found nothing to change or rows that passed: the run failed, the publish job did not succeed, or the run has no usable evidence (it failed before its receipt, or its artifact is missing). The record keeps the measured counts and the evidence outcome (`receipt.outcome`) separately in its attempt entry.
- `result`:
  - `merged`: the PR merged, and the merged list bytes were verified on main.
  - `review-blocked`: a gate refused the PR, or a step needs a person.
  - `none`: there is no PR, or the PR is still pending.
- `state`: `pending`, `review-blocked`, `merged` or `terminal` (no PR and nothing more to do for its newest attempt). The digest reads the receipt line. A pending run shows `result=none`, and `state` says pending. A temporary GitHub read or download failure keeps a run `pending`; only confirmed missing or failed evidence makes it `terminal`. Each attempt entry has its own `firstPendingAt`, set once when that attempt first becomes pending and never changed afterwards. An attempt's 7-day deadline starts at its own `completedAt`, or else at its own `firstPendingAt`. A newer attempt never inherits an older attempt's deadline and never resets an older attempt's evidence.

**Recovery:** before every write, Stage 2 re-reads the issue's comments, all pages. A write that succeeded while the session stopped before reading the reply is found on the next invocation by its marker and is reused. A second comment is never created for the same run ID. Stage 2 creates or recovers the pending record before the merge call. Before the merge call it saves the intent (PR, exact head and base) and reads it back. After the call, it reconciles GitHub's state and saves what came back. Recovery uses only the saved intent, never a head guessed from timestamps. Stage 2 recovers a PR that already merged instead of merging it again. Every pending state has a deadline: after it, the run becomes `review-blocked` with a reason.

**One invocation at a time:** reading before creating does not stop two overlapping sessions from both creating a comment. Stage 2 invocations must be serialized, and that is an activation prerequisite (checklist item 8).

**Other issues stay where they are:** candidate failures (`Cloud model routine: <provider>/<id> failed`), the call-recipe issue and `Cloud model routine: run failed` belong to Stage 1 (`workflow.py`). Stage 2 links to them and never recreates them.

## Write, read and merge routes

- **Write:** the cloud session's GitHub tools, `add_issue_comment` and `update_issue_comment`, on the run-log issue only. Stage 2 sends the receipt line and the state block without a footer; the tool appends its footer once. An update sends the whole new body, again without a footer.
- **Read:** `gh api` with the cloud session's own GitHub token. `verify-run` and `check-pr` use the same token (`GH_TOKEN`).
- **Merge:** the GitHub tool `merge_pull_request` with `owner` `saurabhav88`, `repo` `EnviousWispr`, `pullNumber`, `merge_method` `squash`, `commit_title` = the PR title, `commit_message` exactly `Part of #4353.` and `expectedHeadSha` = the saved head. A call without `expectedHeadSha` is never used, and neither is a call that skips a required check or a branch rule. Founder approval for a head-locked merge of an already-clean PR: 2026-11-05, the #4353 plan, "Merge route amendment".

Proven in the cloud (activation run 3, session `cse_018PEvKK1gHsLY4GBHU5GU6N`, 2026-11-05):
- `merge_pull_request` with an all-zero `expectedHeadSha` was refused with `409 Head branch was modified. Review and try the merge again.`, and PR #4401 stayed open with the same head.
- The real call merged #4401 as `8cf2d985977881916257935eb8df18fcb3187e38`. Its commit message read back as the PR title, a blank line and `Part of #4353.`, with no footer and no trailer.
- `gh api` reads as `saurabhav88`. The session's GitHub proxy refuses GraphQL and numeric `repositories/{id}/...` paths, so Stage 2 uses `repos/{owner}/{repo}/...` REST paths only.
- `verify-run` downloads run artifacts, which redirect to `*.blob.core.windows.net`; the environment allows that host.
- The GitHub tools wrote and updated the run-log records on #4384 as `saurabhav88`, with the footer once and `created_at` unchanged.

## Run verification (`workflow.py verify-run`)

`workflow.py verify-run --run ID --attempt N --trusted DIR --work DIR` classifies one completed Stage 1 run from GitHub's own facts and the run's own evidence. It sends GET requests only, and it writes only under `--work`.

**How it works:**
- It authenticates the run's metadata first, separately from whether the sweep succeeded. So a failed run is classified without pretending it passed.
- For usable evidence, it rebuilds the context from the authenticated metadata and regenerates the permitted proposal in scratch space with `propose.py`. Then it compares the result, list and PR-body bytes with the artifact.
- The recorded source commit is resolved in the trusted checkout. A main that has moved on does not invalidate a run measured earlier.
- It never compares a proposed list with the unchanged base. Current PR and base compatibility stays `check-pr`'s job.

**Credentials:** `GH_TOKEN` must be a token with repository read access (actions and contents). `DIR` for `--trusted` is a checkout of main with full history.

**Output:** a JSON object (schema 1), on stdout and in `<work>/verify-run.json`. It holds:
- `status` and `reason`
- `run`: id, attempt, source SHA, event, `createdAt` (the run's creation), `completedAt` (when this attempt's last job finished, or `null` when GitHub does not report it for every job), run status and conclusion, and the `sweep` and `publish` job conclusions
- `evidence`: artifact, receipt hash, list hash and `proposal`
- `receipt`: `providers`, `candidates`, `added`, `failed` and `outcome` (the evidence outcome)
- `runOutcome`: the outcome for the run-log receipt (see "Field meanings"); `null` when the result is `temporary` or `refused`
- `measured`: whether the counts come from authenticated measurement evidence

Fields that are not available are `null`. The output never carries GitHub response bodies, error text, tokens or artifact contents.

| `status` | Exit | `reason` values | Stage 2 does |
|---|---|---|---|
| `verified` | 0 | `evidence-verified` | Use `receipt`, `runOutcome` and `evidence.proposal`. If `run.publish` is not `success`, record `review-blocked`, reason `publication-failed`. A failed publish job does not prove no PR exists, because the PR may have been created before a reply was lost. So Stage 2 still looks up the attempt's App PR in every state and records it, but never merges through this path. |
| `failure` | 10 | `sweep-failure`, `sweep-cancelled`, `sweep-timed_out`, `sweep-skipped`, `artifact-missing`, `artifact-expired` | Record `providers=3 candidates=0 added=0 failed=0 outcome=failure result=none`, `state: terminal` (`measured: false`). |
| `temporary` | 75 | `github-unavailable`, `github-malformed`, `run-incomplete` | Stay `pending`, with the 7-day deadline. |
| `refused` | 1 | `not-a-routine-run`, `evidence-invalid`, `evidence-mismatch`, `bad-arguments` | Record `review-blocked` with the reason. Never treat it as no-change. |

A complete, well-formed artifact listing with no match confirms `artifact-missing`. An unreadable item in any reply is `github-malformed`, never absence. A timeout, a rate limit, a server error, an ambiguous 403 or 404, or a list that does not add up to its stated total is `temporary`, never confirmed missing.

## Activation checklist (Stage 2)

All of these must hold before the first scheduled Stage 2 run. Each needs read-back evidence. The Stage 1 items are in `scripts/cloud-models/README.md`.

1. The environment `cloud model stage2` exists, with no provider keys, no GCP credentials, no vault access and no setup script.
2. `RUN_LOG_ISSUE`, `WRITER_LOGIN`, `APP_BOT` and `ACTIVATION_DAY` are recorded here.
3. The routes are proven in the cloud: the GitHub tool schemas read, the read token's identity, a run-log record created and updated (author, footer once, body and unchanged `created_at` read back), a wrong-head refusal from the chosen merge call, and one real head-locked merge with its commit title and message read back.
4. `workflow.py verify-run` runs in the Stage 2 environment against one real completed run, and its output is read back.
5. A rehearsal walks through creating the record, an interrupted rerun (the record is reused) and a head change (the new head is checked again).
6. The schedule is set to run after Stage 1, for example Mondays 09:00 UTC, plus one later weekly run to revisit pending records. This is an activation value.
7. Serialization is proven: two Stage 2 invocations can never run at once. For example, one routine with schedules far enough apart that a run finishes first, plus the proof that a manual run waits or is refused while one is active.

## Changing the instructions

Edit `routine-prompt.md`, then paste it (without the leading comment block) into the routine's Instructions box and compare the saved text with this file.
