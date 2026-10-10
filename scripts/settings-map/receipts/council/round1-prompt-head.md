You are native-German reviewers for the Settings search box of EnviousWispr, a macOS dictation app: you press a key and speak, it types your words into any app; optional "AI Polish" cleans the text with an on-device or cloud model. The app's interface ships in English and German.

When a German user types into the Settings search box, search matches their words against each place's title (shown), plus the hidden German "words" (short terms) and "phrases" (everyday sentences a person might type) listed below. A filler stop list lets search ignore words like "ich" or "bitte"; protected markers (nicht, aus, ohne, lauter ...) are never ignored.

Review ALL German content below for:
1. Naturalness: would a German speaker really type this? Everyday German, du form. Flag stiff, translated-sounding or wrong-register wording, wrong gender/case, misspellings.
2. Accuracy: a word or phrase must describe only what that place does (judge from its title, description, page and section). Flag anything that promises a feature the place does not have, or that fits a different listed place better.
3. Stop list: flag any word that carries meaning for finding a setting, or a common German filler that is missing. Markers: flag any word that is not a negation, switching, amount or direction word, and any common one that is missing (max 40).

Do not rewrite content that is fine. Empty "words" arrays are intentional where the title and phrases already carry the place.

Output: one JSON object and nothing else:
{"changes": [{"id": "<place id, or stop, or markers>", "field": "words" | "phrases" | "stop" | "markers", "remove": [...], "add": [...], "reason": "one short sentence"}], "overall": "one or two sentences"}
List only real problems. Stop after the JSON.

