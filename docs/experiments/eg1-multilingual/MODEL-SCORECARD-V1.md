# EG-1 Multilingual Model Scorecard V1

Status: proposed decision matrix. Discovery results are incomplete; do not use this file as a final model selection.

## Hard gates

A candidate is rejected before weighted ranking when any of these is true:

1. Users must download multiple full-size language models for multilingual polishing.
2. Polishing requires an internet connection after model or adapter download.
3. A critical S4 meaning, entity, or numerical corruption appears in the release-grade frozen benchmark.
4. English misses the paired non-inferiority gate.
5. The candidate cannot run through the exact shipped Mac runtime within an approved memory ceiling.

Allowed architectures are one universal full model or one shared full base plus small optional language adapters.

## Weighted score after hard gates

| Area | Weight | Evidence |
|---|---:|---|
| Multilingual strict-green quality | 25 | Frozen benchmark by language, blinded native review |
| Meaning, entity, and numerical safety | 15 | Frozen preservation gates and S0-S4 severity |
| English quality and non-regression | 10 | New frozen English set plus existing regression suites |
| Positive-list activation | 8 | Frozen two-item and three-to-five-item list cases |
| False-list restraint | 7 | Frozen prose, quoted, clinical, legal, and instruction traps |
| Download size | 8 | Exact signed release artifact bytes |
| Peak Mac memory | 6 | Exact shipped runtime measurement on supported Macs |
| Mac latency and throughput | 5 | Cold start, first token, and complete-edit latency |
| Mac power and thermals | 4 | Sustained on-device measurement |
| Adapter/update footprint | 2 | Exact adapter bytes and update mechanics |
| llama.cpp/runtime maturity | 4 | Exact bundled runtime compatibility and output parity |
| Training/tooling maturity | 3 | Reproducible QLoRA, merge, quantization, and conversion |
| License and maintenance risk | 3 | Commercial license, upstream cadence, model provenance |
| **Total** | **100** | |

Quality and safety therefore control 65 points. Deployment cost controls 25 points, including an 8-point download-size weight. Engineering and licensing control 10 points.

## Current discovery-only facts

| Candidate | Task-specific discovery | Approximate full download | Adapter | Status |
|---|---|---:|---:|---|
| Current EG-1 / Qwen3-4B | Russian shipped prompt: independent strict 8/16 when list-command leakage fails cleanup | Q5 2.69 GiB | 126.1 MiB | Baseline |
| Qwen multilingual low-dose smoke | Russian independent strict 9/16; trades one damaging case for another | Custom GGUF not built | about 137 MiB including metadata | Reject low-dose recipe as finalist |
| Gemma multilingual low-dose smoke + list-v2 | Russian shipped-prompt independent strict 14/16 vs current 8/16; 56-case meaning damage 2 vs current 8; fresh list shape 82/100 intended count with 1/100 false lists, semantic audit pending | Q5 5.37 GiB; Q6 5.79 GiB; Q8 7.48 GiB | about 171 MiB including metadata | Reject exact checkpoint: Q5/Q6/Q8 all showed development meaning or scope damage |
| Prompt-aligned Gemma multilingual smoke + list-v2 | Russian strict 14/16 vs current list-v2 6/16, but English two-item strict stayed 4/20 and introduced one medical timing loss; fresh list shape regressed to 63/100 intended count | Not converted after BF16 hard stop | about 171 MiB including metadata | Reject exact recipe; keep Russian training signal |
| Untouched Gemma 4 E4B | Russian strict prompt: strong grammar and lower observed damage | Registry Q4 4.97 GiB | none | Base reference |
| Historical English-tuned Gemma 4 E4B | Russian independent strict 12/16; learned lists but retained filler/number failures | Custom GGUF not built | about 140 MiB | Evidence for multilingual Gemma experiment |
| Untouched Qwen3.5-4B | Russian strict prompt: independent strict 6/16 | Registry Q5 2.93 GiB | none | Hard-stopped first lane |
| Ministral 3 3B | Not yet run task-specific benchmark | Registry Q5 2.30 GiB | none | Research backlog |

The size column can change rank, but it cannot rescue unsafe or low-quality output. Conversely, one 5-8 GiB universal model can beat a 2.69 GiB model if the measured quality gain is large enough and Mac runtime remains acceptable. A user downloading multiple full models remains disqualified before this table is scored.

All current percentages are discovery results with wide intervals. Final rows require the sealed benchmark, exact custom quantization, and exact shipped Mac measurements.
