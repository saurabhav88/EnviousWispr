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

1. Review the draft: accuracy against the real control (Codex, with repo access), naturalness per language (a fresh Codex session per language; German also through the GPT and Gemini council, which needs founder approval for the spend). Save the review output under `scripts/settings-map/receipts/additions/`.
2. Record it in `scripts/settings-map/receipts/reviewed-edits.json`. The builder reconciles every id into exactly one group and stops on anything else:
   - a retained id (in the Phase 0 source and still mapped): reviewed word or phrase changes go under `blocks.<id>.<language>`;
   - an added id (mapped, not in the Phase 0 source): `added.<id>` with `blocks` for all 32 languages and `review`, the path of its review output under `receipts/`;
   - a retired id (in the Phase 0 source, no longer mapped or exempt): `retired.<id>` with the reason;
   - a renamed id is a retirement plus an addition; its new blocks need their own review.
3. Rebuild: `scripts/settings-map/build-vocabulary.py --source <multilingual-v2.json> --inventory Tests/Fixtures/settings-map/inventory.json --edits scripts/settings-map/receipts/reviewed-edits.json --out Sources/EnviousWisprAppKit/Resources/SettingsSearchVocabulary.json`. It prints the resource hash and each language's content hash. `--self-test` checks the reconciliation rules on a tiny source.
4. Update `scripts/settings-map/receipts/vocabulary-review.json`: the new review under each language it covers, the added id under `addedIDs` with its review path, and the printed hashes. The tests compare every language's hash with the shipped content and require each added id's review file, so content without a matching receipt fails.
5. `scripts/settings-map/verify-phase0.py` (usage in its header) must still report every language OK: retained blocks equal their Phase 0 review plus reviewed edits, added blocks equal their own reviewed blocks.

## Receipts

`receipts/vocabulary-review.json` binds the resource bytes and each language's content to its reviews. `receipts/phase0/` keeps the Phase 0 review outputs and briefs, `receipts/lists/` the stop-list and marker reviews, `receipts/council/` the German council prompts and digest, `receipts/additions/` reviews of ids added after Phase 0 (raw council answers stay in the council's encrypted history).

## Notes for the search matcher (PR B)

- Stop words and markers are compared after folding (`SettingsSearchVocabulary.fold`: case, diacritics, ß as ss). The Phase 0 Python builder folded with NFKD and mark removal, which differs for some scripts (Hangul, kana voicing, Greek final sigma); the matcher owns runtime folding and must test it per script.
- Each language's markers are removed from its own stop list here. Protecting markers and setting terms across the union of active languages is the matcher's job.
- Chinese, Japanese and Thai-style text has no spaces; stop words and markers there are segmenter-sized units, and segmentation is the matcher's job.
