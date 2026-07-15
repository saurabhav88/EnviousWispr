# EG-1 Multilingual Model Scorecard V1

Status: proposed decision matrix. Discovery results are incomplete; do not use this file as a final model selection.

## Hard gates

A candidate is rejected before weighted ranking when any of these is true:

1. One user must install more than one complete base-weight set to enable any two claimed languages. This includes packages described as compact, regional, optional, or language-specific. Shards of one model count together as one base-weight set.
2. Polishing requires an internet connection after model or adapter download.
3. A critical S4 meaning, entity, or numerical corruption appears in the release-grade frozen benchmark.
4. English misses the paired non-inferiority gate.
5. The candidate cannot run through the exact shipped Mac runtime within an approved memory ceiling.

Architecture Tier A, preferred: one universal full model. Architecture Tier B, fallback only: one byte-identical shared base plus delta-only language adapters that neither duplicate the base tensors nor run independently as complete models. Tier B enters finalist ranking only after the predeclared universal data-dose ladder fails or plateaus below quality, safety, or supported-Mac runtime gates. Passing the hard gate does not make Tier A and Tier B equally preferred.

A user may install any number of eligible adapters without another base download. The maximum adapter byte or base-ratio limit must be declared before final ranking; the measured 63-171 MiB artifacts are feasibility evidence, not the definition of `small`.

## Weighted score after hard gates

| Area | Weight | Evidence |
|---|---:|---|
| Multilingual strict-green quality | 25 | Frozen benchmark by language, blinded native review |
| Meaning, entity, and numerical safety | 15 | Frozen preservation gates and S0-S4 severity |
| English quality and non-regression | 10 | New frozen English set plus existing regression suites |
| Positive-list activation | 8 | Frozen two-item and three-to-five-item list cases |
| False-list restraint | 7 | Frozen prose, quoted, clinical, legal, and instruction traps |
| Download size | 8 | Exact signed bytes needed for the same complete five-language claim |
| Peak Mac memory | 6 | Exact shipped runtime measurement on supported Macs |
| Mac latency and throughput | 5 | Cold start, first token, and complete-edit latency |
| Mac power and thermals | 4 | Sustained on-device measurement |
| Adapter/update footprint | 2 | Exact adapter bytes and update mechanics |
| llama.cpp/runtime maturity | 4 | Exact bundled runtime compatibility and output parity |
| Training/tooling maturity | 3 | Reproducible QLoRA, merge, quantization, and conversion |
| License and maintenance risk | 3 | Commercial license, upstream cadence, model provenance |
| **Total** | **100** | |

Quality and safety therefore control 65 points. Deployment cost controls 25 points, including an 8-point download-size weight. Engineering and licensing control 10 points.

Download-size ranking uses every byte required to enable English, German, French, Spanish, and Russian. A universal candidate uses its complete universal artifact. An adapter candidate uses the shared base plus every adapter needed for the same claim. Base-plus-one-selected-adapter and marginal adapter size are reported separately as user-experience evidence, but neither can replace the full-claim footprint in ranking.

## Current discovery-only facts

| Candidate | Task-specific discovery | Approximate full download | Adapter | Status |
|---|---|---:|---:|---|
| Current shipped EG-1, merged Qwen3-4B | 56-case multilingual strict 32/56, meaning 48/56, 8 damaging; Russian strict 8/16 | Q5 2.69 GiB | None at runtime | Single-universal-artifact architecture passes; multilingual discovery quality is insufficient and frozen/native proof is absent |
| Qwen shared-base plus current EG-1 LoRA prototype | English two-item strict 2/20; adapter changes output but loses required meaning | 2.69 GiB base plus 63.0 MiB adapter | 63.0 MiB F16 LoRA GGUF | Fallback storage and single-selected-adapter loading proven; current adapter quality rejected; simultaneous preload rejected |
| Qwen multilingual low-dose smoke | Russian independent strict 9/16; trades one damaging case for another | Custom GGUF not built | about 137 MiB including metadata | Reject low-dose recipe as finalist |
| Gemma multilingual low-dose smoke + list-v2 | Russian shipped-prompt independent strict 14/16 vs current 8/16; 56-case meaning damage 2 vs current 8; fresh list shape 82/100 intended count with 1/100 false lists, semantic audit pending | Q5 5.37 GiB; Q6 5.79 GiB; Q8 7.48 GiB | about 171 MiB including metadata | Reject exact checkpoint: Q5/Q6/Q8 all showed development meaning or scope damage |
| Prompt-aligned Gemma multilingual smoke + list-v2 | Russian strict 14/16 vs current list-v2 6/16, but English two-item strict stayed 4/20 and introduced one medical timing loss; fresh list shape regressed to 63/100 intended count | Not converted after BF16 hard stop | about 171 MiB including metadata | Reject exact recipe; keep Russian training signal |
| Untouched Gemma 4 E4B | 56 multilingual: strict 29/56, meaning 55/56, 1 damaging; English two-item strict 4/20 with 1 damaging | Registry Q4 4.97 GiB | none | Safety-first universal-base discovery finalist; native/frozen proof pending |
| Historical English-tuned Gemma 4 E4B | Russian independent strict 12/16; learned lists but retained filler/number failures | Custom GGUF not built | about 140 MiB | Evidence for multilingual Gemma experiment |
| Untouched Qwen3.5-4B | 56 multilingual: strict 28/56, meaning 54/56, 5 damaging; strongest German slice at 8/8 | Registry Q5 2.93 GiB | none | Reserve universal-base challenger; native/frozen proof pending |
| Untouched Qwen3.5-9B capacity control | Blind model-assisted strict 40/92 overall: multilingual 31/56, Russian 7/16, English two-item 2/20; 15 damaging edits; deterministic overflow activation 0/100 | Official BF16 weights 17.98 GiB; text-only GGUF size unproven | none | Stop after full development benchmark; single-universal-base gate passes, but extra capacity did not safely solve English lists or broad activation and does not justify tuning/runtime cost now |
| Untouched Phi-4-mini-instruct | Blind model-assisted strict 37/92 overall: multilingual 18/56, Russian 8/16, English two-item 11/20; 26 damaging edits with translation and critical entity/number corruption | Official BF16 weights 7.145 GiB; exact custom GGUF size unproven | none | Reject from tuning lane; one universal base and good English list shape cannot rescue multilingual safety failure |
| Untouched Ministral 3 3B Instruct | Blind model-assisted strict 30/92 overall: multilingual 24/56, Russian 5/16, English two-item 1/20; meaning safe 61/92 and no damaging extra edit 47/92 | Registry Q5 2.30 GiB | none | Reject from tuning lane; compact universal architecture cannot rescue task quality |

The size column can change rank, but it cannot rescue unsafe or low-quality output. Conversely, one 5-8 GiB universal model can beat a 2.69 GiB model if the measured quality gain is large enough and Mac runtime remains acceptable. A user downloading multiple full models remains disqualified before this table is scored.

Exact-Mac fallback overhead is small when only one selected adapter is loaded: the 63.0 MiB LoRA added 79.0 MiB idle RSS and reached readiness in 697 ms on a warm-cache probe. Two preloaded adapters added 142.6 MiB but failed inactive-adapter output isolation, so their memory result does not make simultaneous hot-swapping eligible.

At the measured Qwen size, base plus one 63.0 MiB selected adapter is about 2.75 GiB. Base plus five same-sized language adapters is about 3.00 GiB; that is the conservative five-language ranking footprint when five distinct adapters are required. A combined adapter could score smaller only after proving the same five-language quality. Five separate 2.69 GiB full models would be about 13.45 GiB and is disqualified regardless of quality. Users should normally download only the adapters they select.

All current percentages are discovery results with wide intervals. Final rows require the sealed benchmark, exact custom quantization, and exact shipped Mac measurements.
