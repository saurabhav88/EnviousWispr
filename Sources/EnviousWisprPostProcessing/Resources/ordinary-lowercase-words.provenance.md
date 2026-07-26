# ordinary-lowercase-words.txt — provenance

Companion record for `ordinary-lowercase-words.txt`, the lexicon that decides
whether a dictation's capitalised first word may be lowercased when the text is
inserted into the middle of an existing sentence. Issue #1785, gate 1.

## What it is and who owns it

Authored by Envious Labs for EnviousWispr. No third-party word list was copied,
adapted, or redistributed, so there is no upstream license to satisfy and no
attribution obligation. It is a product allowlist, not a spell-checker result
and not an operating-system dictionary lookup, so the same input produces the
same output on every machine and in every locale.

## How it was built

Grammatically, from closed-class English (pronouns, determiners, conjunctions,
prepositions, auxiliaries, wh-words, negation) plus open-class categories that
genuinely open sentences (adverbs, adjectives, participles and gerunds,
imperative verbs, generic discourse nouns, interjections, contractions).

It was deliberately NOT built by ranking one speaker's dictation openers and
taking the top N. That method fits a list to whoever recorded the corpus: it
would carry their slang and their tools while missing ordinary words they happen
not to say. The corpus below validates the finished list. It never generated it.

| Category | Members |
|---|---|
| pronouns | 53 |
| determiners | 30 |
| conjunctions | 40 |
| prepositions | 55 |
| auxiliaries | 24 |
| wh words | 6 |
| negation and particles | 4 |
| adjectives | 135 |
| participles and gerunds | 91 |
| adverbs | 128 |
| interjections and openers | 38 |
| verbs imperative | 105 |
| common nouns | 58 |
| quantifiers and ordinals | 15 |
| contractions | 42 |

A word can belong to more than one category, so the column sums above the total.
Distinct entries: **799**.

CORRECTED 2026-07-26 (Codex review r7): `general` was removed. It is a military
and civil TITLE as well as an ordinary word, so `According to witnesses, General
Smith agreed.` was recased to `general Smith`. Thirty-three rank and title
homographs were audited when it was found — `general` was the only one present —
and it now sits in the exclusion class so a regeneration cannot reintroduce it.
The measured 92.7% recall predates this removal and was not re-run; one entry out
of 800 cannot move it materially, and the direction is conservative.
`sha256` of `ordinary-lowercase-words.txt`: `e1965f13834fa3b4e85a460c520f4c5de535ea975a1afcc7e3b859337d30b944`.

## The exclusion class

A word qualifies only if lowercasing a CAPITALISED occurrence of it mid-sentence
is safe. That fails for any ordinary word that is also a name, brand, product,
programming language, nationality, place, weekday, month, or the first-person
pronoun, because the visible damage is a person's name or a product rendered in
lowercase. Those axes are enumerated in
`Tests/EnviousWisprTests/PostProcessing/OrdinaryLowercaseExclusionClass.swift`
(457 entries) and a test fails if any of them reaches this lexicon.
Overlap between the two sets is currently zero.

Under-coverage is safe by construction: a word absent from the lexicon keeps its
capital, which is exactly today's behaviour. Over-coverage is the only direction
that can produce a visible mistake, so the list is built to fail safe.

## Normalisation applied before lookup

1. Unicode right single quote `U+2019` folds to ASCII apostrophe `U+0027`.
2. The token is lowercased with the invariant, non-locale mapping.
3. Surrounding punctuation and quotation marks are trimmed.

Entries are ASCII lowercase letters with at most one internal apostrophe. One
entry per line. `#` begins a comment; blank lines are ignored.

## Measured coverage

Metric, from plan §13a: eligible occurrences whose lowercase spelling is in this
lexicon, divided by all case-eligible occurrences. "Eligible" means the first
token of a delivered dictation survived guards 1 to 6, which reject before the
lexicon is ever consulted.

| First-token disposition | Count | Share of corpus |
|---|---|---|
| eligible hit | 2156 | 80.4% |
| guard5 pronoun I | 315 | 11.8% |
| eligible miss | 171 | 6.4% |
| guard1 already lower | 26 | 1.0% |
| guard3 mixed case or acronym | 7 | 0.3% |
| guard6 always capitalized | 5 | 0.2% |

- Eligible denominator: **2327**
- **Eligible-token recall: 92.7%** against a ship bar of greater than 90%.
- Next 25 approvable uncovered words would add under 2 percentage points, so the
  §13a stopping rule ("stop when another 25 approved words gain less than five
  percentage points") is satisfied and the lexicon stops here.

## Pinned corpus

Real delivered dictations recovered from the local debug log, deduplicated, with
fixed test-harness sentences removed. The corpus is pinned because the source log
rotates; an unpinned measurement is not reproducible.

| Source | Bytes | sha256 (truncated) | Records |
|---|---|---|---|
| `app.3.log` | 10,485,796 | `914575f3f41b77baff50ac556e86d3a9` | 550 |
| `app.2.log` | 10,485,840 | `d2e1930c6686b3229e846b28b07fb522` | 859 |
| `app.1.log` | 10,485,944 | `a0977c41e6f3d201b7b9e6edeb7bb217` | 823 |
| `app.log` | 8,928,272 | `29e1b7743712144de4682adce9838d70` | 582 |

- Raw records: 2814
- Test-harness sentences removed: 24
- Exact duplicates dropped: 110
- **Corpus records: 2680**
- Corpus `sha256`: `f2152dd25f35be3e033b7cc0856790a4f949e10df4c679cbab99d7722eaa28ef`

The corpus contains dictated content and therefore never leaves the machine and
is never committed. It lives beside the measurement scripts under the gitignored
`docs/` tree. Only the counts and checksums above travel into the repository.

## Known limits, stated rather than discovered later

- **One speaker.** The validating corpus is a single person's dictation. The
  lexicon is authored grammatically to blunt this, but recall for another user
  will differ. Recall is a floor indicator, not a guarantee.
- **English only.** Non-English first words are never in the lexicon, so they
  keep their capitalisation. Six such records appear in the corpus.
- **No arbitrary common nouns.** Generic discourse nouns are included; ordinary
  object nouns such as "store" are not, because coverage there buys little and
  the proper-noun collision risk rises. Those words are simply left alone.
- **Names win ties.** Where a word is both ordinary and a name, the name wins and
  the word is excluded, even when the ordinary reading is far more common. `will`
  is the clearest example.

## Reproducing every number here

Four steps, in order: pin the corpus from the rotating debug log and record each
source file's checksum; build the lexicon and the exclusion class from the
category lists; run the gate checks, which fail closed before printing any
headline number; regenerate this file from the results.

The scripts that perform those steps are working artifacts kept beside the issue
plan under the gitignored `docs/` tree, so they are not part of a fresh clone.
The description above is the authority; the scripts are the convenience.

## When this file must be updated

Any change to `ordinary-lowercase-words.txt` changes its checksum and invalidates
the recall figure above. Regenerate both in the same change. Re-pinning the
corpus deliberately changes the published numbers and must update them in the
same change too, rather than leaving a figure that no longer traces to a corpus.
