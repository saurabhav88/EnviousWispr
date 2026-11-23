# Spanish becomes an interface language: vocabulary migration (#3142 Spanish slice, 2026-11-21)

## What changed
Spanish joined the interface languages, so its titles now come from the Spanish String Catalog. The Spanish `title` was removed from every shipped Spanish block (246 retained ids through the builder, 52 added ids through their review files and `reviewed-edits.json`, and the two reviewed Spanish title edits of `currentEngineSection` and `selfLearningDictionary`). Spanish words and phrases were kept unchanged. `verify-phase0.py` reports every language OK.

## Runtime-named places
A place named only at run time has no catalog title, so its Spanish vocabulary title had been the only text matching its reviewed Spanish label. The Spanish search test found two such places the label no longer finds in the top five: `lockedLanguage` ("Idioma del dictado", rank 7) and `transcribeFile.steps` ("Pasos para transcribir un archivo", absent).

Proposed Spanish words (each place's label wording) were reviewed by the GPT + Gemini council (session `es-vocab-x2-2026-11-21`, Azure `gpt-6-2-sol` and `gemini-4-hydrogen`; raw answers stay in the council's encrypted history). Both: no change.

Adopted:
- `lockedLanguage` es word: `idioma del dictado`.
- `transcribeFile.steps` es word: `pasos para transcribir un archivo`.

## Search words the removed titles carried
Removing the Spanish titles also removed words that only the title carried (the final local Codex review found `hablantes` for `meetingSpeakerLabels`). A sweep over every Spanish block compared the old title's words with the new catalog label plus the remaining words and phrases: 51 ids lost at least one word, 49 lost more than a small function word (`del`, `para`). For those 49, the old reviewed Spanish title is kept as a Spanish search word (an alias; no new wording). Ten of them are added ids, so their review files under `additions/` carry the alias too and their hashes in `reviewed-edits.json` were refreshed.
