You are writing the search vocabulary for the Settings search box of EnviousWispr, a macOS dictation app (you press a key and speak, it types your words into any app; optional "AI Polish" cleans the text with an on-device or cloud model). The app ships in English and German.

Use ONLY this brief and the place list below. Do not open, search or read any file, folder, repository or website.

For EVERY place id in the list below, write vocabulary in English ("en") and German ("de"):
- "words": 3 to 8 short meaning words or short terms people might type for this place that are NOT already in its title: synonyms, everyday names, product or model names it involves, common misnamings. Examples: Input device: mic, microphone, headset; Recording chimes: sound, beep, ding. German words are what a German speaker would type (Mikro, Mikrofon, Headset), not literal translations of the English words.
- "phrases": 2 to 4 short everyday sentences a person would type when looking for this place, in their own words, not the app's words. Example for "Stop recording on silence": "make it stop when I pause", "end recording automatically". German: written natively (du-form, everyday), e.g. "bei einer Sprechpause aufhören".

Rules:
- Describe only what the place really does, judging from its title, description, page and parent. Do not invent features.
- A word or phrase that would fit two different places equally goes to neither, or only to the one it uniquely describes. Choices inside a setting get words about that choice; the setting gets words about the setting as a whole.
- Actions (buttons) get fewer words (2 to 4) and 1 to 2 phrases.
- Use lowercase except product names. No punctuation inside words.

Output: one JSON object only, no commentary, no code fence:
{"<id>": {"en": {"words": [...], "phrases": [...]}, "de": {"words": [...], "phrases": [...]}}, ...}
Include every id from the list below exactly once.

Place list (id | kind | page > tab > section | EN title | DE title | description | parent):
