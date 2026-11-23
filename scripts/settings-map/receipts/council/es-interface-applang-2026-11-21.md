# Spanish named as an interface language in Settings search (#3142 Spanish slice, 2026-11-21)

The `appLanguage.shipped` place (the Settings row listing the app's interface languages) named English, German and French in every language's words and phrases. With Spanish shipping, each of the 32 language blocks gains one word and one phrase that mention Spanish, in the same pattern as its existing entries.

Draft: Azure `gpt-5-6-luna`. Review: GPT + Gemini council (session `es-review-v-2026-11-21`, Azure `gpt-6-2-sol` and `gemini-4-hydrogen`; raw answers stay in the council's encrypted history). Both flagged only Chinese; adopted Gemini's word `西班牙语界面` (the draft `西文界面` is ambiguous) and kept the draft phrase, which matches the block's pattern.

The adopted words and phrases are recorded under `blocks.appLanguage.shipped` in `reviewed-edits.json`.

The place is named at run time, so its Spanish label ("Idiomas de interfaz disponibles", reviewed with the Spanish catalog) is found only through vocabulary: its wording is added as the Spanish word `idiomas de interfaz`.
