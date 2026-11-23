# French becomes an interface language: vocabulary migration (#3142 French slice, 2026-11-21)

## What changed
French joined the interface languages, so its titles now come from the French String Catalog. The French `title` was removed from every shipped French block (246 retained ids through the builder, 52 added ids through their review files and `reviewed-edits.json`, and the one reviewed French title edit of `selfLearningDictionary`). French words and phrases were kept unchanged. `verify-phase0.py` reports every language OK.

## Runtime-named places
A place named only at run time has no catalog title, so its French vocabulary title had been the only text matching its reviewed French label. The French search test found three such places that the label no longer finds: `livePreview.language` ("Modifier la langue de dictée"), `recordingChime.preview` ("Écouter le son") and `localModel.testLive` ("Vérifier que le modèle est actif").

Proposed French words were reviewed by the GPT + Gemini council (session `fr-vocab-x2-2026-11-21`, Azure `gpt-6-2-sol` and `gemini-4-hydrogen`; raw answers stay in the council's encrypted history). Gemini: no change. GPT: two rewordings and one removal.

Adopted:
- `recordingChime.preview` fr words: `écouter`, `écouter le son` (GPT; "entendre" names perception, not the action).
- `localModel.testLive` fr words: `tester EG-1`, `tester S1-mini`, `tester le modèle`, `vérifier que le modèle est actif` (GPT; bare "tester" and "vérifier" say nothing about what is tested).
- `livePreview.language` fr words: `changer la langue d’aperçu`, `langue de dictée`, `modifier la langue de dictée` (the proposal plus GPT's full-label word, needed because "Modifier" alone is the exact title of `lockedLanguage.change`; GPT's removal of the existing reviewed word was not adopted, since it is outside this migration).
