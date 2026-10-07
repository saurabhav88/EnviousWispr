# Settings search vocabulary (#3482)

`Sources/EnviousWisprAppKit/Resources/SettingsSearchVocabulary.json` holds, for every searchable Settings Map id and each of the 32 declared languages, the words and everyday phrases people type for that place, plus each language's filler (stop) list and protected markers. The schema authority is `SettingsSearchVocabulary.validate` in `Sources/EnviousWisprAppKit/Views/Settings/SettingsSearchVocabulary.swift`; the required `build-and-test` lane runs it through `SettingsSearchVocabularyTests` and `SettingsSearchCatalogTests`. A new, renamed or removed searchable id fails those tests and names the draft command.

## Draft a new place

```
scripts/settings-map/draft-vocabulary.sh <id>
```

It exports the id's metadata from the compiled map (`SettingsMapExportTests`, opt-in), refuses unknown, structural and exempt ids before any model runs, then drafts in a fresh isolated Codex session and writes an UNREVIEWED draft with a hash receipt to `build/settings-map-drafts/<id>-<time>/`. It takes minutes (it builds the test target); from Claude Code, run it in the background. `--self-test` checks its refusals, isolation and receipts with a stubbed exporter and launcher.

The Codex session runs from an empty folder outside every repository, with a private `CODEX_HOME` holding only the auth link, web search off, a read-only sandbox, `--ignore-rules` and `--ephemeral`. Because the folder is outside the EnviousWispr checkout, `codex-run`'s EnviousWispr self-review attestation does not apply: the session reads no repository content and reviews nothing.

### Manual equivalent

1. `TEST_RUNNER_EW_SETTINGS_MAP_EXPORT=/tmp/export.json TEST_RUNNER_EW_SETTINGS_MAP_EXPORT_ID=<id> scripts/xcode-test.sh --configuration Debug --filter EnviousWisprTests/SettingsMapExportTests`, and confirm `/tmp/export.json` holds exactly that id.
2. `cat scripts/settings-map/draft-brief.md /tmp/export.json > /tmp/prompt.md`.
3. Make an empty folder outside any repository and a `CODEX_HOME` folder containing only a symlink `auth.json -> ~/.codex/auth.json`. From the empty folder, pipe `/tmp/prompt.md` into `CODEX_HOME=<home> ~/.claude/bin/codex-run <out> -c tools.web_search=false exec --sandbox read-only --skip-git-repo-check --ignore-rules --ephemeral -C <empty folder>`.
4. The answer at `<out>.last` is an unreviewed draft.

## Review and adopt

1. Review the draft: accuracy against the real control (Codex, with repo access), naturalness per language (a fresh Codex session per language; German also through the GPT and Gemini council, which needs founder approval for the spend). Save the reviewed result as `scripts/settings-map/receipts/additions/<id>.json` in the shape `{"id": "<id>", "blocks": {"<language>": {"title"?, "words", "phrases"}, ...}}` with all 32 languages, next to the review transcript.
2. Record it in `scripts/settings-map/receipts/reviewed-edits.json`. The builder reconciles every id into exactly one group and stops on anything else:
   - a retained id (in the Phase 0 source and still mapped): reviewed word, phrase or translated-title changes go under `blocks.<id>.<language>` (English and German titles come from the interface and are not edited here);
   - an added id (mapped, not in the Phase 0 source): `added.<id>` with `blocks` for all 32 languages, `review` (the path of that JSON under `receipts/`) and `reviewSHA256` (its SHA-256). The verifier and the tests require the file to stay under `receipts/`, match the hash, name the id and hold exactly the adopted blocks;
   - a retired id (in the Phase 0 source, no longer mapped or exempt): `retired.<id>` with a nonblank reason;
   - a renamed id is a retirement plus an addition; its new blocks need their own review.
3. Rebuild: `scripts/settings-map/build-vocabulary.py --source <multilingual-v2.json> --inventory Tests/Fixtures/settings-map/inventory.json --edits scripts/settings-map/receipts/reviewed-edits.json --out Sources/EnviousWisprAppKit/Resources/SettingsSearchVocabulary.json`. It prints the resource hash and each language's content hash. `--self-test` checks the reconciliation rules on a tiny source.
4. Update `scripts/settings-map/receipts/vocabulary-review.json`: the new review under each language it covers, the added id under `addedIDs` with its review path, and the printed hashes. The tests compare every language's hash with the shipped content and require each added id's review file, so content without a matching receipt fails.
   Also set `reviewedSourceSHA256.<id>` for every id whose blocks were reviewed: the test `reviewsMatchTheCurrentEnglish` prints the value. It fails for any id whose English title or description changed since its translations were reviewed, so renaming a setting asks for exactly that id's re-review.
5. `scripts/settings-map/verify-phase0.py` (usage in its header) must still report every language OK: retained blocks equal their Phase 0 review plus reviewed edits, added blocks equal their own reviewed blocks.

## Receipts

`receipts/vocabulary-review.json` binds the resource bytes and each language's content to its reviews. `receipts/phase0/` keeps the Phase 0 review outputs and briefs, `receipts/lists/` the stop-list and marker reviews, `receipts/council/` the German council prompts and digest, `receipts/additions/` reviews of ids added after Phase 0 (raw council answers stay in the council's encrypted history).

## Export and reference

`reference/settings-map.json` is the full export (every node in map order, its owned copy in English and German, runtime resolvers named, the validated vocabulary and fingerprints of the map metadata, the interface catalog and the vocabulary). `reference/settings-map.md` is rendered from it by `render-reference.py`. Both are generated:

- `scripts/settings-map/export.sh` extracts afresh through `SettingsMapExportTests` (it builds the test target), renders, and replaces both files.
- `scripts/settings-map/export.sh --check` does the same into a staging folder and fails if either committed file is missing or stale; it never writes them.
- `scripts/settings-map/export.sh --from <export.json> [--check]` renders an export another run already wrote. CI uses it after the Release test run, which executes the export test with `TEST_RUNNER_EW_SETTINGS_MAP_EXPORT` set (`.github/workflows/pr-check.yml`, step "Check the Settings Map export is in sync").
- `SettingsMapExportSyncTests` also compares the committed JSON with a fresh in-process export in every test run.
- `--self-test` on `export.sh`, `render-reference.py` and `publish-catalog.py` runs offline.

## Product catalog publication

`scripts/settings-map/publish-catalog.py --catalog ~/.claude/knowledge/enviouswispr --revision <sha>` reads the export and `catalog-surfaces.json` committed at `<sha>`. `catalog-surfaces.json` is the one mapping from map ids to catalog `ui_surface` slugs: several ids may share one physical control (a picker and its choices), and `newSurfaces` declares the few controls the catalog had not listed. The tool refuses an unmapped or unknown id, a slug that is not an existing macOS surface, and any change outside what it owns. Without `--write` it applies the migration to a disposable copy, compares every table before and after, and runs the catalog's `rebuild.sh` on a copied folder. With `--write` (only at the session wind-down catalog step) it writes `data/NNN-macos-settings-map-<date>.sql` and rebuilds. It owns the `ui-map-<slug>` evidence rows and the new surfaces; it updates no other surface and no setting link.

## Meaning assets (Settings search, PR B)

`Sources/EnviousWispr/Resources/SettingsSearchMeaning/` holds what the meaning pass needs on the Mac: `SettingsSearchEncoder.mlmodelc` (the fine-tuned multilingual-e5-small, 6-bit palettized, precompiled, CPU only), `tokenizer.unigram` (its tokenizer in a compact file, read by `SettingsSearchUnigramTokenizer`), `place-vectors.bin` / `place-vectors.json` (one float16 vector per distinct place text, 24,339 rows for 246 places in 32 languages) and `manifest.json` (hashes, provenance, reference vectors). The folder rides the APP target as a folder reference in `Project.swift` and is read through `Bundle.main`, like the output classifier: AppKit's own resource glob cannot place a Core ML model. `.gitignore` re-includes it (the broad `*.bin` rule); the largest file, the encoder's `weights/weight.bin`, is about 88 MB, under GitHub's 100 MB limit, and every regeneration of it adds that much to the repository history.

`SettingsSearchMeaningAssets.pinnedManifestSHA256` pins `manifest.json`, which pins every other file. `SettingsSearchMeaningAssetsTests` recomputes them and prints the new pin when the manifest changes.

**A new or changed setting needs new vectors.** After the map node and the reviewed vocabulary are in (the steps above) and `scripts/settings-map/export.sh` has refreshed `reference/settings-map.json`:

1. `TEST_RUNNER_EW_SETTINGS_PLACE_TEXTS=/tmp/place-texts.json scripts/xcode-test.sh --filter EnviousWisprTests/SettingsSearchPlaceTextsExportTests` writes the texts to embed. The Swift recipe (`SettingsSearchPlaceTexts`, a test helper) is the only owner of which texts those are.
2. `python3 scripts/settings-map/meaning-assets.py place-vectors --texts /tmp/place-texts.json --model <fine-tuned model dir>` embeds them with the full-quality model (`passage: ` prefix). Needs sentence-transformers; the Phase 0 bench's `.venv` had 6.1.0, and the fine-tuned model is the bench's `models/finetuned/e5small-v2` (weights sha256 in the manifest).
3. Set `pinnedManifestSHA256` to the value the test prints.

`SettingsSearchMeaningAssetsTests` fails, naming this procedure, when the committed vectors were built from another map, vocabulary, interface catalog or text recipe. `meaning-assets.py check` verifies the files against the manifest without Xcode; `meaning-assets.py --self-test` runs offline.

The encoder and tokenizer change only with the model: `meaning-assets.py encoder --package <Encoder.mlpackage> --tokenizer-dir <hf-tokenizer dir>` compiles the package with `xcrun coremlcompiler` (macOS 14 target), builds `tokenizer.unigram` from the Hugging Face `tokenizer.json` (refusing any pipeline other than the XLM-R one the Swift tokenizer implements) and records reference vectors from Python Core ML. The Swift tokenizer is checked against the Hugging Face ids by `Tests/Fixtures/settings-search/meaning-tokenizer-parity.json`, written by `meaning-tokenizer-fixture.py` (regenerate it when the place texts change: the test says so).

Why the tokenizer is in-repo: ArgmaxOSS, the only tokenizer library the app links, segments this vocabulary differently from Hugging Face ("query:" gets ids 944 and 1294 instead of 41 and 1294), which moves every search vector (cosine 0.84 to 0.95 against the reference). The Hugging Face Swift package would add a network-capable Hub client and seven more packages to the app. The load-time self-test (`SettingsSearchMeaningWorker`) compares the real encoder with the manifest's reference vectors, so a tokenizer or model that disagrees turns the meaning pass off instead of ranking wrongly.

Known limit: the Hugging Face normalizer groups characters into grapheme clusters with the Unicode version of its Rust build, Swift with the OS's. They can differ for characters assigned in recent Unicode versions that a keyboard cannot type; the parity corpus draws only Unicode 15.1 assigned characters.

## Notes for the search matcher (PR B)

- Stop words and markers are compared after folding (`SettingsSearchVocabulary.fold`: case, diacritics, ß as ss). The Phase 0 Python builder folded with NFKD and mark removal, which differs for some scripts (Hangul, kana voicing, Greek final sigma); the matcher owns runtime folding and must test it per script.
- Each language's markers are removed from its own stop list here. Protecting markers and setting terms across the union of active languages is the matcher's job.
- Chinese, Japanese and Thai-style text has no spaces; stop words and markers there are segmenter-sized units, and segmentation is the matcher's job.
