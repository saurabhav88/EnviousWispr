# EG-1 English List Pilot 75+75 Decision Contract V2

Status: blocked before model output. V2 strengthens V1 after independent code-only preflight. Every `PENDING` binding below must be replaced and this contract committed before either arm is rendered or run.

## Fixed scope and architecture

- Development evidence only; no release-quality or frozen claim.
- Preferred architecture remains one universal offline EG-1 model. This prompt experiment cannot justify another full language model.
- Baseline arm: current shipped EG-1 prompt.
- Candidate arm: list-aware V2 prompt.
- Both arms use the same 75 positive-list and 75 prose-restraint cases, in the same order, through the same app-owned `llama-server` process and model ID `eg-1`.
- This pilot measures connector-wire output after shipped connector cleanup. It is not paste-equivalent proof because the later app-level `validatePolishOutput` fallback is outside this run.

## Sealing and execution requirements

1. The portable corpus assembly receipt, both corpus hashes, both raw and model-visible prompt hashes, renderer, shipped-request mirror, runner, dual-arm orchestrator, scorer, this contract, and Git commit are bound before output.
2. The renderer emits only `id`, `system`, `user`, and `max_tokens`; expected answers and audit metadata cannot enter a model request.
3. Baseline and candidate renderings must have byte-identical ID order, user messages, and token budgets. Only the system prompt may differ.
4. One dual-arm orchestrator discovers and authenticates the server once, verifies every model shard against the bound shipping manifest, then proves the same PID, parent PID, app bundle, endpoint, model artifact, and shipped flags before and after each arm.
5. Both baseline and candidate arms must have zero inference errors and zero empty outputs. Any failure invalidates the complete A/B run and requires a fresh full run under a new run ID. Case-only reruns are prohibited; the one shipped transport retry remains allowed.
6. Outputs and receipts use exclusive creation. The A/B receipt is written last and binds both output hashes to their explicit arm and prompt hashes.
7. Deterministic scoring requires the A/B receipt and explicit baseline/candidate mapping. Filename order cannot define direction.
8. Semantic review uses opaque randomized arm labels. The reviewer receives no prompt names, expected answers, mapping, deterministic results, or aggregate scores.

## Co-primary results

Report separately:

1. Positive-list strict success: `x/75`, Wilson 95% interval.
2. Restraint false-list rate and restraint strict success: `y/75`, Wilson 95% intervals.

No combined headline percentage is allowed. Combined paired strict may appear only as diagnostic detail.

## Candidate advancement gate

The list-aware prompt advances only when every mechanical condition passes and semantic review later passes:

1. Positive strict improvement is at least eight net cases out of 75, or 10.67 percentage points.
2. Positive strict has two-sided exact McNemar `p < 0.05`.
3. Candidate-only false-list regressions on restraint equal zero, and candidate total false lists do not exceed baseline.
4. Candidate item-loss and scope-loss counts do not increase in either lane.
5. Both arms have zero inference errors and zero empty outputs.
6. Arm-blind semantic review finds zero cases where the candidate is meaning-damaging and has higher severity than the baseline, including identity, quantity, timing, negation, medical/legal scope, and fabrication.

Failure of any condition rejects the candidate. A non-significant result is inconclusive. Passing advances only to a larger native-reviewed/frozen evaluation.

## Statistical limits

- `0/75` false lists has a Wilson 95% upper endpoint of 4.87% and a one-sided exact 95% upper bound of 3.92%; this pilot cannot prove a 2.5% release ceiling.
- A true five-point paired improvement has poor power at this sample size. Approximate 80% minimum detectable net effects range from 12.54 points at 15% discordance to 23.48 points at 50% discordance.
- This pilot can detect a large clean effect or obvious safety failure. It cannot prove equivalence, multilingual quality, real-user accuracy, or release quality.

## Bound evidence

This block is machine-parsed. Rendering must reject every missing, extra, duplicate, malformed, or `PENDING` value. Git uses a non-circular two-commit proof: all code and data hashes are frozen in the code-anchor commit; the current execution HEAD must be its direct child and may change only this contract.

<!-- EG1_LIST_V2_BINDINGS_BEGIN -->
```json
{
  "assembly_receipt_sha256": "PENDING",
  "positive_corpus_sha256": "PENDING",
  "restraint_corpus_sha256": "PENDING",
  "baseline_raw_prompt_sha256": "PENDING",
  "baseline_model_visible_prompt_sha256": "PENDING",
  "candidate_raw_prompt_sha256": "PENDING",
  "candidate_model_visible_prompt_sha256": "PENDING",
  "contract_verifier_sha256": "PENDING",
  "renderer_sha256": "PENDING",
  "shipped_request_mirror_sha256": "PENDING",
  "local_wrapper_sha256": "PENDING",
  "subset_runner_sha256": "PENDING",
  "dual_arm_orchestrator_sha256": "PENDING",
  "deterministic_scorer_sha256": "PENDING",
  "ab_scorer_sha256": "PENDING",
  "blind_packet_builder_sha256": "PENDING",
  "semantic_rubric_sha256": "PENDING",
  "semantic_unblinder_sha256": "PENDING",
  "delivery_manifest_sha256": "PENDING",
  "code_anchor_git_sha1": "PENDING"
}
```
<!-- EG1_LIST_V2_BINDINGS_END -->

No model output may be generated while any binding remains pending.
