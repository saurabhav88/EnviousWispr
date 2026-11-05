# Cloud model list scripts (#4353)

The cloud model list is `website/public/cloud-models.json`, with a byte-identical bundled copy at `Sources/EnviousWispr/Resources/cloud-models.json`. The app's contract is `CloudModelList.validated(from:)` in `Sources/EnviousWisprLLM/CloudModelList.swift`.

| Script | Job |
|---|---|
| `validate-list.py` | Validates a list document against the shared fixtures in `fixtures/`, the same ones `CloudModelListTests` runs through the Swift parser. `--same A B` also requires the two copies to be byte-identical. |
| `propose.py` | The weekly routine's only owner of permitted automated list changes. It only adds rows for new models; it never hides, un-hides or edits a row (founder decision 14). `generate` writes a proposal and `check` verifies one. Both call the same permission engine. |
| `app_token.py` | Stage 2's only GitHub route. `exec -- <command>` mints a short-lived installation token for the Stage 2 App (`STAGE2_APP_ID`, `STAGE2_APP_PRIVATE_KEY`), scoped to this repository alone, and runs the command with it in `GH_TOKEN`. It never prints the token. `--self-test` runs `app_token_test.py` against a throwaway key and a fake GitHub. Usage: `workers/cloud-models-routine/README.md` "Footer-free write route". |

Engineering changes to the list (a recommendation, a request edit, a label, hiding a row) are ordinary reviewed PRs. They are outside `propose.py`'s policy. The workflow decides which PRs are routine PRs (#4353 PR 5, chunk 7).

## propose.py

```text
propose.py generate --base REV --receipt FILE --context FILE \
                    --output-root DIR --result FILE [--repo DIR]
propose.py check    --base REV --receipt FILE --context FILE \
                    --result FILE --current-root DIR --target-base REV [--repo DIR]
propose.py --self-test
```

**Inputs and trust**

- **`--receipt`:** the measurement receipt the Swift harness wrote. It is data: no field is executed, and refusal messages name fields, never values. The script refuses a receipt with a missing or contradictory field. It never fills in a default.
- **`--base`:** the recorded base, which is the commit the routine measured. It must resolve to a commit equal to the receipt's and the context's `sourceSHA`. Both list copies at that commit must be identical, valid, in the canonical two-space form, and must hash to the receipt's `list.sha256`.
- **`--context`:** what the authenticated caller (the workflow or Stage 2, which got the receipt from GitHub) states about the run. Its fields are `schema`, `repository`, `workflow`, `runID`, `runAttempt`, `event`, `ref`, `sourceSHA` and `receiptSHA256`. The script compares these with the receipt and its bytes. **A match here does not authenticate the receipt with GitHub. The caller must do that.** There is no way to skip this comparison.

**What it may change: additions only**

- **Add a row:** a new provider/id with `recommended: false` and `hidden: false`. A `pass` adds the unchanged fallback row, including after an OpenAI parameter strip. A `passViaSearch` adds the chosen setting. That requires a rejected fallback, the search menu order, one screening success and three confirmation successes without adaptation, successful replies and physical requests that carry exactly that setting. Chat eligibility and file batching must stay the fallback's for the id and its dated spellings, as the receipt's `resolution` reports them. The script does not re-derive capability or dated-id rules. Every phase (the fallback and each search attempt) must match the requests the ledger recorded for it. An earlier attempt must have ended in a way the search continues after (a rejected request, unusable output or an adaptation), and no earlier attempt may have qualified. `medianPolishMs` must be the middle of the passing phase's measured timings, or absent when that is out of range.
- **Leave everything else alone:** the script never deletes, reorders, hides or edits existing rows or fields. Each user's menu comes from their own key, so a retired model leaves it by itself. `updated` changes only with a proposal. It becomes the later of the base date and the run's UTC day.

**Outputs**

- **With changes:** `generate` writes both list copies under `--output-root`, then writes the result file last. The result holds the receipt hash, the recorded base, the instrument outcome, the final outcome, the operations and the list hash.
- **With no permitted change:** no list file is written, and the result says `proposal: false`.
- **`failure` and `partial`:** these outcomes are never upgraded. A `failure` proposes nothing.
- **Status:** `proposalStatus` is only `proposed` or `none`. Merge and publication are recorded later.

**Checking**

`check` is read-only. It recomputes the result from the same inputs and requires these to be exactly the recomputed bytes:

- the current list copies under `--current-root`
- the result file

It also requires the list at `--target-base` (the PR's current base) to be the recorded base list. A moved base with the same list bytes is accepted. A changed list is refused, and the routine must run again or a person reconciles by hand. A changed PR head needs a fresh `check`.

**Exit status:** 0 when generated or checked, 1 when refused (one line on stderr), 2 for a usage error.

**Tests:** `propose.py --self-test` runs `propose_test.py`, which runs every category in its `CATEGORIES` tuple against throwaway git repositories. `CloudModelRoutineProposalTests` (Swift) passes real receipts from the fake-run harness through this script.

## The weekly workflow (`workflow.py`)

`.github/workflows/cloud-models-sweep.yml` runs the routine every Monday at 06:17 UTC, and also when started by hand. `workflow.py` is the helper each job calls. It never decides what a row may be. That is always `propose.py`.

| Job | Credentials | What it does |
|---|---|---|
| `sweep` | The three provider keys, only in its `Sweep` step. Repository read only. | Runs `workflow.py authorize` (this repository, `schedule` or `workflow_dispatch`, `refs/heads/main`, the routine workflow file, a full commit id). Then it runs the paid Swift sweep with `--real-boundary` and `finish-sweep`. `finish-sweep` checks that the named test `weeklySweep()` passed in a lane that executed at least one test with verdict PASS. It scans the receipt for the injected keys, builds the checker context from GitHub's own run facts and runs `propose.py generate`. It then scans every staged file again and uploads only the allowlisted evidence files. |
| `publish` | The routine App token, minted here only, with contents, pull requests and issues write. No provider keys. | Checks the evidence (allowlisted files, size limits, manifest hashes, this run's context) and regenerates the proposal from the receipt. It refuses any difference. It files one deduplicated issue per failed model, and the call-recipe issue when every setting was rejected. For a proposal, it pushes `cloud-model-routine/run-<id>-<attempt>` and opens one PR. A rerun reuses an identical branch and the App's open PR. Another author, other content or a closed PR is refused. It never merges or enables auto-merge. |
| `verify-run` (Stage 2) | A repository read token. GET requests only. | Classifies one completed run as `verified`, `failure`, `temporary` or `refused` from GitHub's facts and the run's own evidence, regenerating the proposal with `propose.py`. Contract: `workers/cloud-models-routine/README.md` "Run verification". |
| `report-failure` | `GITHUB_TOKEN` with issues write. No provider keys. Runs only for this repository's schedule or manual run on main, and `authorize` runs again before any request. | Works out a closed stage (`authorize`, `sweep`, `receipt`, `publication`, `outcome`, `cancelled`) from job results only. It comments once per run on the open `Cloud model routine: run failed` issue. It cannot report a run that never started; Stage 2 and the digest detect missing runs. |

Issue and comment lookups read every page; a failed page refuses before any write, and only the reporting bot's own issue body and comments count as an earlier report. The token is sent as an unredirected header, so it never follows the artifact download's redirect to signed storage. Later jobs never see the provider keys. They read only the evidence files the `sweep` step already scanned. Every public body (list rows, the result, the PR body, issue bodies) is built from those files.

**PR check:** the `routine-pr-check` job in `pr-check.yml` feeds `build-check`. It treats a PR as a routine PR only when its author is the App's bot login (`CLOUD_MODEL_ROUTINE_APP_BOT`) with type `Bot`. Labels, titles, branches and bodies decide nothing. For a routine PR, the trusted tooling comes from the PR base and the PR head is checked out separately, as data only. The job then refuses the PR unless all of these hold:
- the source run is `cloud-models-sweep.yml` on main, started by a schedule or by hand, with its `sweep` job succeeded
- the run has exactly one current evidence artifact for that run and attempt
- the evidence context matches the run's own GitHub facts
- the PR changes only the two list copies, at the current head
- `propose.py check` passes against the recorded base and the PR's current base

Every other PR passes this job and keeps the ordinary list validation in `website-check`.

**Activation prerequisites:** this file does not set any of these.
- The `cloud-model-routine` Environment, restricted to `main`, holding the secrets `EW_ROUTINE_OPENAI_KEY`, `EW_ROUTINE_CLAUDE_KEY` and `EW_ROUTINE_GEMINI_KEY`.
- The `cloud-model-routine-publish` Environment, restricted to `main`, holding `CLOUD_MODEL_ROUTINE_APP_PRIVATE_KEY`.
- The repository variables `CLOUD_MODEL_ROUTINE_APP_ID` and `CLOUD_MODEL_ROUTINE_APP_BOT`.
- The App installed on this repository only. Until `CLOUD_MODEL_ROUTINE_APP_BOT` is set, no PR counts as a routine PR.

**Tests:** `workflow.py --self-test` runs `workflow_test.py`. It runs every group in its `GROUPS` tuple against throwaway git repositories and a fake GitHub. It needs PyYAML, and it fails on any skip, any empty group, or fewer tests than the floor in its `run()`. Not verified locally: live GitHub publication, whether required checks start on an App-created PR, Environment restrictions and the paid sweep.
