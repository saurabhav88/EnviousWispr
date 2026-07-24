# EG-1 Web-Speech Proxy Benchmark V1

Status: paused design draft. Candidate output has not been generated and no frozen rows have been selected. This is automated proxy evidence, not a human-authored or native-reviewed benchmark.

## Purpose

Build the strongest practical EG-1 benchmark available without recruiting human authors or reviewers. Every case starts from licensed public human speech. EnviousWispr's real ASR transcript becomes the polishing input; the public reference transcript anchors the speaker's content. Candidate output stays sealed until development or finalist execution is authorized.

This benchmark may rank experiments and expose regressions. It must never be described as native-human validation or as a direct estimate of real-world pass rate.

## Frozen public sources

| Source | Pinned repository revision | License | Use | Known limitation |
|---|---|---|---|---|
| [`PolyAI/minds14`](https://huggingface.co/datasets/PolyAI/minds14) | `40ce77cb32a384e4d50a568e1ec39ac804019d33` | CC-BY-4.0 | Common EN/DE/FR/ES/RU spontaneous-speech source | Real requests, but only the banking domain and no stable public speaker ID |
| [`google/fleurs`](https://huggingface.co/datasets/google/fleurs) | `70bb2e84b976b7e960aa89f1c648e09c59f894dd` | CC-BY-4.0 | Common EN/DE/FR/ES/RU broad-topic source | Read speech; production noise and spontaneous phrasing are underrepresented |
| [`facebook/voxpopuli`](https://huggingface.co/datasets/facebook/voxpopuli) | `42f01879c780b4a2e90ec0b4f616c2ece526e4f1` | CC0-1.0 plus the dataset card's additional source notice | Held-out English Type B source | Parliamentary register; no Russian configuration, so it cannot influence the five-language ranking |
| [`edinburghcstr/ami`](https://huggingface.co/datasets/edinburghcstr/ami) | `46f28f2503e2ec48f8867a84eef356c70476beab` | CC-BY-4.0 | Held-out English Type B conversational source | Mostly design meetings; utterances must be joined only within one meeting and speaker |

Common Voice is not part of V1. Its spontaneous release currently covers only EN/DE/FR among the five targets, and Mozilla asks that access occur through Mozilla Data Collective rather than mirrored copies. It can be evaluated later as a source-specific robustness panel, not silently mixed into the common ranking.

## Multilingual allocation

Each target language has exactly 160 development cases and at least 320 frozen cases.

| Role | MINDS-14 | FLEURS | Total per language |
|---|---:|---:|---:|
| Development | 80 | 80 | 160 |
| Frozen | 160 | 160 | 320 |
| Total reserved | 240 | 240 | 480 |

The same source proportions apply to EN, DE, FR, ES, and RU. A language-specific third source may form a diagnostic panel, but it cannot alter the common five-language ranking.

Whole source-text families are assigned once. A normalized reference transcript, duplicate audio ID, upstream prompt ID, or explicit source-family link places every connected row in one component. Components cannot cross training, development, frozen, or Type B roles. Where a public speaker ID exists, the whole speaker stays in one role. Where it does not, the receipt must state that speaker separation is unavailable and cluster inference by the strongest observable family instead.

Development selection may be inspected and rerun. Frozen selection uses a private seed; only its SHA-256 commitment, source counts, component counts, and artifact hashes are published before a finalist is locked. Frozen source text, ASR input, reference text, candidate output, and case-level scores remain unopened during tuning.

## Building one proxy case

1. Download the exact pinned audio and reference record into ignored local storage.
2. Record dataset revision, configuration, split, row ID/path, source-family ID, audio SHA-256, reference SHA-256, license, and attribution.
3. Run the audio through the same ASR path used by EnviousWispr. Store its runtime/model receipt and transcript hash.
4. Reject empty, wrong-language, duplicate-family, or source/reference-mismatched records before any polishing model runs.
5. Build content requirements from the public transcript: names, numbers, dates, amounts, negation, corrections, intent, and lexical anchors. Automated extraction may add requirements but may not delete source content.
6. Keep the ASR transcript as `asr_input` and the public transcript as `content_reference`. Do not pretend the public transcript is a perfect polished gold when it lacks punctuation or contains genuine speech disfluency.

## Scoring without human gold

Mechanical hard gates are primary:

- output remains in the source language;
- every protected name, identifier, number, amount, date, negation, timing, and correction survives;
- no new fact, actor, quantity, instruction, or list item appears;
- requested removals and filler cleanup occur only when the case contract permits them;
- list activation, marker type, item count, item atomicity, shared scope, and restraint behavior match the predeclared contract;
- output is nonempty, contains no wrapper/meta text, and stays within the edit budget.

Semantic proxy review uses at least three independently executed judge recipes from different model families. Outputs are arm-blind and order-randomized. A case is semantically passing only when the mechanical gates pass and the judge policy reaches its predeclared agreement threshold. Judge disagreement is a measured failure/abstention, not an invitation to hand-pick the favorable answer. Report each judge separately, the consensus, abstentions, and model-family sensitivity.

Exact-reference similarity is descriptive only. A candidate is not rewarded for copying an unpunctuated transcript, and it is not penalized merely for a safe grammatical variant.

## Automated training gold

Training data is separate from every benchmark family. For a training-only source row, generate proposed polished outputs with at least three teacher recipes from different model families plus one deterministic minimal-edit recipe. A row is exportable only when:

- all protected-content and language gates pass;
- no teacher saw benchmark candidate output;
- the selected output is supported by the predeclared teacher consensus;
- alternative teachers do not reveal unresolved meaning disagreement;
- the exact source, teachers, prompts, runtime versions, outputs, and decision are receipt-bound.

Rows with judge disagreement, ambiguous reference content, translation, factual repair, or large rewriting are discarded. They are not manually rescued after observing a candidate score.

## English Type B V2 proxy

Keep the already sealed 1,890-case category, length, tier, and trap matrix. The current source-allocation recommendation is 1,890 held-out English source units:

- 630 FLEURS train fragments from IDs excluded from every multilingual role;
- 630 VoxPopuli test fragments with gold transcripts and known speaker IDs;
- 630 AMI IHM test composites built from contiguous turns by one speaker.

One-prose cases consume one source unit. List cases may combine two to five short fragments inside that unit, but all fragments must come from the same predeclared source family; an AMI composite cannot cross meeting or speaker. The case's semantic family contains every component fragment, speaker/meeting/prompt family, and deterministic transformation-template ID. No component may appear in another benchmark or training role.

Positive-list gold is built mechanically from the reference fragments in the required order and marker style. The wrapper may add only a predeclared spoken list cue and shared scope; it may not invent item content. Restraint cases use the same source pool and matched cue families but require prose. This preserves the list-versus-restraint contrast while grounding item content in human speech.

The Type B proxy is used once on one locked finalist. If any row is opened during development, its entire connected family moves permanently to development and a same-cell reserve is activated before finalist output.

## Statistics

- Report every language and source separately before any aggregate.
- Use family-clustered intervals and paired comparisons; source fragment, speaker/chapter where available, and transformation template are clustering variables.
- Apply the predeclared multiple-language correction.
- Keep list activation, false-list rate, strict structure, content damage, critical damage, and semantic abstention separate.
- A source-specific gain cannot hide a regression in another source or language.
- Zero observed critical failures is not proof of zero risk; publish the upper confidence bound.

## Storage and release boundary

Raw audio, transcripts, private selection seeds, generated cases, and model outputs live only under ignored local `artifacts/` storage. The repository may track contracts, source metadata, licenses, hashes, scripts, aggregate receipts, and nontext case IDs. Do not mirror source datasets or publish benchmark text/audio from this work.

All EG-1 execution remains offline after the selected model files are downloaded. Internet access is used only to acquire and verify the public source datasets. Heavy ASR, teacher, or candidate runs use AlienSV when the runtime is compatible. A finalist still must pass the exact shipped Mac runtime gate.
