# French named as an interface language in Settings search (#3142 French slice, 2026-11-21)

The `appLanguage.shipped` place (the Settings row listing the app's interface languages) named only English and German in every language's words and phrases. With French shipping, each of the 32 language blocks gains one word and one phrase that mention French, in the same pattern as its existing entries.

Draft: Azure `gpt-5-6-luna`. Review: GPT + Gemini council (session `fr-review-v-2026-11-21`, Azure `gpt-6-2-sol` and `gemini-4-hydrogen`; raw answers stay in the council's encrypted history). Gemini: no change. GPT: one change, adopted (Romanian word `meniuri în franceză`). The result search label for the same place changed from "English or German" to "Available interface languages" (German "Verfügbare Oberflächensprachen", French "Langues d’interface disponibles"), reviewed in the same session.

The adopted words and phrases are recorded under `blocks.appLanguage.shipped` in `reviewed-edits.json`.

The place is named at run time, so its new label is found only through vocabulary: the label's own wording is added as a word in the interface languages (`interface languages`, `Oberflächensprachen`, `langues d’interface`), from the label reviewed in the same session.
