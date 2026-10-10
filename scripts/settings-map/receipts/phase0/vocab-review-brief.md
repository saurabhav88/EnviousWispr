You are reviewing a draft search vocabulary for the Settings search box of EnviousWispr, a macOS dictation app (press a key and speak, it types your words into any app; optional "AI Polish" cleans the text with an on-device or cloud model). The app ships in English and German.

Use ONLY this brief, the place list and the draft below. Do not open, search or read any file, folder, repository or website.

Each place has "words" (short terms people might type that are not in its title) and "phrases" (everyday sentences people type when looking for it), in English ("en") and German ("de").

Fix the draft so search finds the right place and nothing else:
1. Accuracy: remove or rewrite any word or phrase that describes something the place does not do, judging from its title, description, page and parent.
2. Collisions: a word or phrase that fits another place in the list equally well must go to neither, or only to the one it uniquely describes. Choices inside a setting keep words about that choice; the setting keeps words about the setting as a whole.
3. Reach: words should be the short single words people really type (mic, beep, dark, hotkey, shortcut, Mikro, Tastenkürzel), not long descriptive labels. Prefer 3 to 8 words per place and language, 2 to 4 phrases (actions: 2 to 4 words, 1 to 2 phrases). Add obvious everyday terms that are missing.
4. German: natural, everyday German as a German speaker would type it (du-form), not a translation of the English. Fix unnatural or wrong German.

Output: one JSON object only, no commentary, no code fence, with the corrected vocabulary for EVERY id in the draft below, same shape:
{"<id>": {"en": {"words": [...], "phrases": [...]}, "de": {"words": [...], "phrases": [...]}}, ...}

