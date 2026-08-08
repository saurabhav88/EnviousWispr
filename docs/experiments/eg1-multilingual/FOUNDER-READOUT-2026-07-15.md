# EG-1 Multilingual Overnight Readout

Status: living draft as of 2026-07-15 16:31 EDT. Development evidence only; no frozen release claim.

## The short answer

The old 93.7% score is not trustworthy as a real-world quality claim. The old training and evaluation files overlap on 1,549 of 1,890 evaluation rows, about 82%. Real user feedback about lists and international languages is consistent with the failures found in the new audits.

The first fresh exact-Mac result is now complete. A list-aware prompt made EG-1 produce more lists, but it also produced more false lists, more scope loss, and six candidate-only meaning-damaging cases under arm-blind review. Prompt-only is rejected.

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
| [Phi-4-mini](https://huggingface.co/microsoft/Phi-4-mini-instruct) | Explicitly lists all five target languages among 23, but Microsoft says training remains primarily English. | Eligible on paper; task audit found frequent translation and number/entity corruption, so it is rejected. |
| [Ministral 3](https://huggingface.co/mistralai/Ministral-3-3B-Instruct-2512-BF16) | Claims dozens and explicitly names English, French, Spanish, and German among 11 highlighted languages. Russian is not in that explicit list. | Russian is a higher-risk target even before the weak task-specific English result. |
| [EuroLLM-9B](https://huggingface.co/utter-project/EuroLLM-9B-Instruct-2512) | A European multilingual specialist covering 35 languages, including all five targets. | Eligible as one universal model, but rejected at smoke after wrapper tags leaked in 2/5 outputs. |

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
| 3 | Qwen3.5-9B capacity control | Blind audit: 40/92 strict overall and 31/56 multilingual, but 15 damaging edits, 7/16 Russian, only 2/20 English two-item, and 0/100 broad list activation. | Stop after the full development benchmark; extra capacity did not justify a tuning or Mac-runtime lane. |
| 4 | Current Qwen3 EG-1 | Smallest shipping baseline, but 8/56 damaging rows in the current multilingual audit and weak short-list activation. | Keep as exact-Mac baseline, not evidence that quality is solved. |
| 5 | Phi-4-mini-instruct | English list shape was comparatively strong at 11/20 semantic strict, but multilingual was only 18/56 and 26/92 rows had damaging edits, including translation and critical identifier/number corruption. | Reject from this tuning lane; do not spend a training run on it. |
| 6 | Ministral 3 3B Instruct | Compact, but the blind audit found only 30/92 strict overall, 24/56 multilingual, 5/16 Russian, and 1/20 English two-item outputs. | Reject from this tuning lane; do not spend a training run on it. |
| 7 | EuroLLM-9B-Instruct-2512 | The Spanish smoke stayed in-language and produced 5/5 nonempty outputs, but 2/5 leaked internal transcript or cleaned-text wrappers, including one full transcript-frame repeat. | Hard stop at smoke; no full benchmark, scoring, tuning, quantization, or Mac-runtime work. |

These differences are small development signals, not statistically established release rankings. Native review and frozen data are still required.

## What Qwen3's language evidence actually says

There is no statistically valid ranking of English, German, French, Spanish, and Russian yet. The existing evidence mixes different prompts, runtimes, judges, tasks, and exposed development sets.

The narrow current-EG-1 diagnostic is German > French > Spanish on one shared eight-case legacy slice: German passed polishing on 8/8, French on 6/8, and Spanish on 2/8. Those samples are tiny: the 95% Wilson intervals are 67.6%-100%, 40.9%-92.9%, and 7.1%-59.1%, respectively.

Untouched Qwen3 is even less stable across evidence paths:

| Language | Legacy strict | Newer bakeoff strict |
|---|---:|---:|
| German | 0/8 | 6/8 |
| French | 3/8 | 6/8 |
| Spanish | 1/8 | 3/8 |

The case families are shared, but the prompt and review path changed. The newer aggregate reports seven damaging rows across its 56 multilingual cases, and its per-case semantic judgments were not retained for independent recomputation. The disagreement is evidence of prompt/judge sensitivity, not a real improvement.

Russian is also prompt-sensitive: untouched Qwen3 moves from 3/16 strict with the shipping prompt to 7/16 with the strict or labeled prompt on the same development cases. English broad Type B is excluded because of training/family exposure, while English list mechanics measure a different task. A human-authored/native-reviewed benchmark is not available, so the next defensible ranking will use one common, balanced, family-disjoint proxy built from licensed public human speech and reference transcripts. It must be labeled proxy evidence rather than human validation.

## What was learned about prompts versus training

The list-aware prompt increased visible list activation, but prompt-only changes were not safe enough:

- On a fresh leakage-audited 75 positive plus 75 restraint comparison through the exact shipped Mac runtime, current EG-1's list-aware prompt increased list activation from 52/75 to 68/75 but strict positive success only from 11/75 to 15/75. The four-case paired gain was not statistically significant (`p=0.125`) and missed the predeclared eight-case minimum.
- False lists increased from 25/75 to 32/75. Positive scope loss increased from 15/75 to 23/75.
- Three independent blind reviewers plus a fourth blind adjudication found 12/150 meaning-damaging candidate outputs versus 8/150 for baseline, including six candidate-only damaging cases and only two baseline-only cases.
- The safer Gemma arm improved list shape, but its low-dose and prompt-aligned tuned checkpoints still introduced scope or medical-timing damage.

Conclusion: prompt engineering helps expose the behavior boundary but does not solve the problem alone. The best remaining universal route is a materially larger, balanced data dose derived from licensed human speech, followed by a separately frozen web-speech proxy and exact-Mac validation. Automated gold/review must use multiple checks and cannot be described as native-human evidence.

Simply increasing Qwen3.5 from 4B to 9B did not solve it either. The 9B control learned explicit two-bullet shape more readily, but it dropped scope or identity in eight of those explicit rows and never activated on the broader 100-case positive-list check. Switching to Phi-4-mini improved English list shape but made international safety much worse. Better data and stricter preservation training matter more than parameter count or a family swap alone.

The multilingual-specialist EuroLLM-9B control also failed before the full benchmark: two of five untouched Spanish smoke outputs exposed internal wrapper tags. The predeclared fail-closed rule stopped the lane immediately. This rejects that exact model, not the one-universal-model requirement.

The Qwen3.5-4B reserve is now technically LoRA-compatible, but it has no quality evidence. A fresh AlienSV compatibility preflight used the reviewed trainer bytes and the pinned four-row private synthetic set. It attached LoRA to all 248 required text modules, including all 120 GDN placements, with zero vision/MTP leakage and exactly 32,464,896 trainable parameters. It completed the contract's single optimizer step in 20.347 seconds and saved a 129,927,008-byte adapter. The manifest explicitly marks this as compatibility-only, not a benchmark, candidate, checkpoint promotion, or reason to train before approved D1 data exists.

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

No frozen model outputs have been opened. The original contract cannot pass without native authorship and review. Founder direction now replaces that unavailable dependency with a clearly labeled web-speech proxy: the real EnviousWispr ASR transcript from licensed public audio is the input, the public reference transcript anchors content truth, and deterministic plus model-blind automated checks score preservation and formatting. Frozen selection remains private and unopened until a finalist is locked.

The common five-language source pool is now fixed in principle. MINDS-14 supplies naturally spoken banking requests in EN/DE/FR/ES/RU; FLEURS supplies broader-topic human read speech in all five languages. Both are CC-BY-4.0 and large enough for 160 development plus 320 frozen cases per language with a 50/50 source split. This removes language-specific source imbalance from the ranking while retaining two meaningfully different speech conditions. MINDS-14 is narrow-domain and FLEURS is read speech, so neither source alone is allowed to support a broad quality claim.

The English Type B proxy will retain the sealed 1,890-case category, length, and trap matrix while drawing equally from held-out FLEURS read speech, VoxPopuli parliamentary speech, and AMI meeting speech. List cases may combine multiple same-family source fragments through predeclared deterministic cue templates, with every component retained in the family graph. That tests list mechanics using human-speech content without pretending the synthetic list wrapper itself came from a natural dictation.

The 800-row development authoring gate is now implemented and independently clean. Its 20% shared slice is exactly 32 language-neutral briefs rewritten once in each of the five languages, not the 80 briefs used by the separate 2,000-row D1 training design. One private roster owns four disjoint roles: concept author, concept reviewer, local native author, and local native reviewer. Every concept and local identity is resolved through that same private identity-reference registry; at least five concept authors and five concept reviewers are required, with no one handling more than eight briefs. The exact roster, brief content hashes, five-language bindings, native fidelity reviews, leakage evidence, and rating schema remain authenticated through launch, merge, evaluation verification, and final ratings. This closes the earlier loophole where five unrelated examples could be labeled as one shared multilingual family.

The final private Mac/MPS proof passed in 17 minutes 41 seconds. It exercised the exact clean-archive allocation, brief sealing, roster-bound launch, production scanner, production merge recomputation, synthetic scanner, and synthetic merge recomputation. Both production and synthetic evidence were rejected before evaluation for the correct reasons: production thresholds are still calibration-required, and synthetic output is not quality evidence. This proves the gate fails closed; it does not supply the missing native benchmark content or make a model-quality claim.

The D1 universal training-data contract separately allocates 2,000 families: 400 per priority language, balanced across core polishing, positive lists, and matched prose restraints. The 400 cross-language rows now have a sealed metadata-only allocation: 80 language-neutral concepts, each mapped once into English, German, French, Spanish, and Russian. No concept prose, identity, approval, or model output exists yet. D1 still cannot export training data until those private concepts and all 2,000 rows are independently approved and screened against training and benchmark families.

The broad English Type B gate remains required, but its content must be rebuilt. A fresh audit found shipping training overlaps 1,549/1,890 old Type B rows exactly. ID/origin transitive components expose 1,866/1,890 rows; seeding that same family graph with conservative normalized-text matches exposes 1,868/1,890. The old gate cannot support a real-world accuracy claim. The 900 overflow rows have zero exact overlap but 899/900 share exposed families, so they cannot simply replace the training rows.

The replacement controls are now sealed. The authenticated registry covers 11,236 source rows, 7,198 opaque blocked families, 13,733 normalized input/output hashes, and all 23 provisional decisions. Because semantic-family clearance was not proven for any provisional row, all 23 are replaced. The authoring workflow now holds 1,867 fresh primary assignments plus 23 activated same-cell reserves: 1,890 active assignments in 126 balanced 15-case packets, with 1,913 total custody records. Its canonical metadata-only receipt is `d0867b581d73e4f7b5717a0c78ac42a2b4043b0328a4f1d957048ce55878979f`. No benchmark prose or candidate output exists yet.

The old 5,656-row English replay source has also been screened without publishing private text. Exact overlap and duplicate-family controls left 4,051 candidate-only rows. A local four-axis embedding screen compared every candidate with all 2,790 historical Type B rows and produced a metadata-only manual-review queue. The queue is authenticated and review-cleared, but every row still requires semantic-family, meaning-safety, and native-editorial approval. Zero replay rows are training-eligible and export remains prohibited.

## Adapter fallback: feasible, but not needed yet

The exact bundled Mac runtime proved the permitted storage shape:

- Shared Q5 base: 2.69 GiB.
- One current rank-16 F16 adapter: 63.0 MiB.
- Base plus five same-size adapters: about 3.00 GiB total.
- Five separate full models: about 13.45 GiB and categorically disqualified.

One selected adapter loaded offline and added about 79 MiB idle memory with sub-second warm readiness. Loading two adapters at once failed output isolation, so the safe fallback today is exactly one selected adapter loaded with the shared base, using a local server restart when switching. No language adapter has passed a quality gate, and this fallback does not enter finalist ranking until the universal data-dose ladder fails or plateaus.

## Work still in flight

1. Freeze the licensed web-speech source contract and exact dataset revisions before candidate output. Download only into ignored local storage, preserve license/source/audio/reference hashes, and assign whole source-text families to development, frozen, or Type B exactly once.
2. Run the public audio through the real EnviousWispr ASR path, build the 800-row multilingual development proxy, and seal the 1,600-row minimum frozen proxy without opening frozen model output. Build the separate 1,890-case Type B proxy from held-out English source families and the already sealed category matrix.
3. Create the first balanced training dose from development-authorized web-speech families only. Train the Gemma 4 E4B primary after leakage checks; keep Qwen3.5 as the technically compatible reserve and never train from frozen or Type B families.
4. Compare candidates on development panels. Stop each exact recipe after one smoke and one full benchmark if it does not improve without meaningful regressions.
5. Run the leakage-clean Type B V2 gate only once on a locked finalist, then validate any survivor through the exact shipped Mac path. The current app build must first embed signed build provenance and an app-produced or compiled-Swift delivery receipt; a Python shipping-contract mirror is useful evidence but is not literal end-user delivery parity.

## Decisions that are not yet justified

- Do not claim 94-95% real-world quality.
- Do not name a release winner from the small development sets.
- Do not open the frozen benchmark early.
- Do not train per-language full models.
- Do not assume a small adapter is safe merely because it loads.
- Do not reject the universal-model strategy based on the earlier 40-rows-per-language smoke.
