# Cloud model list scripts (#4353)

The cloud model list is `website/public/cloud-models.json`, with a byte-identical bundled copy at `Sources/EnviousWispr/Resources/cloud-models.json`. The app's contract is `CloudModelList.validated(from:)` in `Sources/EnviousWisprLLM/CloudModelList.swift`.

| Script | Job |
|---|---|
| `validate-list.py` | Validates a list document against the shared fixtures in `fixtures/`, the same ones `CloudModelListTests` runs through the Swift parser. `--same A B` also requires the two copies to be byte-identical. |
| `propose.py` | The weekly routine's only owner of permitted automated list changes. `generate` writes a proposal and `check` verifies one. Both call the same permission engine. |

Engineering changes to the list (a recommendation, a request edit, a label) are ordinary reviewed PRs. They are outside `propose.py`'s policy. The workflow decides which PRs are routine PRs (#4353 PR 5, chunk 7).

## propose.py

```text
propose.py generate --base REV --receipt FILE --context FILE --freshness FILE \
                    --output-root DIR --result FILE [--repo DIR]
propose.py check    --base REV --receipt FILE --context FILE --freshness FILE \
                    --result FILE --current-root DIR --target-base REV [--repo DIR]
propose.py --self-test
```

**Inputs and trust**

- **`--receipt`:** the measurement receipt the Swift harness wrote. It is data: no field is executed, and refusal messages name fields, never values. The script refuses a receipt with a missing or contradictory field. It never fills in a default.
- **`--base`:** the recorded base, which is the commit the routine measured. It must resolve to a commit equal to the receipt's and the context's `sourceSHA`. Both list copies at that commit must be identical, valid, in the canonical two-space form, and must hash to the receipt's `list.sha256`.
- **`--context`:** what the authenticated caller (the workflow or Stage 2, which got the receipt from GitHub) states about the run. Its fields are `schema`, `repository`, `workflow`, `runID`, `runAttempt`, `event`, `ref`, `sourceSHA` and `receiptSHA256`. The script compares these with the receipt and its bytes. **A match here does not authenticate the receipt with GitHub. The caller must do that.** There is no way to skip this comparison.
- **`--freshness`:** for each provider, the latest successful catalog observation that the caller authenticated, or `null`. A newer observation supersedes this receipt's hide and un-hide actions for that provider. The script refuses an observation older than the receipt's own complete observation, and also refuses a missing one.

**What it may change**

- **Add a row:** a new provider/id with `recommended: false` and `hidden: false`. A `pass` adds the unchanged fallback row, including after an OpenAI parameter strip. A `passViaSearch` adds the chosen setting. That requires a rejected fallback, the search menu order, one screening success and three confirmation successes without adaptation, successful replies and physical requests that carry exactly that setting. Chat eligibility and file batching must stay the fallback's for the id and its dated spellings, as the receipt's `resolution` reports them. The script does not re-derive capability or dated-id rules. Every phase (the fallback and each search attempt) must match the requests the ledger recorded for it. An earlier attempt must have ended in a way the search continues after (a rejected request, unusable output or an adaptation), and no earlier attempt may have qualified. `medianPolishMs` must be the middle of the passing phase's measured timings, or absent when that is out of range.
- **Hide a row:** only after two distinct weekly absences from a complete, current catalog. The history must be real ISO weeks, one entry per row, no later than the provider's latest observation, and must agree with this run's absence report. Only `hidden` and `hiddenReason` change, and an earlier reason is replaced by the routine's own.
- **Un-hide a row (founder decision 13):** only a row whose `hiddenReason` is exactly the routine's own `Not in the provider's model list since YYYY-MM-DD`, with a real date, and that a complete, current catalog shows again (`alreadyHiddenPresent`). The script removes `hiddenReason` and sets `hidden: false`. A row with any other reason belongs to a person and stays hidden.
- **Leave everything else alone:** the script never deletes, reorders or edits other rows or fields. `updated` changes only with a proposal. It becomes the later of the base date and the run's UTC day.

**Outputs**

- **With changes:** `generate` writes both list copies under `--output-root`, then writes the result file last. The result holds the receipt hash, the recorded base, the instrument outcome, the final outcome, the operations, the list hash and digest notes (`missingForRoutineKey`, `personHiddenPresent`, `supersededByNewerObservation`).
- **With no permitted change:** no list file is written, and the result says `proposal: false`.
- **`failure` and `partial`:** these outcomes are never upgraded. A `failure` proposes nothing.
- **Status:** `proposalStatus` is only `proposed` or `none`. Merge and publication are recorded later.

**Checking**

`check` is read-only. It recomputes the result from the same inputs and requires these to be exactly the recomputed bytes:

- the current list copies under `--current-root`
- the result file

It also requires the list at `--target-base` (the PR's current base) to be the recorded base list. A moved base with the same list bytes is accepted. A changed list is refused, and the routine must run again or a person reconciles by hand. A changed PR head needs a fresh `check`.

**Exit status:** 0 when generated or checked, 1 when refused (one line on stderr), 2 for a usage error.

**Tests:** `propose.py --self-test` runs `propose_test.py`, which covers four categories against throwaway git repositories. `CloudModelRoutineProposalTests` (Swift) passes real receipts from the fake-run harness through this script.
