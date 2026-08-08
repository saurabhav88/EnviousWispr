# EG-1 English List Pilot 75+75 Decision Contract V1

Status: predeclared 2026-07-15 08:07 EDT, before any current-EG-1 prompt-arm output was generated or opened. Development evidence only.

## Fixed architecture and arms

- Architecture gate: one universal offline EG-1 model. This prompt experiment cannot justify another full language model.
- Baseline arm: current shipped EG-1 prompt.
- Candidate arm: list-aware V2 prompt.
- Runtime: the same active app-owned server, shared model shards, model ID `eg-1`, and shipping flags for both arms.
- Request path: `scripts/eval/eg1_local_app_eval.py`, bound to the explicit verified app bundle, authenticated health, and exact shipped-request behavior.
- Sampling: the first 75 accepted checkpoint-order positive cases and first 75 accepted checkpoint-order restraint cases already sealed model-blind. No substitutions based on either arm's output.
- Scoring: deterministic scorer first, followed by an arm-blind independent semantic review. The semantic reviewer may not see aggregate or paired scores before completing case judgments.

## Co-primary results

The two lanes remain separate:

1. Positive-list strict success: `x/75`, Wilson 95% interval.
2. Restraint false-list rate and restraint strict success: `y/75`, Wilson 95% intervals.

No combined percentage is allowed. A combined paired strict comparison may appear only as diagnostic detail because a list gain cannot average away a restraint regression.

## Candidate advancement gate

The list-aware prompt advances only when every condition passes:

1. Positive strict improvement is at least eight net cases out of 75, or 10.67 percentage points.
2. The positive strict paired comparison has two-sided exact McNemar `p < 0.05`.
3. There are zero candidate-only false-list regressions on the restraint lane, and the candidate's total false-list count does not exceed baseline.
4. Deterministic audited item loss and scope loss do not increase in either lane.
5. Arm-blind semantic review finds zero new meaning-damaging edits, including lost identity, quantity, timing, negation, medical/legal scope, or fabricated content.
6. The candidate has zero inference errors and zero empty outputs.

Failure of any restraint, meaning, or inference condition rejects the candidate even when positive-list gains are large. A non-significant positive result is inconclusive, not proof of no effect. Passing means only `advance to a larger, native-reviewed/frozen evaluation`; it is not release approval.

## Statistical limits fixed before results

For one 75-case lane, representative Wilson 95% intervals are:

| Observed | Rate | Wilson 95% interval |
|---:|---:|---:|
| 0/75 | 0.00% | 0.00%-4.87% |
| 1/75 | 1.33% | 0.24%-7.17% |
| 68/75 | 90.67% | 81.97%-95.41% |
| 74/75 | 98.67% | 92.83%-99.76% |
| 75/75 | 100.00% | 95.13%-100.00% |

Even 0/75 false lists cannot establish the proposed 2.5% release ceiling; its one-sided exact 95% upper bound is 3.92%, and its two-sided Wilson upper endpoint is 4.87%. The pilot therefore cannot prove release safety.

Using the repository's unconditional power calculation for the two-sided exact conditional McNemar test, a true five-point paired improvement with 75 cases has only:

| Discordance rate | Power for true +5 points |
|---:|---:|
| 10% | 15.41% |
| 20% | 10.65% |
| 30% | 8.28% |
| 40% | 7.13% |
| 50% | 6.81% |

Approximate net effects required for 80% power are 12.54 points at 15% discordance, 14.64 at 20%, 18.14 at 30%, 21.11 at 40%, and 23.48 at 50%. This pilot can detect a large, clean prompt effect and obvious safety failures. It cannot reliably establish a five-point improvement, equivalence, multilingual quality, real-user accuracy, or release quality.

## Bound evidence

- sealed selection manifest SHA-256: `7d7831eb14406f15c1e9c12cbdf98e3d198b370ee5623cfa9a565307d08dd174`
- sealed pilot-definition SHA-256: `5a7cb24ef6fe61f7f67cee66338fc0a4adcf1da16697ff31e2c10f6faf50ca04`
- fail-closed scorer SHA-256: `d150cd011563a7a42478890dce3c014dcd8b2b6cb8d918222c86c239ee0facef`
- paired-power implementation SHA-256: `9e1c522666818c7d875bd2932a58b4d3fed8eab4011a01ffa971ed2524132677`
- contract parent commit: `aa412af3c101ae8b7ffe3bcd6e17c5df4107f2f0`

If any bound file changes, this contract must be versioned before new model output is generated. It may not be edited after outputs exist to make a result pass.
