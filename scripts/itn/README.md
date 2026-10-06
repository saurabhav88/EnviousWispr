# Language data for the inverse text normalizer (#1677)

Developer notes for `scripts/itn/`. This directory turns pinned public sources, reviewed refusal data and declared syntax data into eight committed Swift data files. The language route reads them for the languages `LanguageRuleRegistry.production` registers (German, French, Spanish, Italian, Portuguese, Dutch and Polish); bundled third-party notices carry the CLDR and NeMo attribution.

## What is here

| Path | Role |
|---|---|
| `generate.py` | Offline generator. Reads the pinned files listed in `manifest.json`, `refusals/de.json` and `review-data.schema.json`, and takes the one refusal-hash definition from `validate-review-data.py`. It reads no corpus file. Writes eight files. |
| `manifest.json` | Every source: upstream repo, tag, commit, path, SHA-256, license and license hash (a source with `language` other than `de` feeds only its own output); plus the declared ordinal, phone-prefix, number-style, phone-trigger, clock-idiom (per language) and hour-first clock extractions. |
| `sources/cldr/`, `sources/nemo/` | The pinned upstream bytes and their license texts. |
| `refusals/de.json` | Reviewed and pending refusal entries. Only reviewed entries with a bound version, review reference and semantic hash may be lowered. |
| `review-data.schema.json`, `validate-review-data.py` | Well-formedness checks for the expectation rows and refusals. |
| `corpus/` | Frozen German expectation rows: development, controls and acceptance (holdout). |
| `tests/` | Generator tests (`test_generate.py`) and validator tests (`test_review_data.py`). |

## Commands

```text
python3 scripts/itn/generate.py --check        # regenerate in a temp dir, byte-compare all eight outputs
python3 scripts/itn/generate.py                # validate every input, then write the committed outputs
python3 scripts/itn/generate.py --inventory    # print the source-to-output inventory
python3 -m unittest discover -s scripts/itn/tests -p 'test_generate.py'
```

CI (`build-check` in `.github/workflows/pr-check.yml`, step "Language data generator") runs the `--check` line and the `test_generate.py` line. Both read only files in the checkout and make no network request.

Do not run these in CI or as a routine check:

- `generate.py --refresh` downloads the pinned URLs and verifies their hashes. It is the only network path.
- `generate.py --self-test`, discovery that includes `test_review_data.py`, and `validate-review-data.py` with or without `--frozen` read the acceptance corpus. Keep them out of routine and CI checks while ordinal acceptance content is reserved.

## The eight outputs

All under `Sources/EnviousWisprPostProcessing/Generated/`, built together: all eight are validated before any is written, and `--check` verifies all eight.

- `GermanNumberData.swift`: German number words (zero, units, teens, tens, scale words) and the bounded ordinal forms.
- `DutchNumberData.swift`: the Dutch cardinal lexicon (0 to 19, the stressed `één`, the tens, the compound prefixes `eenen` to `negenen`, and the article form `een`).
- `GermanPhonePrefixData.swift`: reviewed phone-prefix refusal entries.
- `GermanOrdinalData.swift`: reviewed ordinal refusal entries.
- `GermanNumberStyleData.swift`: German number-style data (units, postcode labels, street suffixes).
- `PhoneTriggerData.swift`: the spoken plus word per language for the signed phone path.
- `ClockIdiomData.swift`: per-language minute-first clock-idiom syntax data (German, Dutch) and, for a language whose declaration requires them (German), its reviewed literal refusal entries.
- `HourFirstClockData.swift`: hour-first clock syntax data (French, Spanish, Italian, Portuguese).

Never edit a generated file by hand. Change the manifest, a source or a reviewed refusal, run `generate.py`, and commit the result.

## Sources and licenses

| Source | Pin | License |
|---|---|---|
| Unicode CLDR `common/rbnf/de.xml`, `common/rbnf/nl.xml` | `release-48-2`, commit `11299982335beb974c1c63c45265184e759c0f41` | Unicode License v3 |
| NVIDIA NeMo text-processing German number tables | `r1.2.0`, commit `7efa127d968c081793ebf11fa94dfb4257302d48` | Apache-2.0 |

Both licence texts are in `THIRD-PARTY-NOTICES.txt` (and in the copy bundled for the app's Open Source Licenses screen); `scripts/ci/gen-third-party-notices.sh --check` verifies that each component's name, version, licence and URL appear there and that the app copy matches the root file. It does not diff the licence text against `scripts/itn/sources/*/LICENSE`. Pinned CLDR rule data and NeMo TSV data are used; neither vendor's ITN implementation is embedded. Every hash is in `manifest.json`; the generator refuses a file whose bytes differ from its pin.

## Reproducibility

Normal generation and `--check` are deterministic and offline. The generator records each normalization it applies (NFC, lower-casing, soft-hyphen removal, tens times ten) and fails the run on a missing, altered, malformed or conflicting input instead of dropping it.

## Runtime ownership

Each reviewed or lexical output is read by exactly one adapter (`LanguageNumberGrammar` for both number files, `LanguagePhonePrefixRules`, `LanguageOrdinalRules`, `LanguageClockIdiomRules`; `ITNGeneratedDataTests` pins the readers), which build typed rules or throw. The passes (`LanguageNumberStylePass`, `LanguagePhonePrefixPass`, `LanguageClockIdiomPass`, `LanguageHourFirstClockPass`; `LanguageOrdinalPass` is not wired) propose edits against one immutable snapshot and the shared `LanguageTextEditor` applies them. `LanguagePassCatalog` (`InverseTextNormalizer+Language.swift`) decides which passes each registered language runs.

## What this does not establish

- **Generator integrity is not linguistic correctness.** A passing `--check` says the committed files equal what the pinned inputs produce. It does not say a German sentence converts correctly.
- **Phone prefix and clock idiom missed conversion acceptance:** neither reached 59/59 fresh conversion sentences per engine. Phone also missed the measurement's preregistered zero-added-change criterion; that does not mean every changed control was damaged. Both remain pending, not declined.
- **Ordinal is pending.** It lacks German calendar and month data, a grounded fixed-expression policy and proper-name clearance. No ordinal acceptance was measured.
- **Existing controls are regression controls.** They guided development, so they are not independent controls. The independent-control gate is unresolved.
- **The WhisperKit file runner is not the shipping backend.** It sets `wordTimestamps = false` and skips the backend's 500 ms silence padding. Results from it are indicative, not proof of shipped output.
- **Short-input latency says nothing about long input or deadline behavior.** The measured sentences were short; the longer length buckets were not measured.
- **Synthetic speech is not natural speech.** The acceptance audio came from two text-to-speech voices.

## The acceptance corpus

`corpus/de-holdout.jsonl` holds fresh conversion rows kept apart so a pass could be measured on text nobody tuned against. The phone and clock rows have now been used once to measure the first passes; they are exposed. Do not tune a pass, an expectation or a refusal against them, and do not reuse them as a development oracle. A later change needs prospective, newly frozen acceptance material. Ordinal holdout has not been used for acceptance scoring or tuning. Do not inspect it or let it guide implementation; preserve it for a mechanism frozen after its required authorities are established.

The acceptance measurement receipt and raw outputs live in the main checkout's ignored `docs/audits/`; they are not committed files.
