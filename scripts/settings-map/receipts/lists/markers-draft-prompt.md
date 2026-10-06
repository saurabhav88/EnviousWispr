You are drafting per-language word lists for the Settings search box of EnviousWispr, a macOS dictation app (press a key and speak, it types your words into any app; optional "AI Polish" cleans the text). People type searches such as "turn off the sound", "stop recording when I pause", "dictate without punctuation", "make the pill bigger", in their own language.

Use ONLY this brief. Do not open, search or read any file, folder, repository or website. Do not run commands.

Search ignores common filler words in each language (a stop list). Some short, common words must NEVER be ignored, because they change what the person wants. Draft that protected list for each language below.

Include, as single words exactly as people type them (lowercase where the language has case):
1. Negation and absence: words like English "not", "no", "without", "never", "don't", "doesn't", "can't", "nothing", "none".
2. Switching direction: words like English "on", "off", "enable", "disable", "start", "stop", "turn", "show", "hide", "mute", "unmute", "pause".
3. Amount and direction: words like English "more", "less", "louder", "quieter", "faster", "slower", "bigger", "smaller", "up", "down", "again".
4. Each language's own equivalents and common inflected or contracted forms people actually type (for example French "pas", "sans", "non", "ne", "désactiver", "activer"; German "nicht", "kein", "keine", "ohne", "aus", "an", "ein").

Rules:
- One word per item. No phrases, no spaces (for languages written without spaces between words, give the shortest word unit a word segmenter would produce, for example Chinese 不, 关闭, 开启; Japanese ない, オフ, オン).
- Only words a filler list might wrongly drop, or that carry the meaning above. Not setting names (no "microphone", "clipboard").
- At most 40 words per language. Prefer the most frequent forms.
- Languages: ar, bg, cs, da, de, el, en, es, et, fi, fr, hi, hr, hu, it, ja, ko, lt, lv, mt, nl, pl, pt, ro, ru, sk, sl, sv, tr, uk, vi, zh.

Output: one JSON object and nothing else, keys are the 32 language codes above, each value an array of strings. Stop after the JSON. Do not summarise.
