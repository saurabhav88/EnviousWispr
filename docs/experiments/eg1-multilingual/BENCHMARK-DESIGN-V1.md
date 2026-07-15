# EG-1 Multilingual Benchmark Design V1

Status: proposed release-grade protocol. The current Russian 16-development/8-frozen corpus and eight-case-per-language probes are discovery evidence only.

## Product architecture gate

- Allowed: one shared multilingual full model, even when it is larger than current EG-1.
- Allowed fallback: one shared full base plus small hot-swappable language LoRA adapters.
- Disqualified: any architecture requiring users to download multiple full-size language models.
- App inference remains fully offline after model or adapter download.

## Corpus matrix

Build the same stratified corpus for English, German, French, Spanish, and Russian.

| Behavior stratum | Development | Frozen |
|---|---:|---:|
| Filler removal | 10 | 20 |
| Self-correction | 10 | 20 |
| Grammar and language-specific morphology | 10 | 20 |
| Punctuation and capitalization | 10 | 20 |
| Entities, numbers, and dates | 10 | 20 |
| Names and code-switching | 10 | 20 |
| Topic shifts and longer dictation | 10 | 20 |
| Mixed behavior with two to three edits | 10 | 20 |
| Explicit two-item list | 10 | 20 |
| Scoped two-item list without a direct command | 10 | 20 |
| Natural three-to-five-item bullet list | 10 | 20 |
| Spoken ordinals requiring a numbered list | 10 | 20 |
| Two-item prose restraint trap | 10 | 20 |
| Three-plus-item prose enumeration trap | 10 | 20 |
| Quoted, clinical, legal, or instruction restraint trap | 10 | 20 |
| Clean or minimal-edit restraint | 10 | 20 |
| **Per language** | **160** | **320** |
| **Five-language total** | **800** | **1,600** |

Within each language, block cases evenly across work/admin, personal/home, technical/product, medical, and legal/financial domains. Target 80% native-original cases and 20% shared concepts independently rewritten into natural local speech.

## Separation and anti-overfitting rules

- Split by semantic and template family before any localization.
- Training, development, and frozen data cannot share templates or paraphrases.
- Exact and fuzzy-deduplicate all splits against training data and each other.
- Tune weights, prompts, decoding, and scoring only on development data.
- Hash and seal each frozen corpus before candidate experiments.
- Run frozen data only on current EG-1 and one predeclared finalist. Testing another finalist requires a new frozen version.
- The exact quantized GGUF through the shipped Mac runtime is the final authority, not FP16 output on AlienSV.
- Keep core-polish, positive-list, and false-list scoreboards separate. Do not combine them into one headline percentage.

## Scoring

A strict green requires every gate:

1. Same language.
2. Meaning preserved.
3. Requested cleanup completed.
4. Native grammar and morphology acceptable.
5. Entities and numbers preserved.
6. Correct list activation or restraint.
7. No damaging extra edits.

Report numerator, denominator, and Wilson 95% interval for strict green, language retention, meaning preservation, grammar, cleanup, positive-list success, and false-list rate. Report S0-S4 damage severity separately. Use paired bootstrap confidence intervals and exact McNemar tests for candidate-versus-current comparisons.

Use Holm-Bonferroni correction across the five primary language comparisons. Category analyses are secondary; control them with a 5% Benjamini-Hochberg false-discovery rate.

## Native review

- Before freezing: one native author and one independent native validator per language.
- Frozen outputs: two blinded native reviewers with randomized model labels.
- A third native reviewer adjudicates disagreements.
- Repeat 10% of ratings to measure consistency.
- If agreement on primary gates is below 0.70, the evaluation itself is no-go until the rubric is repaired and affected outputs are rerated.
- LLM judges and subagents may triage and audit, but cannot authorize multilingual release quality.

## Proposed release gates

For every language claimed as supported:

- Strict green: at least 285/320. Wilson lower bound is above 85%.
- Same-language and meaning preservation: at least 317/320 each.
- Positive lists: at least 72/80.
- False lists: no more than 2/80 per language and no more than 10/400 across all languages.
- Critical S4 damage: zero across all 1,600 frozen cases.

Candidate comparison gates:

- English paired non-inferiority lower bound must be above -2 percentage points.
- No target language may regress by more than 2 percentage points.
- At least two of German, French, Spanish, and Russian must improve significantly after Holm correction.
- Re-run the existing English 1,890-case and 100-positive/100-trap suites as regression checks, but label them honestly: they are not clean held-out estimates.

These thresholds are proposed defaults for the first release-grade benchmark and need founder/CTO approval before they become product policy.
