# Seam joining — research complete, ready to plan the build

Research phase for #1785, 2026-07-25. Everything below is measured, not estimated.
Nothing has been wired into the app.

## The problem, restated

A user dictates in several recordings. Each is transcribed independently, so the
transcriber capitalises the first word and usually appends a full stop. The
recordings land one after another at the cursor and read as broken:

    "I mean the ideal outcome." + "would be recognizing when two sentences..."
    pasted:  I mean the ideal outcome. Would be recognizing when...
    wanted:  I mean the ideal outcome would be recognizing when...

Both halves of the defect are ours to fix. Measured from the founder's real log:
the transcriber capitalises most resumed recordings, and **our own polish step
capitalises the rest** ("disjointed" -> "Disjointed", "is run" -> "Is run").

## What shipped as the answer

A **seam classifier**: a multilingual encoder reads a window either side of the
join and emits ONE label. Deterministic code applies the edit.

    KEEP · MERGE_SPACE · MERGE_COMMA

The model never emits text. That is the load-bearing property — it is why this
cannot delete words the way EG-1 did ("I mean" vanished) or rewrite them the way
GECToR did ("is closed" -> "was closed").

**Winning configuration:** XLM-RoBERTa base, square-root language-balanced
sampling, checkpoint selected by fewest wrong merges, fp16 weights.

| metric | measured |
|---|---|
| accuracy, trained languages (EN/DE/RU, 879 rows) | 99.8% |
| accuracy, ZERO-SHOT languages (ES/FR/IT/PT/PL/NL, 330 rows) | 97.9% |
| wrong merges (silent damage) across all 1,209 rows | **0** |
| latency, single item, on the founder's M4 Mac | 13.6 ms median, 14.2 ms p95 |
| download size | 573 MB (fp16) |
| provider dependence | none — runs for every user |

Model: `model/seam-fp16/`. All variants also on the rig at `C:\Users\saura\seam-*`.

## Ranked alternatives, all measured on the same data

| approach | trained-lang acc | unseen-lang acc | wrong merges | note |
|---|---|---|---|---|
| **classifier, sqrt-balanced** | **99.4%** | **97.7%** | 0.3 + 1.7 | winner |
| classifier, no balancing | 98.8% | 96.4% | 1.3 + 2.0 | Russian unstable |
| classifier, full balancing | 98.7% | 94.3% | 1.7 + 3.7 | overfits small langs |
| classifier on mmBERT-small | 98.0% | **81.2%** | 2.3 + 9.0 | collapses zero-shot |
| GECToR (Grammarly), fine-tuned | 64.1% seam | — | 68 | run-ons; edits far from seam |
| GECToR off-the-shelf | 22.8% seam | — | — | trained on essay errors |
| deterministic rules only | 36% seam / 78% usable | — | 0 | safe floor, no download |
| today (do nothing) | 14% seam | — | 0 | baseline |

## Findings that will save the next session time

**Aggregate metrics hide the decision.** mmBERT-small looked competitive on
trained languages (98.0%) and collapsed on unseen ones (81.2%). English is 68% of
the trained test set, so ALWAYS read per-language columns. `compare_models.py`
prints them.

**Wrong merges and accuracy do not move together.** mmBERT-base had 2 wrong
merges at epoch 2 and 14 at epoch 3 while accuracy moved 99.1% -> 98.1%.
`train_seam.py` selects on wrong merges for this reason. Do not revert it.

**Russian instability was a data-mix problem, not a model problem.** Russian was
800 of 11,264 rows (7%) and swung 91.9-98.8% across seeds. Balanced sampling
fixed it outright. **We did not need more Russian data.** Square-root balancing
(`--balance-power 0.5`) beats both full balancing and none.

**Zero-shot transfer works.** 97.9% on six languages with zero training examples.
Expanding languages likely needs a validation set per language, not a data
generation project.

**Single-seed results cannot separate two models.** Wrong merges swung 1 -> 3 ->
19 across epochs of one run. Everything reported here is 3 seeds.

**The glue code mattered more than the model choice.** Blind LLM grading moved the
classifier 73% -> 89% -> 100% usable across three rounds, entirely by fixing
`arms.py`: a missing full stop when keeping a boundary, a doubled comma, "A"
treated as an acronym, a surviving pause-comma on a space-merge, and the
speaker's repeated word at the seam. None of these were model errors.

## Build phase opened — 2026-07-25

Epic **#1790**. Plan: `docs/feature-requests/issue-1790-2026-07-25-seam-joining.md`.
Most of the questions below are now answered; the answers are recorded here so
this file stays the single research record.

**Core ML conversion, measured** (`code/convert_coreml.py`, reference re-scored
on the M4 at the same fixed shape):

| variant | size | trained acc | wrong | unseen acc | wrong | agreement | median ms |
|---|---|---|---|---|---|---|---|
| PyTorch reference | 1.1 GB | 99.8% | 0 | 97.9% | 0 | — | 13.6 |
| Core ML fp16 | 557 MB | 99.8% | 0 | 97.9% | 0 | 100.0% | 2.7 |
| **Core ML int8** | **279 MB** | **99.8%** | **0** | **97.6%** | **0** | **99.9%** | **2.7** |
| Core ML 4-bit | 139 MB | 96.7% | **9** | 91.8% | **2** | 95.3% | 2.4 |

Eight-bit ships. Four-bit is **measured and rejected** — it breaks the one
disqualifying metric. macOS 14 target accepted, so no Sonoma exclusion.
279 MB is under the 512 MB single-object CDN ceiling, so no sharding.
Artifact kept at `model/seam-coreml-int8.mlpackage`.

**Conversion gotcha, four failures of one class.** transformers 5's attention
and masking code emits ops the converter cannot take: `new_ones`, a vectorised
higher-order op in mask expansion, a TRAINING-dialect exported program, and a
boolean mask combine. Do not patch these one at a time. Present the weights to
transformers 4.49 through `prepare_legacy_dir()`, which writes corrected
metadata and symlinks the untouched weights. Pinned env
`~/.cache/seam-convert-venv`: torch 2.7.1, transformers 4.49.0, coremltools 9.0.
The `model/seam-legacy-view/` directory is that shim, not a second model.

**Founder decisions 2026-07-25.** Size is not a blocker; a mandatory download
alongside the speech model at setup is fine, where "mandatory" means always
fetched and never setup-blocking. The lexicon approach is rejected — the model
takes over the casing decision, with labels derived free from the uncorrupted
source text. New epic; #1785 keeps its spacing and paste-safety half.

### Still open

1. **Everything is synthetic corruption.** No test yet against the live
   transcriber. Founder's own 12 real seams pass 12/12, but that is a small
   sample. Phase D gate.
2. **Tokenizer parity is unverified.** ArgmaxCore ships Unigram, a Precompiled
   normalizer and a Metaspace pretokenizer, which is everything XLM-RoBERTa
   needs, but fidelity against our real inputs is untested. First task of the
   plan's Phase B.
3. **Where it runs is settled, and it is NOT the always-on layer.** The seam
   decision needs the text already at the cursor, which only exists at delivery,
   after polish — and our own polish step is one of the two sources of the
   spurious capital. It extends `CursorInsertionRepair`, not
   `TextProcessingRunner`. Correcting the earlier note here.
4. **Vocabulary trimming** is the only remaining size lever now that four-bit is
   rejected. Costs zero-shot transfer. Not planned.

## Reproducing

    # rig (native Windows venv, transformers 5.14.1, gector 1.2.0 installed)
    ssh saura@aliensv
    python train_seam.py --model FacebookAI/xlm-roberta-base --epochs 3 \
        --seed 11 --balance-power 0.5 --out seam-sqrt-s11
    python compare_models.py seam-sqrt      # per-language
    python final_bakeoff.py                 # both test sets, ranked

    # Mac (transformers 5.14.1)
    python quantise_and_measure.py          # fp16 + real Mac latency

Rig gotchas: `set "VAR=value"` quoted or the trailing space corrupts it;
`PYTHONUTF8=1` required or Cyrillic crashes the loader; transformers 5 can train
GECToR but cannot load its checkpoints.

## Data provenance

`data/seam_train.jsonl` — 11,264 pairs. English from the founder's own dictations
(EG-1 training corpus + private corpus), split at natural pause points and
corrupted to match measured transcriber behaviour. German and Russian generated
by ChatGPT (prompt in `../chatgpt-data-prompt.md`).

`data/seam_test.jsonl` — 879 held out. English from the founder's independent
1,000-case file; German and Russian carved out of the generated sets with an
explicit leakage check (121 rows removed for sharing a first half with training).

`data/seam_zeroshot.jsonl` — 330 rows, six languages never trained on.

**Contains the founder's real dictation content. Gitignored. Never commit.**
