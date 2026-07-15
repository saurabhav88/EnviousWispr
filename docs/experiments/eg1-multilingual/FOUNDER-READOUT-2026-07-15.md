# EG-1 Multilingual Overnight Readout

Status: living draft as of 2026-07-15 06:18 EDT. Development evidence only; no frozen release claim.

## The short answer

The old 93.7% score is not trustworthy as a real-world quality claim. The old training and evaluation files overlap on 1,549 of 1,890 evaluation rows, about 82%. Real user feedback about lists and international languages is consistent with the failures found in the new audits.

The product architecture is now non-negotiable:

1. Preferred: one universal offline EG-1 download for every supported language.
2. Fallback: one byte-identical shared base plus small delta-only language adapters.
3. Disqualified: making one user download a second complete base-weight model for another language.

A larger universal model is allowed when quality justifies it. Download size is scored only after the one-base, offline, safety, English, and Mac-runtime gates pass.

## Why these five languages

The 30-day PostHog snapshot showed 352 installs and 15,260 dictations across 38 countries. Germany led installs with 182 after the German blog, followed by the United States with 61; India had 11 and the United Kingdom had nine. Country is only a prioritization proxy because the visible production `language` property was blank, not proof of what people dictated.

English remains the primary product target. German has the clearest current international demand. French, Spanish, and Russian complete the first five because they provide meaningful language-family variety and are relevant to the strongest base-model candidates. Every language keeps its own quality and safety gate; a strong aggregate cannot hide a weak language.

Official model-card coverage is only an eligibility screen, not proof of polishing quality:

| Base family | Official multilingual claim | First-five implication |
|---|---|---|
| [Qwen3](https://qwenlm.github.io/blog/qwen3/) | 119 languages and dialects; the official list explicitly includes English, German, French, Spanish, and Russian. | All five are claimed, but current EG-1's task-specific audits still find real damage. |
| [Qwen3.5](https://huggingface.co/Qwen/Qwen3.5-4B) | 201 languages and dialects, with aggregate multilingual benchmarks over 23-63 settings depending on the benchmark. | Broadest claimed coverage, but the small copy-edit audit did not match the aggregate ranking. |
| [Gemma 4](https://huggingface.co/google/gemma-4-E4B-it) | Pre-trained on 140+ languages with out-of-the-box support for 35+. | Broad enough to test all five; native task data must establish which are truly strong. |
| [Ministral 3](https://huggingface.co/mistralai/Ministral-3-3B-Instruct-2512-BF16) | Claims dozens and explicitly names English, French, Spanish, and German among 11 highlighted languages. Russian is not in that explicit list. | Russian is a higher-risk target even before the weak task-specific English result. |

This is why the project cannot choose a base from a general multilingual leaderboard. The relevant question is whether it safely preserves names, numbers, scope, corrections, lists, and grammar in each target language.

## What the current model actually looks like

- Current EG-1 is Qwen3-4B-Instruct-2507 plus a rank-16 LoRA trained for two epochs on 5,656 mostly English examples.
- The PEFT adapter is 126.1 MiB. Its converted F16 LoRA GGUF is 63.0 MiB. The shipped merged Q5 model is 2.69 GiB.
- Only 259 training outputs are lists. Just three are two-item lists, the shape users are reporting as weak.
- The historical multilingual smoke added only 40 synthetic, non-native-reviewed rows per non-English language. The 160 non-English rows were 2.74% of its training mixture. That experiment was too small to answer whether a properly trained universal model can work.

## Current discovery ranking

| Rank | Candidate | What the evidence says | Current action |
|---:|---|---|---|
| 1 | Gemma 4 E4B | Lowest observed meaning damage in the 56-case blind development audit: 1/56, versus 5 for Qwen3.5 and 7 for untouched Qwen3. Much larger download. | Safety-first universal training base; exact low-dose checkpoints rejected, serious balanced-data experiment still justified. |
| 2 | Qwen3.5-4B | Strong grammar and German slice; 5/56 meaning-damaging rows and weak lists without targeted training. | Reserve universal challenger. |
| 3 | Current Qwen3 EG-1 | Smallest shipping baseline, but 8/56 damaging rows in the current multilingual audit and weak short-list activation. | Keep as exact-Mac baseline, not evidence that quality is solved. |
| 4 | Ministral 3 3B Instruct | Compact, but the blind audit found only 30/92 strict overall, 24/56 multilingual, 5/16 Russian, and 1/20 English two-item outputs. | Reject from this tuning lane; do not spend a training run on it. |

These differences are small development signals, not statistically established release rankings. Native review and frozen data are still required.

## What was learned about prompts versus training

The list-aware prompt increased visible list activation, but prompt-only changes were not safe enough:

- Current EG-1 created false lists and meaning damage.
- The safer Gemma arm improved list shape, but its low-dose and prompt-aligned tuned checkpoints still introduced scope or medical-timing damage.

Conclusion: prompt engineering helps expose the behavior boundary but does not solve the problem alone. The best remaining universal route is a materially larger, balanced, native-reviewed training dose, followed by frozen and exact-Mac validation.

## The honest benchmark now being built

The multilingual V2 contract requires at least 2,400 exact cases:

- English, German, French, Spanish, and Russian.
- 160 development rows per language and at least 320 frozen rows per language.
- All 16 polishing behaviors across five real-use domains.
- Whole-family separation from training and prior evaluations.
- At least 80% native-original writing.
- Two blinded native reviewers per frozen case/model, with a third adjudicator on every disagreement.
- Predeclared Wilson intervals, paired tests, multiple-language correction, and zero tolerance for critical meaning damage.

The frozen count is power-driven rather than fixed for convenience. First, one exact finalist is selected and locked using development only. A separate custodian then supplies only aggregate current-versus-finalist disagreement counts per language—no case IDs, arm direction, or case-level outcomes. The harness validates the real 800-row development corpus and locked model receipts, sizes from a simultaneous upper confidence bound across all five languages, and expands every behavior/domain cell equally until the paired test has at least 80% power for a five-point improvement. With 10% observed disagreement in each 160-case development language, the conservative plan selects 880 frozen rows per language. This size is locked before frozen outputs exist and cannot be changed afterward.

No frozen model outputs have been opened. The real corpus cannot pass validation until native authorship, native review, leakage receipts, and manifest binding are complete.

The D1 universal training-data contract separately allocates 2,000 families: 400 per priority language, balanced across core polishing, positive lists, and matched prose restraints. It cannot export training data until every row is independently native-approved and screened against training and benchmark families.

## Adapter fallback: feasible, but not needed yet

The exact bundled Mac runtime proved the permitted storage shape:

- Shared Q5 base: 2.69 GiB.
- One current rank-16 F16 adapter: 63.0 MiB.
- Base plus five same-size adapters: about 3.00 GiB total.
- Five separate full models: about 13.45 GiB and categorically disqualified.

One selected adapter loaded offline and added about 79 MiB idle memory with sub-second warm readiness. Loading two adapters at once failed output isolation, so the safe fallback today is exactly one selected adapter loaded with the shared base, using a local server restart when switching. No language adapter has passed a quality gate, and this fallback does not enter finalist ranking until the universal data-dose ladder fails or plateaus.

## Work still in flight

1. Finish and leakage-screen the new 100-positive/100-restraint English list development corpus, which was generated without seeing model outputs.
2. Run current EG-1 with the shipped prompt and the list-aware prompt through the exact bundled Mac runtime on that new corpus.
3. Score structure, preservation, false lists, damage proxies, confidence intervals, and paired changes; then run independent semantic cross-review.
4. Use that result to decide whether any prompt variant survives and whether the next universal Gemma/Qwen training dose should begin.

## Decisions that are not yet justified

- Do not claim 94-95% real-world quality.
- Do not name a release winner from the small development sets.
- Do not open the frozen benchmark early.
- Do not train per-language full models.
- Do not assume a small adapter is safe merely because it loads.
- Do not reject the universal-model strategy based on the earlier 40-rows-per-language smoke.
