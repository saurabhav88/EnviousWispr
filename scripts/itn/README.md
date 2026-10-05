# German language data for the inverse text normalizer (#1677)

Developer notes for `scripts/itn/`. This directory turns pinned public sources and reviewed expectation data into four committed Swift data files. **Nothing here is reachable from dictation today:** the production registry is empty and the German passes are not called by any shipped code path. Customer behavior has not changed.

## What is here

| Path | Role |
|---|---|
| `generate.py` | Offline generator. Reads the pinned files listed in `manifest.json`, `refusals/de.json` and `review-data.schema.json`, and takes the one refusal-hash definition from `validate-review-data.py`. It reads no corpus file. Writes four files. |
| `manifest.json` | Every source: upstream repo, tag, commit, path, SHA-256, license and license hash; plus the declared ordinal, phone-prefix and clock-idiom extractions. |
| `sources/cldr/`, `sources/nemo/` | The pinned upstream bytes and their license texts. |
| `refusals/de.json` | Reviewed refusal entries (cases that must stay as written), each with a semantic hash. |
| `review-data.schema.json`, `validate-review-data.py` | Well-formedness checks for the expectation rows and refusals. |
| `corpus/` | Frozen German expectation rows: development, controls and acceptance (holdout). |
| `tests/` | Generator tests (`test_generate.py`) and validator tests (`test_review_data.py`). |

## Commands

```text
python3 scripts/itn/generate.py --check        # regenerate in a temp dir, byte-compare all four outputs
python3 scripts/itn/generate.py                # validate every input, then write the committed outputs
python3 scripts/itn/generate.py --inventory    # print the source-to-output inventory
python3 -m unittest discover -s scripts/itn/tests -p 'test_generate.py'
```

CI (`build-check` in `.github/workflows/pr-check.yml`, step "Language data generator") runs the `--check` line and the `test_generate.py` line. Both read only files in the checkout and make no network request.

Do not run these in CI or as a routine check:

- `generate.py --refresh` downloads the pinned URLs and verifies their hashes. It is the only network path.
- `generate.py --self-test` and `validate-review-data.py --frozen` read the full corpus, including the acceptance file. See "The acceptance corpus" below.

## The four outputs

All under `Sources/EnviousWisprPostProcessing/Generated/`, built together: all four are validated before any is written, and `--check` verifies all four.

- `GermanNumberData.swift`: number words (zero, units, teens, tens, scale words) and the bounded ordinal forms.
- `GermanPhonePrefixData.swift`: reviewed phone-prefix refusal entries.
- `GermanOrdinalData.swift`: reviewed ordinal refusal entries.
- `GermanClockIdiomData.swift`: clock-idiom syntax data and reviewed literal refusal entries.

Never edit a generated file by hand. Change the manifest, a source or a reviewed refusal, run `generate.py`, and commit the result.

## Sources and licenses

| Source | Pin | License |
|---|---|---|
| Unicode CLDR `common/rbnf/de.xml` | `release-48-2`, commit `11299982335beb974c1c63c45265184e759c0f41` | Unicode License v3 |
| NVIDIA NeMo text-processing German number tables | `r1.2.0`, commit `7efa127d968c081793ebf11fa94dfb4257302d48` | Apache-2.0 |

Both texts and their notices are in `THIRD-PARTY-NOTICES.txt`; `scripts/ci/gen-third-party-notices.sh --check` keeps them in sync. Only lexical data is used. Every hash is in `manifest.json`; the generator refuses a file whose bytes differ from its pin.

## Reproducibility

Normal generation and `--check` are deterministic and offline. The generator records each normalization it applies (NFC, lower-casing, soft-hyphen removal, tens times ten) and fails the run on a missing, altered, malformed or conflicting input instead of dropping it.

## Runtime ownership

The generated data is read by exactly one adapter per output (`LanguageNumberGrammar`, `LanguagePhonePrefixRules`, `LanguageOrdinalRules`, `LanguageClockIdiomRules`), which build typed rules or throw. The passes (`LanguagePhonePrefixPass`, `LanguageOrdinalPass`, `LanguageClockIdiomPass`) propose edits against one immutable snapshot and the shared `LanguageTextEditor` applies them. `LanguageRuleRegistry.production` is empty, so nothing registers a German rule set and no pass runs in the app. Registering a language is a separate, gated change.

## What this does not establish

- **Generator integrity is not linguistic correctness.** A passing `--check` says the committed files equal what the pinned inputs produce. It does not say a German sentence converts correctly.
- **Phone prefix and clock idiom missed the acceptance bar** (59 of 59 fresh conversions per engine, zero added change). Both stay pending, not declined.
- **Ordinal is pending.** It lacks German calendar and month data, a grounded fixed-expression policy and proper-name clearance. No ordinal acceptance was measured.
- **Existing controls are regression controls.** They guided development, so they are not independent controls. The independent-control gate is unresolved.
- **The WhisperKit file runner is not the shipping backend.** It sets `wordTimestamps = false` and skips the backend's 500 ms silence padding. Results from it are indicative, not proof of shipped output.
- **Short-input latency says nothing about long input or deadline behavior.** The measured sentences were short; the longer length buckets were not measured.
- **Synthetic speech is not natural speech.** The acceptance audio came from two text-to-speech voices.

## The acceptance corpus

`corpus/de-holdout.jsonl` holds fresh conversion rows kept apart so a pass could be measured on text nobody tuned against. The phone and clock rows have now been used once to measure the first passes; they are exposed. Do not tune a pass, an expectation or a refusal against them, and do not reuse them as a development oracle. A later change needs prospective, newly frozen acceptance material. The ordinal rows have not been read by any code, test or generator; keep it that way until their missing authorities exist.

The acceptance measurement receipt and raw outputs are kept outside the repository (ignored `docs/audits/`), not as tracked files.
